# Logging & Observability (Backend Application)

## Overview

This document covers the **backend application's** logging and telemetry — what the ASP.NET Core agent
(`src/agent_backend`) emits, where it goes, and how to query it. It is the counterpart to the **gateway-side**
diagnostics docs ([`apim-app-insights.md`](apim-app-insights.md), [`apim-azure-monitor.md`](apim-azure-monitor.md)), which cover request/response logging
configured on Azure API Management itself. Two layers, one destination:

| Layer | Configured in | Captures | Doc |
| --- | --- | --- | --- |
| **APIM gateway** | Bicep API diagnostics + gateway policy | Inbound/outbound gateway requests, client IP, rate-limit and token-usage metrics | [`apim-app-insights.md`](apim-app-insights.md), [`apim-azure-monitor.md`](apim-azure-monitor.md) |
| **Backend app** | [`Program.cs`](../src/agent_backend/Program.cs) + `ILogger` call sites | Incoming requests, outgoing dependencies, GenAI agent spans, structured app logs, the RAG retrieval audit trail | *this doc* |

Both export to the same **Application Insights** resource, so a single trace can be followed from the SPA's
request, through the backend, out to APIM, and back.

## Telemetry backbone — Azure Monitor OpenTelemetry distro

Telemetry is wired once in [`Program.cs`](../src/agent_backend/Program.cs), and only when a connection string is present so local dev without
Application Insights still starts clean:

```csharp
if (!string.IsNullOrWhiteSpace(builder.Configuration["APPLICATIONINSIGHTS_CONNECTION_STRING"]))
{
    builder.Services.AddOpenTelemetry()
        .UseAzureMonitor()
        .WithTracing(t => t.AddSource(AgentFactory.TelemetrySourceName))
        .WithMetrics(m => m
            .AddMeter(AgentFactory.TelemetrySourceName)
            .AddMeter(TokenUsageTelemetry.MeterName));
}
```

`APPLICATIONINSIGHTS_CONNECTION_STRING` is set on the App Service in Azure. `UseAzureMonitor()` auto-collects:

- **Incoming requests** — every backend HTTP request (`/chat`, `/chat/stream`, `/files`, …) as a `request`.
- **Outgoing dependencies** — every `HttpClient` call the backend makes: the APIM gateway (Responses API,
  embeddings, Content Safety, Document Intelligence), Cosmos DB, and Azure AI Search, each as a `dependency`
  with duration and success/failure.
- **Logs** — every `ILogger` entry (below) as a `trace`, with structured properties in `customDimensions`.

### GenAI agent spans

`AddSource`/`AddMeter` pull in the Microsoft Agent Framework's **GenAI spans** — the agent is built with
`.UseOpenTelemetry(sourceName: AgentFactory.TelemetrySourceName, …)` ([`AgentFactory.cs`](../src/agent_backend/Services/AgentFactory.cs)), emitting spans for
LLM calls, tool invocations, and token usage under the source `AgentBackend.Agent`.

### Token/cost metrics

A second meter, `AgentBackend.Tokens` ([`TokenUsageTelemetry.cs`](../src/agent_backend/Services/TokenUsageTelemetry.cs)), records the FinOps view of a turn:
`agent.tokens.prompt|completion|total|cached|reasoning` and `agent.turns`, tagged **only** with `model`
and `streaming`. It is called from both `ChatService.AskAsync` and `ChatService.StreamAsync`, and never
throws — a telemetry failure is logged at Warning and the answer is still served.

`sessionId` is deliberately **not** a metric dimension: it is a UUID, so one time series per conversation
would explode metric cardinality and cost. It travels on the companion `"Token usage audit"` **trace**
instead (below), where cardinality is free. The two together are what let the **Token & Cost Insights**
workbook break tokens down by model *and* rank the heaviest conversations — see
[`finops.md`](finops.md).

### Content Safety outcome metric

A third meter, `AgentBackend.ContentSafety` ([`ContentSafetyService.cs`](../src/agent_backend/Services/ContentSafetyService.cs)), emits
`agent.contentsafety.evaluations` once per pre-check, tagged with a single `outcome` dimension:

