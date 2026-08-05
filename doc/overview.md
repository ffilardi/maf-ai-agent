# Solution Overview

Microsoft Agent Framework (MAF) AI agent fronted by an Azure API Management "AI Gateway" that load-balances and rate-limits access to Azure AI Foundry / Azure OpenAI models.

**Architecture**: Two-tier — an ASP.NET Core (.NET 10) minimal-API backend agent on Azure App Service, and a Vite + React (TypeScript) single-page web chat hosted on Azure Static Web Apps. The SPA calls the backend directly from the browser (CORS), with no proxy tier.

## Backend Directory Structure

```text
src/agent_backend/
├── Program.cs                 ← Composition root (DI + route wiring)
│
├── Configuration/
│   └── AgentOptions.cs        ← Env-var config + Has*Config guards
│
├── Endpoints/                  ← Routes + handler methods (no controllers)
│   ├── MetaEndpoints.cs        GET /, /ping, /config
│   ├── ChatEndpoints.cs        POST /chat, /stream, sessions CRUD
│   ├── FilesEndpoints.cs       File upload/status/content/delete
│   └── UiMessageStreamResult.cs  IResult for SSE streaming protocol
│
├── Models/                     ← Request/response types + [JsonPropertyName]
│   ├── ChatModels.cs           ChatRequest, UiStreamPart, MessageMetadata
│   └── FileModels.cs           FileStatusResponse, IngestionMessage…
│
├── Services/                   ← Business logic & infrastructure services
│   ├── AgentFactory.cs         Builds AIAgent via Responses API + providers
│   ├── ChatService.cs          AskAsync + StreamAsync (agent turn logic)
│   ├── ConversationStore.cs    Cosmos CRUD for sessions/messages
│   │
│   ├── IngestionService.cs     EnqueueAsync + ProcessAsync + purge methods
│   ├── QueueIngestionWorker.cs BackgroundService (queue consumer)
│   ├── IngestionInitializer.cs HostedService (ensure index at startup)
│   ├── StorageService.cs       Blob upload/download (managed identity)
│   ├── QueueService.cs         Storage queue (enqueue/poll)
│   ├── IngestionStatusStore.cs Table Storage (file status records)
│   ├── DocumentIntelligenceService.cs DI API via APIM → markdown
│   ├── EmbeddingService.cs     Azure OpenAI embeddings (via APIM)
│   ├── SearchAdapter.cs        Hybrid search + semantic re-ranking
│   ├── SearchIndexer.cs        Index CRUD + chunk upload
│   │
│   ├── MarkdownChunker.cs      ~512-token chunks with overlap
│   └── MarkdownTitle.cs        Title extraction from text
│
└── AgentBackend.csproj         OPENAI001 warning suppressed (preview APIs)
```

### Layer descriptions

| Layer | Responsibility |
| --- | --- |
| **1 — Endpoints** | Route definitions + thin handler lambdas. Validate input, call services, map to HTTP results. No `[Controller]` classes — this is Minimal API (Fluent route DSL). |
| **2 — Models** | Wire shapes for request/response serialization. Every field pinned with `[JsonPropertyName]` (camelCase in, snake_case for `tokenUsage`). |
| **3 — Configuration** | Single settings class (`AgentOptions`) with boolean guards (`HasApimConfig`, `HasCosmosConfig`, etc.). Read from environment variables — not config hierarchy binding. Each guard gates a set of services and endpoints. |
| **4 — Core Services** | `ChatService` orchestrates agent turns (ask + stream). `ConversationStore` handles Cosmos CRUD. `AgentFactory` wires the MAF agent, history provider, and RAG tool provider. |
| **4 — Ingestion Pipeline** | `IngestionService` splits work into two paths: fast request-path enqueue (POST /files → 202), then background worker (`QueueIngestionWorker`) runs the conversion/chunk/embed/index pipeline. |
| **5 — Infrastructure** | Each cloud service has its own class (`StorageService`, `SearchIndexer`, etc.). All LLM/Search/DI calls go through **APIM** (never directly). Blob/Queue/Table use managed identity (`DefaultAzureCredential`). |
| **6 — Helpers** | Dependency-free utilities for markdown processing (chunking + title extraction). |

## API Endpoints Reference