| `outcome` | Meaning |
| --- | --- |
| `clean` | Screened, nothing at or above `CONTENT_SAFETY_THRESHOLD`, no prompt attack |
| `flagged` | Screened and tripped — rejected in `block` mode, logged only in `log` mode |
| `failopen` | **Not screened.** A `text:analyze` or `text:shieldPrompt` call errored and the turn was allowed through |

`failopen` is the one that matters operationally: in `block` mode it means blocking was silently disabled
for that turn. Three values is low enough cardinality to land in `customMetrics` and back a metric alert —
fire on a sustained non-zero `failopen` rate. The **Agent Operations** workbook charts the split and shows
the fail-open percentage as a tile.

Failing open is still the default, because a Content Safety outage taking chat down is usually the worse
trade. Set `CONTENT_SAFETY_FAIL_CLOSED=true` (only meaningful alongside `CONTENT_SAFETY_MODE=block`) to
invert that and reject unscreened turns with the normal block message.

> **Sensitive data is off by default.** `EnableSensitiveData = false` on the GenAI instrumentation means
> **prompts, responses, and tool arguments/results are *not* written to traces** — spans still carry model
> name, token counts, and tool names, but not message content. This is deliberate: the traces stay a
> low-sensitivity operational signal. The one place tool *metadata* is deliberately recorded for audit is the
> RAG retrieval manifest (below), which is compact and text-free by construction.

### Request timing

An `X-Process-Time` middleware ([`Program.cs`](../src/agent_backend/Program.cs)) stamps each response with total processing time (mirroring the
Python backend). For `/chat/stream` this fires on first flush, so it measures **time-to-first-byte**, not the
full stream duration.

## The RAG retrieval audit trail

Because tool results are **not persisted to Cosmos** (see *Conversation history* below), the durable record of
*what grounded each answer* is a structured audit log emitted by `SearchAdapter.LogRetrievalManifest` on every
retrieval:

```
RAG retrieval audit: session={SessionId} hits={HitCount} query={Query} manifest={Manifest}
```

`manifest` is a JSON array with one object **per retrieved chunk**:

| Field | Meaning |
| --- | --- |
| `FileId` | The attachment the chunk came from (resolves to `/files/{fileId}` and the citation preview) |
| `Source` | The `Title (filename.ext)` citation label the model cites |
| `Score` | Semantic reranker score (falls back to the hybrid fusion score) — how relevant the chunk was |
| `Length` | Chunk character count — **the text itself is never logged** |

This answers the audit questions — *which files/chunks grounded this session, how relevant, how large* —
without persisting chunk text anywhere. It is **compact by design**: at ≤5 hits × ~100 chars the serialized
manifest stays far under Application Insights' limits (below), where a raw chunk dump would be truncated.

### Why the manifest, not the raw tool output

Application Insights truncates oversized fields silently:

| Field | Cap |
| --- | --- |
| `customDimensions` property value (structured log properties) | **8,192 characters** |
| `message` (rendered log message) | **32,768 characters** |

A few AI Search chunks (~512 tokens each, with overlap) is easily 10–40 KB of text — so logging the raw tool
output would be lossily truncated at 8 KB (as a property) or 32 KB (in the message). The manifest sidesteps
this entirely by recording identifiers + a length instead of the text.

### If verbatim capture is ever required

App Insights is not a store for large payloads, and its **sampling** can drop telemetry under load. If a true
compliance-grade, full-fidelity record of the exact bytes the model saw is needed, the pattern is: tee the raw
tool output to **blob storage** (the backend already has managed-identity blob access via `StorageService`)
keyed `audit/{sessionId}/{turn}/{callId}`, and log only the **blob URI** in the manifest. The manifest stays
the queryable index; the blob holds the fidelity. This is intentionally *not* implemented — YAGNI until a
verbatim requirement exists.

## Structured log call sites

Every entry below flows to Application Insights as a `trace` with its structured properties in
`customDimensions` (queryable in KQL).

| Area | File | Level | What it records |
| --- | --- | --- | --- |
| RAG retrieval audit | [`SearchAdapter.cs`](../src/agent_backend/Services/SearchAdapter.cs) | Information | The per-turn retrieval manifest (above) |
| RAG failure | [`SearchAdapter.cs`](../src/agent_backend/Services/SearchAdapter.cs) | Warning | A caught search failure (degrades to ungrounded) — no longer swallowed silently |
| Token usage audit | [`TokenUsageTelemetry.cs`](../src/agent_backend/Services/TokenUsageTelemetry.cs) | Information | Per-turn `sessionId`, `model`, `streaming` and the prompt/completion/total/cached/reasoning token counts — the high-cardinality half of the cost telemetry |
| Chat persist failure | [`ChatService.cs`](../src/agent_backend/Services/ChatService.cs) | Error | Model answered but the end-of-turn Cosmos history write failed — *the turn was not saved* |
| Content Safety detection | [`ChatService.cs`](../src/agent_backend/Services/ChatService.cs) | Warning | Flagged category severities + prompt-attack flag + mode (`log`/`block`), every mode |
| Content Safety fail-open (API) | [`ContentSafetyService.cs`](../src/agent_backend/Services/ContentSafetyService.cs) | Warning | The failing `text:analyze` / `text:shieldPrompt` call itself |
| Content Safety fail-open (turn) | [`ChatService.cs`](../src/agent_backend/Services/ChatService.cs) | Warning | The turn reached the model unscreened, with the effective `mode` and `failClosed` — paired with the `outcome=failopen` metric |
| Stream last-resort | [`UiMessageStreamResult.cs`](../src/agent_backend/Endpoints/UiMessageStreamResult.cs) | Error | An exception after headers were committed; stream is still terminated with `[DONE]` |
| Ingestion worker | [`QueueIngestionWorker.cs`](../src/agent_backend/Services/QueueIngestionWorker.cs) | Info / Warning / Error | Worker lifecycle, retries, poison-queue moves |
| Ingestion pipeline | [`IngestionService.cs`](../src/agent_backend/Services/IngestionService.cs) | Error | Per-step ingestion failures (naming the session/file for manual cleanup) |
| Ingestion init | [`IngestionInitializer.cs`](../src/agent_backend/Services/IngestionInitializer.cs), [`SearchIndexer.cs`](../src/agent_backend/Services/SearchIndexer.cs) | Info / Error | Startup resource creation (index, queue, table, container) |

## Error-handling logging (chat streaming path)

The streaming turn has two failure shapes, and each logs differently (`ChatService.StreamAsync`,
`UiMessageStreamResult`):