| Method | Route | Handler Class | Core Service Called | Description |
| --- | --- | --- | --- | --- |
| GET | `/` | `MetaEndpoints` | — | Runtime string (health info) |
| GET | `/ping` | `MetaEndpoints` | — | Health check |
| GET | `/config` | `MetaEndpoints` | `AgentOptions` | Client config (models, default prompt) |
| **POST** | `/chat` | `ChatEndpoints` | `ChatService.AskAsync()` | Buffered agent turn → `{sessionId, answer, usedTools, tokenUsage}` |
| **POST** | `/chat/stream` | `ChatEndpoints` | `ChatService.StreamAsync()` | Streaming agent turn → AI SDK UI Message Stream (SSE, v1) |
| GET | `/chat/sessions` | `ChatEndpoints` | `ConversationStore.ListAsync()` | List past conversations (newest-first, max 50) |
| GET | `/chat/{sessionId}/messages` | `ChatEndpoints` | `ConversationStore.GetMessagesAsync()` | Get session transcript (oldest-first) |
| DELETE | `/chat/{sessionId}` | `ChatEndpoints` | `ConversationStore.DeleteAsync()` → `IngestionService.PurgeSessionAsync()` | Delete session + cascade-purge attachments (best-effort) |
| **POST** | `/files` | `FilesEndpoints` | `IngestionService.EnqueueAsync()` | Multipart upload → 202 (processing) |
| GET | `/files?sessionId=…` | `FilesEndpoints` | `IngestionStatusStore.ListAsync()` | List all file statuses for a session |
| GET | `/files/{fileId}` | `FilesEndpoints` | `IngestionStatusStore.GetAsync()` | Poll status of one file (processing → indexed/failed) |
| GET | `/files/{fileId}/content?sessionId=…` | `FilesEndpoints` | `StorageService.DownloadAsync()` | Preview/download original file (stored-XSS hardened) |
| DELETE | `/files/{fileId}?sessionId=…` | `FilesEndpoints` | `IngestionService.PurgeFileAsync()` | Purge one file's artifacts (best-effort, idempotent) |

All endpoints return **503** when their required configuration is absent — the app starts regardless of which features are configured.

## Dependency Injection Summary

Every service is registered as a **singleton** in `Program.cs`. Services are resolved lazily via `IServiceProvider` from endpoint handlers (not as constructor parameters) so that config-guard failures return **503** instead of DI-time 500.

| Service | Registered When | Lifespan | Notes |
| --- | --- | --- | --- |
| `AgentOptions` | Always | Singleton | Baked into every handler via DI parameter |
| `CosmosClient` | `HasCosmosConfig` | Singleton | Shared across agent + ConversationStore |
| `ConversationStore` | `HasCosmosConfig` | Singleton | Cosmos CRUD (sessions/messages) |
| `AIAgent` | Always | Singleton | Built lazily; throws if APIM missing |
| `ChatService` | Always | Singleton | Agent turn orchestration |
| `DefaultAzureCredential` | `HasIngestionConfig` | Singleton | Managed identity (no account keys) |
| `StorageService` | `HasIngestionConfig` | Singleton | Blob upload/download |
| `QueueService` | `HasIngestionConfig` | Singleton | Storage queue producer/consumer |
| `IngestionStatusStore` | `HasIngestionConfig` | Singleton | Table Storage (file status) |
| `DocumentIntelligenceService` | `HasIngestionConfig` | Singleton | DI → markdown (via APIM) |
| `EmbeddingService` | `HasIngestionConfig` | Singleton | Azure OpenAI embeds (via APIM) |
| `SearchIndexer` | `HasIngestionConfig` | Singleton | Index CRUD + chunk upload (via APIM) |
| `IngestionService` | `HasIngestionConfig` | Singleton | Enqueue + process + purge logic |
| `IngestionInitializer` | `HasIngestionConfig` | HostedService | Ensure container/index at startup |
| `QueueIngestionWorker` | `HasIngestionConfig` | HostedService | Background queue consumer (5-min visibility, retry-then-poison) |

## Request Flow — Chat Turn

```text
Browser SPA
    │
    ├─ POST /chat            → buffered (JSON response)
    └─ POST /chat/stream     → SSE stream (AI SDK UI Message Stream v1)
         │
         ├─ ChatEndpoints handler validates input & config
         └─ ChatService.BuildTurnAsync()
              ├─ Creates AgentSession + tags StateBag with sessionId
              └─ AIAgent.RunAsync() (Responses API via APIM)
                   ├─ CosmosChatHistoryProvider → session history (capped read; TTL disabled)
                   ├─ CompactionProvider → trims loaded history before the model call
                   └─ TextSearchProvider → RAG tool "SearchChatAttachments" (if configured)
         │
         └─ ChatService.StreamAsync() extracts tokenUsage + usedTools from response
              └─ Returns UiStreamPart sequence: start → content parts → message-metadata → finish
```

## File Ingestion Flow — Async Pipeline