1. **Model/gateway failure with no content yet** — surfaced to the client as an in-band `error` stream part
   (HTTP status can't travel once streaming headers are committed). Not separately logged here; the failed
   dependency is already captured by auto-collection.
2. **End-of-turn persist failure** (the model answered, then the Cosmos history write threw — e.g. the
   provider's `InvalidOperationException("Batch operation failed with status: BadRequest")`) — logged at
   **Error** noting *the turn was not saved to Cosmos*, and the stream is completed normally so the client
   still gets its answer, metadata footer, and a clean `finish`. This is now rare: tool results are filtered
   out of persistence (below), which was the batch-size cause.
3. **Anything that still escapes** `ChatService` reaches `UiMessageStreamResult`'s last-resort `catch`, which
   logs at **Error** and writes `[DONE]` so the connection isn't reset (`ERR_CONNECTION_RESET`). Client
   disconnects (cancellation) return quietly without logging noise.

## Conversation history — what is (and isn't) persisted

Cosmos DB stores **only the user-facing transcript**: user turns and assistant answers. Tool-call and
tool-result messages are filtered out before persistence by `AgentFactory.StripToolPlumbing`, wired as the
`CosmosChatHistoryProvider`'s `storeInputResponseMessageFilter`. Two reasons:

- **Correctness/size** — a large RAG tool-result dump could push a turn's Cosmos *transactional batch* past
  the 2 MB limit (→ `BadRequest`, the original failure this addressed). Dropping both sides of a tool exchange
  together also keeps stored history structurally valid for the next turn (no orphaned tool call).
- **Separation of concerns** — future turns are grounded by the assistant's *answer*, not the raw retrieval;
  the raw retrieval is instead audited to App Insights via the manifest above.

The filter runs **only on the store path** — the model still sees full tool results *within* the turn.

## Privacy summary — what never gets logged

- **Prompt/response/tool text in traces** — off (`EnableSensitiveData = false`).
- **RAG chunk text** — never in the audit manifest (identifiers + length only) and never persisted to Cosmos.
- **Content Safety** — logs which categories/severities tripped, not the offending message content.

## Local development

Without `APPLICATIONINSIGHTS_CONNECTION_STRING` the OpenTelemetry exporter isn't wired, but `ILogger` still
writes to the **console** (the default ASP.NET Core provider), so the retrieval manifest, persist-failure
errors, and Content Safety detections are all visible in the `dotnet run` output. Default minimum level is
`Information`, so the manifest (`Information`) shows locally; raise/lower via standard
`Logging:LogLevel` configuration.

## The Agent Operations workbook

The visual layer over this telemetry is the **Agent Operations** Azure Monitor workbook
([`infra/modules/monitor/resources/ops-workbook.bicep`](../infra/modules/monitor/resources/ops-workbook.bicep), always deployed, wired from [`main.bicep`](../infra/main.bicep)'s
`opsWorkbookName` — open it in the portal under Application Insights → **Workbooks**). It replaced the
stock `azd` Application Insights *dashboard*, whose canned metric part-types rendered mostly empty for
this workload (a Linux `.NET` API + a JS-SDK-less SPA): no browser telemetry, no availability tests,
and Windows-only performance counters. The workbook is driven by KQL over the signal documented above
and organizes it into sections — **request health** (rate, failures, P50/P95, per-route), **dependencies**
(latency + failures split across the APIM gateway, Cosmos, and AI Search), the **RAG retrieval audit**
(retrievals over time, top grounding sources, zero-hit turns), **Content Safety & reliability**
(detections, outcome split, fail-open rate, persist failures, top exceptions), and the **GenAI spans** (LLM + tool operations). Token /
cost showback lives in the sibling **Token & Cost Insights** workbook instead (see [`finops.md`](finops.md)),
and the gateway's own health — per-API and per-endpoint success/failure, response-time percentiles,
throttling, per-caller consumption — in the **API Gateway Operations** workbook (see
[`apim-azure-monitor.md`](apim-azure-monitor.md)). Note that this third one lives under **Log Analytics
workspace → Workbooks**, not App Insights, because it reads the `ApiManagementGatewayLogs` table.

> Note on rollout: `azd provision` creates the workbook but does not delete the pre-existing `dash-*`
> Portal dashboard from older deployments (azd doesn't prune resources dropped from the template) —
> remove it once with `az portal dashboard delete -g rg-monitor-<env>-<token> -n dash-<env>-<token>`.

## KQL query examples

The workbook above visualizes these; run them ad hoc in the Application Insights **Logs** blade.

**Retrieval audit for a session** (which files grounded the answers, and how relevant):

```kusto
traces
| where message startswith "RAG retrieval audit"
| where customDimensions.SessionId == "<sessionId>"
| project timestamp, hits = customDimensions.HitCount, query = customDimensions.Query, manifest = customDimensions.Manifest
| order by timestamp desc
```

**Turns that were answered but not saved** (Cosmos persist failures):

```kusto
traces
| where message startswith "Model responded but history persist failed"
| project timestamp, message, sessionId = customDimensions.SessionId
| order by timestamp desc
```

**Content Safety detections** (deployed in `block` mode; switch `CONTENT_SAFETY_MODE` to `log` to tune the threshold without rejecting turns):

```kusto
traces
| where message startswith "Content safety flagged"
| project timestamp, sessionId = customDimensions.SessionId, categories = customDimensions.Categories,
          promptAttack = customDimensions.Attack, mode = customDimensions.Mode
| order by timestamp desc
```

**Turns that reached the model unscreened** (Content Safety failed open — in `block` mode, blocking was off):

```kusto
customMetrics
| where name == "agent.contentsafety.evaluations"
| extend outcome = tostring(customDimensions.outcome)
| summarize turns = sum(valueSum) by bin(timestamp, 15m), outcome
| render timechart
```

**GenAI agent spans** (LLM calls / tool invocations with token counts):

```kusto
dependencies
| where target has "AgentBackend.Agent" or name has_any ("chat", "tool")
| project timestamp, name, duration, success, customDimensions
| order by timestamp desc
```