```text
Browser SPA uploads file (multipart)
    │
    └─ POST /files → IngestionService.EnqueueAsync()
         ├─ Upload original to Blob Storage (path: {fileId}/{name})
         ├─ Write "processing" status to Table Storage (PartitionKey=sessionId, RowKey=fileId)
         └─ Enqueue message to Queue Storage
              │  ← Returns 202 (fast path) — SPA polls GET /files/{fileId}
              ▼
QueueIngestionWorker (BackgroundService)
    │
    └─ Dequeues → IngestionService.ProcessAsync()
         ├─ Download original blob
         ├─ Convert to markdown: Document Intelligence (prebuilt-layout) or verbatim for text
         ├─ Extract title: DI-detected → first heading → filename without extension
         ├─ Chunk markdown (MarkdownChunker, ~512 tokens + overlap)
         ├─ Embed chunks (EmbeddingService → Azure OpenAI via APIM)
         └─ Index chunks into AI Search (SearchIndexer, hybrid vector + text, semantic config)
              │
              └─ Update status to "indexed" in Table Storage (SPA polls until terminal)
```

## Key Design Decisions

| Decision | Rationale |
| --- | --- |
| **Minimal API, no controllers** | Leaner codebase; handlers are inline methods in endpoint files; DI via handler parameters (`IServiceProvider`, `AgentOptions`) |
| **Lazy service resolution** | Config guards (503) run before DI builds the agent; avoids throwing 500 when optional features are unconfigured |
| **Async file ingestion** | Upload returns 202 immediately; background worker converts/chunks/indexes; SPA polls for status |
| **Best-effort cascade delete** | Session deletion purges blobs, search chunks, and status rows — each step isolated so one failure doesn't break others |
| **Stored-XSS defense on file preview** | Content type derived from validated extension (not uploader input); html/office forced to download, not render |
| **Server-side conversation history** | Cosmos-owned; SPA sends only `{sessionId, chatInput}` per turn — not the full message array |
| **Responses API (not Chat Completions)** | Only Azure surface that returns reasoning summaries; `store=false` to keep Cosmos in charge of history |
| **History bounded, TTL disabled** | Cap Cosmos reads (`MaxMessagesToRetrieve`), keep transcripts forever (`MessageTtlSeconds=null`), and compact in-context (`ToolResultCompactionStrategy` → `ContextWindowCompactionStrategy`) — see the history section below |
| **Tool results not persisted** | Only user turns + assistant answers reach Cosmos (`AgentFactory.StripToolPlumbing`); raw RAG tool results are audited to App Insights instead — keeps each turn's transactional-batch write under Cosmos's 2 MB limit (see the history section + `logging.md`) |
| **APIM as single gateway** | All LLM/Search/DI traffic routes through APIM — load balancing, rate limiting, token management, managed-identity auth |
| **Managed identity for storage** | No account keys anywhere; App Service MI + `DefaultAzureCredential` grants Storage Blob/Queue/Table Data Contributor |
| **CORS for direct SPA → backend** | No proxy tier; SPA calls App Service directly (CORS-gated by `ALLOWED_ORIGINS` from Static Web App hostname) |

## Conversation History & the `store` Flag

Two of the design decisions above (**Server-side conversation history**, **Responses API with `store=false`**) are the same choice viewed from two angles. This section explains it in full because it drives the whole persistence design.

### What `store` does (Azure OpenAI Responses API)

The Responses API can keep a server-side copy of the conversation. The `store` parameter (`StoredOutputEnabled` in the .NET SDK, set in `AgentFactory.BuildResponseOptions`) chooses who owns history:

| Setting | Behaviour | Who owns history |
| --- | --- | --- |
| `store=true` (**API default**) | The service persists each response and returns a response id; the next turn is chained by passing that id (`previous_response_id`) instead of resending prior turns. | Azure (server-side) |
| `store=false` (**what we set**) | The call is **stateless** — nothing retained server-side, no id returned. The caller must supply full prior history each turn. | The caller (us) |

### Where `store=true` would save it

Not into a database you control — into **Azure's managed service storage attached to your Azure OpenAI / Foundry resource**:

- Retrieved only **by id** (`GET /responses/{id}`) — no "list conversations", no query surface, no schema you own.
- Lives in the **same region** as the resource (data residency follows the resource), platform-encrypted at rest.
- **Fixed, limited retention** (on the order of ~30 days) that you don't control — not a durable system of record.

### Why we force `store=false` and own history in Cosmos

There are two hard reasons and several soft ones.

**Hard reason 1 — the load-balanced gateway.** APIM load-balances across multiple Azure OpenAI / Foundry backends. Server-side stored state is **per-backend-instance**: a conversation created when the request hit backend A does not exist when the next turn routes to backend B. `store=true` is therefore fundamentally incompatible with a multi-backend gateway — the id won't resolve on a different backend.

**Hard reason 2 — MAF's history contract.** With `store=true`, the Responses API returns a conversation id *and* we have `CosmosChatHistoryProvider` wired. MAF's `ChatClientAgent` sees two competing history mechanisms and throws at end-of-run: *"Only ConversationId or ChatHistoryProvider may be used, but not both"*. Running stateless (`store=false`) leaves Cosmos as the single source of truth.

**Soft benefits of owning history:**

| Benefit | Why it matters here |
| --- | --- |
| Provider/model portability | Transcript isn't locked to Azure OpenAI — swap the model per request (`AI_MODEL_DEPLOYMENTS`) or the provider entirely, keeping the conversation. |
| Queryable, not retrieve-by-id | Powers the sessions sidebar (`GET /chat/sessions`, `GET /chat/{sessionId}/messages`) — impossible with opaque server-side state. |
| Ownership & governance | We control region, retention, and **deletion** — `DELETE /chat/{sessionId}` purges the transcript and cascades to file-ingestion artifacts (GDPR erasure, etc.). |
| Custom enrichment | Metadata (token usage, tools used, `userName`) lives alongside messages instead of in an opaque blob. |

**Trade-off we accept:** stateless turns resend prior history each call (more tokens/latency than server-side id chaining), and we run the plumbing + pay for Cosmos. MAF's built-in `CosmosChatHistoryProvider` does almost all of the plumbing; the history-bounding knobs below keep long conversations cheap.

### Bounding history: retrieval cap, TTL, and compaction

Owning history means owning its cost. Three knobs, set in `AgentFactory.Create`, keep it in check — they act at **different layers** and are complementary, not redundant:

| Knob | Layer | Default | What we set | Effect |
| --- | --- | --- | --- | --- |
| `CosmosChatHistoryProvider.MaxMessagesToRetrieve` | Cosmos read | `null` (unbounded) | `MAX_HISTORY_MESSAGES` (100) | Reads only the N most-recent messages per turn — a Cosmos RU + latency guard. (`MaxItemCount` is only the query **page size**, *not* a total cap.) |
| `CosmosChatHistoryProvider.MessageTtlSeconds` | Cosmos storage | `86400` (24h) | `null` (**disabled**) | Transcripts persist indefinitely so users can resume a conversation days later. |
| `CompactionProvider` (an `AIContextProvider`) | In-context | none | pipeline (below) | Reduces the *loaded* message set before each model call to bound the context window and per-turn prompt cost. |

A **fourth mechanism sits upstream of all three: tool plumbing is never persisted.** Tool-call/tool-result messages are filtered out before they reach Cosmos (`AgentFactory.StripToolPlumbing`, wired as the provider's `storeInputResponseMessageFilter`), so a stored transcript is only user turns + assistant answers. This keeps each turn's transactional-batch write under Cosmos's 2 MB limit (an oversized RAG dump was the original `BadRequest` failure) *and* means the history loaded from Cosmos on later turns already excludes old tool dumps. Consequently `ToolResultCompactionStrategy` below now mainly bounds *within-turn* tool bloat (many tool calls in one turn) rather than cross-turn dumps, and acts as a backstop. The raw tool results are audited to App Insights instead (see `logging.md`).

The compaction pipeline (`PipelineCompactionStrategy`, executed in order):

1. **`ToolResultCompactionStrategy`** — collapses verbose in-context RAG tool-result dumps (trigger: `HasToolCalls`), preserving the 6 most-recent groups so the current exchange stays intact. With tool results excluded from persistence, these dumps are now the current turn's own tool calls, not reloaded history.
2. **`ContextWindowCompactionStrategy`** — token-budget backstop: evicts tool results (at 50% of budget) then truncates the oldest turns (at 80%) as history approaches the input budget = `MAX_CONTEXT_WINDOW_TOKENS` − `MAX_OUTPUT_TOKENS`. Token counts are estimated (bytes/4) — no tokenizer dependency.

Key ordering insight: **the cap bounds what Cosmos *reads*; compaction bounds what the model *sees*.** Compaction runs *after* the Cosmos load, so it can't reduce DB read cost — that's the cap's job. The cap (100) sits comfortably above compaction's preserve floor, so compaction does the fine-grained trimming and the cap is only a backstop against a pathological transcript.

## Cross-References

| Doc | Topic |
| --- | --- |
| `quickstart.md` | Provisioning, local dev, extending the agent |
| `rag.md` | Azure AI Search RAG — search adapter, indexing pipeline |
| `logging.md` | Backend logging & telemetry — the streaming/persist error handling and the RAG retrieval audit trail |
| `features.md` | Feature overview |
| `guidance.md` | Development and deployment guidance |
| `load-balancing*.md` | APIM load balancing configuration |
| `apim-policies.md` | AI Gateway policies (rate limits, token management) |
| `apim-azure-monitor.md` | Monitoring and observability via APIM |
| `apim-app-insights.md` | Application Insights integration with APIM |
