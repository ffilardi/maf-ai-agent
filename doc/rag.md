# Retrieval-Augmented Generation (RAG) Guide

## Overview

The agent grounds its answers on your own content using [Azure AI Search](https://learn.microsoft.com/azure/search/)
and the Microsoft Agent Framework's `TextSearchProvider`. The provider is exposed to the model as an
**on-demand `SearchChatAttachments` tool**: the model decides when a question needs grounding, calls `SearchChatAttachments`, and
composes its answer from the retrieved passages. When a passage is used, `SearchChatAttachments` appears in the
response's `usedTools` array.

Content reaches the index two ways: a pre-existing index you populate yourself, and — new — **file
attachments** users upload in the chat. The frontend's attachment button (paperclip in the composer) posts a
document to the backend's `POST /files`, which persists it and **enqueues** it; a background worker runs the
ingestion pipeline (Document Intelligence → chunk → screen → embed → push) and the SPA polls the file's status,
keeping the prompt box locked until it's indexed (or fails). Each chunk is tagged with the conversation's
`sessionId`, and the `SearchChatAttachments` tool filters retrieval to the current conversation — a document uploaded in one
chat isn't retrieved in another. Retrieval is **hybrid** (keyword + vector): chunks are embedded with
`text-embedding-3-large` at ingestion and the query is embedded the same way at read time (the push-model
index has no server-side vectorizer).

This replaces the MCP-based tool integration from earlier versions of this template — the backend no
longer uses Model Context Protocol servers.

## How it works

1. **Wiring** ([`Services/AgentFactory.cs`](../src/agent_backend/Services/AgentFactory.cs)): when all three `AI_SEARCH_*` settings are present
   (`AgentOptions.HasAiSearchConfig`), a `TextSearchProvider` is registered on the agent in
   `OnDemandFunctionCalling` mode with the tool name `SearchChatAttachments`. If the settings are absent, no search
   tool is advertised — the agent answers from the model's own knowledge.
2. **Retrieval** ([`Services/SearchAdapter.cs`](../src/agent_backend/Services/SearchAdapter.cs)): the provider calls `SearchAdapter.SearchAsync(query, ct)`,
   which runs a hybrid (keyword + vector) query against the index — embedding the query with
   `EmbeddingService`, and filtering to the current conversation via the `sessionId` read off the tool
   invocation's `FunctionInvokingChatClient.CurrentContext.Options.AdditionalProperties` (`ResolveSessionScope`) —
   and returns grounding passages. With no session scope it fails closed (returns nothing).
3. **Grounding**: the framework injects the returned passages into the model context, and the model
   cites them in its answer.

```
User question
   │
   ▼
maf-agent (Microsoft Agent Framework)
   │  model decides grounding is needed
   ▼
SearchChatAttachments ─►  SearchAdapter.SearchAsync  ──►  Azure AI Search index
   │                                                      │
   ◄──────────────  TextSearchResult[] passages  ─────────┘
   │
   ▼
Grounded answer  (usedTools: ["SearchChatAttachments"])
```

## Configuration

The `SearchChatAttachments` tool is gated on all three settings being present (otherwise it stays dormant):

| Variable | Description | Example |
|----------|-------------|---------|
| `AI_SEARCH_ENDPOINT` | APIM AI Search API base (search is reached only through the gateway) | `https://apim-env-token.azure-api.net/search` |
| `AI_SEARCH_SUBSCRIPTION_KEY` | APIM subscription key sent as the `api-key` header | Retrieved from Key Vault |
| `AI_SEARCH_INDEX` | Index name | `agent-index` |

On Azure these are set automatically by [`infra/modules/app/app.bicep`](../infra/modules/app/app.bicep). Search traffic goes through the APIM
gateway (single auth surface, rate limits, App Insights): the backend authenticates to APIM with the
subscription key, and **APIM** authenticates to the search service with its managed identity — it holds
**Search Index Data Reader** (query) plus **Search Index Data Contributor** + **Search Service Contributor**
(the ingestion write path: document push + create-index) ([`infra/modules/apim/apim.bicep`](../infra/modules/apim/apim.bicep) →
[`infra/modules/security/search-rbac.bicep`](../infra/modules/security/search-rbac.bicep)). No search admin key exists anywhere.

### File-ingestion settings

The `POST /files` attachment pipeline needs the settings above **plus** the following (all present ⇒
`AgentOptions.HasIngestionConfig`; absent ⇒ `POST /files` returns 503):

| Variable | Description | Example |
|----------|-------------|---------|
| `STORAGE_ACCOUNT_NAME` | Storage account for blob (original + markdown), queue (async pipeline), table (status) — accessed with the App Service's **managed identity**, no key | `stenvtoken` |
| `STORAGE_CONTAINER` | Blob container (created on first use) | `attachments` |
| `DOCINTEL_ENDPOINT` | APIM gateway **root** fronting Document Intelligence (the DI SDK appends `/documentintelligence/...`) | `https://apim-env-token.azure-api.net` |
| `AI_EMBEDDING_DEPLOYMENT` | Embedding deployment used to vectorize chunks + queries (via APIM `/openai`) | `text-embedding-3-large` |
| `MAX_UPLOAD_MB` | Server-side upload cap | `10` |
| `INGESTION_QUEUE` / `INGESTION_STATUS_TABLE` | Queue + status table names (created on first use) | `ingestion` / `ingestionstatus` |

Storage uses **managed identity**, not an account key: `DefaultAzureCredential` authenticates the backend
App Service, which is granted **Storage Blob / Queue / Table Data Contributor** on the account
([`infra/modules/app/app.bicep`](../infra/modules/app/app.bicep) → [`infra/modules/security/storage-rbac.bicep`](../infra/modules/security/storage-rbac.bicep)) — those data roles also cover
creating the container/queue/table on first use. Locally, `DefaultAzureCredential` falls back to your
`az login` (running `dotnet run`) or a service principal supplied via `AZURE_*` env vars.

Document Intelligence is fronted by its own APIM API (declared as the `apimDocIntelApi` module in
[`infra/modules/apim/apim.bicep`](../infra/modules/apim/apim.bicep) from
[`infra/modules/apim/api/document-intelligence-openapi.json`](../infra/modules/apim/api/document-intelligence-openapi.json),
path `documentintelligence`), subscription-key ingress with APIM's managed identity (**Cognitive Services
User**) as the backend auth — mirroring the AI Search API. The DI analyze call is long-running, so the DI
policy ([`infra/modules/apim/policies/document-intelligence-api-policy.xml`](../infra/modules/apim/policies/document-intelligence-api-policy.xml))
rewrites the `Operation-Location` header back to the gateway so the SDK polls the result through APIM.

## The index

> [!IMPORTANT]
> Azure AI Search indexes are a data-plane object and **cannot be declared in Bicep** — only the search
> *service* is provisioned by the infrastructure. The index is created by the ingestion code:
> `SearchIndexer.InitializeAsync` ([`Services/SearchIndexer.cs`](../src/agent_backend/Services/SearchIndexer.cs)) issues an idempotent create-or-update once at
> startup (via `IngestionInitializer`), provisioning the index with the schema below. Schema changes are
> additive — a new field or semantic configuration lands on the next boot without a rebuild, though chunks
> indexed before the change keep their old values until the file is re-ingested.

The index (`agent-index`) is a **hybrid** (keyword + vector) index. Three fields map onto the framework's
`TextSearchProvider.TextSearchResult`; the rest carry the vector and the per-conversation scope:

| Index field | TextSearchResult property | Purpose |
|-------------|---------------------------|---------|
| `id`            | (key)        | Unique chunk id (`{fileId}-{n}`) |
| `title`         | `SourceName` | Human-readable source label — the document's **detected title** (Document Intelligence's title paragraph → first markdown heading → file name without extension) |
| `fileName`      | —            | The original uploaded file name (metadata; retrievable) |
| `sourceUrl`     | — | The original blob URI (stored for reference; **not** used as the citation link — it's private) |
| `fileId`        | `SourceLink` | Surfaced to the model as `attachment://{fileId}`, resolved client-side to the preview endpoint |
| `content`       | `Text`       | The passage text used for grounding |
| `sessionId`     | (filter)     | Conversation the chunk belongs to (scopes retrieval) |
| `fileId`        | (filter)     | The uploaded file the chunk came from (for lifecycle) |
| `contentVector` | (vector)     | 3072-dim embedding of `content` (`text-embedding-3-large`), HNSW profile |

The index also carries a **semantic configuration** (`semantic-config`) prioritizing `title` + `content`,
used by the retrieval query's semantic re-ranker (below).

## The ingestion pipeline

Ingestion is **asynchronous** — the upload returns immediately and the heavy work runs off the request path
in a background worker, so a slow document doesn't hold an HTTP request open.

**Request path** — `POST /files` ([`Endpoints/FilesEndpoints.cs`](../src/agent_backend/Endpoints/FilesEndpoints.cs) → `IngestionService.EnqueueAsync`) accepts
one document plus the `sessionId` and:

1. **Validate** — size first (`MAX_UPLOAD_MB`, enforced on `Content-Length` and on the body read itself, *before*
   the multipart form is buffered), then the file name is sanitised (`SanitizeFileName`: no directory component, no
   control characters, `[A-Za-z0-9._ -]` only, 128 chars max with the extension preserved) and its extension checked
   against `SupportedFileTypes`; else 415/413/400.
2. **Persist original** — `StorageService` uploads to `{container}/{fileId}/{sanitizedName}` (`fileId` = GUID); it
   rejects any path with a `..` segment, a backslash, or a leading `/` as a last line of defense.
3. **Record + enqueue** — writes a `processing` status (`IngestionStatusStore`, Table Storage) and enqueues an
   `IngestionMessage` (`QueueService`, storage queue), then returns **202** `{fileId, status:"processing"}`.

**Worker** — `QueueIngestionWorker` (a `BackgroundService` in the same App Service) consumes the queue and
runs `IngestionService.ProcessAsync`:

4. **Download + to markdown** — downloads the original; already-textual files (txt/csv/md/json/tsv) are used
   verbatim (saved as `output.{ext}`), everything else goes through Azure **Document Intelligence**
   `prebuilt-layout` → markdown (`output.md`), saved to the same `{fileId}/` folder. A **title** is derived
   here: DI's detected title paragraph (binary path) → the first markdown/text heading (`MarkdownTitle`) →
   the file name without its extension.
5. **Chunk** — `MarkdownChunker` splits on markdown paragraph/heading boundaries (~512 tokens, ~10% overlap).
6. **Screen** — the chunks go through Content Safety **Prompt Shields** for embedded instructions (below);
   detection is recorded for review, nothing is withheld from the index.
7. **Embed** — `EmbeddingService` vectorizes the chunks with `text-embedding-3-large` (via APIM `/openai`).
8. **Push** — upload the chunks (tagged with `title`/`fileName`/`sessionId`/`fileId`) to the index that
   `IngestionInitializer` already ensured at startup; finally the status is set to `indexed` (with the chunk
   count).

The worker hides each message for a 5-minute visibility timeout while processing; a transient failure leaves
the message to be redelivered (retry), and after 5 attempts it's marked `failed` and moved to a poison queue.
Reprocessing is safe — chunk ids are deterministic (`{fileId}-{n}`), so a redelivered message overwrites.

### Screening uploads for indirect prompt injection

An uploaded document is untrusted input that ends up *inside the model's context*, so a file can carry
instructions aimed at the assistant rather than content aimed at the reader ("ignore your instructions and…").
The per-turn Content Safety check never sees this — the user's message is innocuous; the payload arrives
through retrieval. So step 6 screens the extracted chunks through `text:shieldPrompt`'s **`documents`**
channel, the parameter built for exactly this (`ContentSafetyService.EvaluateDocumentsAsync`, batches of 5).

Screening is **detective, not preventive**: every chunk is screened, every detection is reported, and the file
is indexed in full regardless. Nothing is rejected, quarantined, or withheld. That is a deliberate choice —
Prompt Shields' `documents` channel returns a bare boolean with no severity or confidence, so there is no
threshold to tune, and it is tuned for short retrieved passages: ordinary imperative security prose ("the user
must type the number displayed on the phone to gain access") reads to it like an injected instruction. Blocking
on that boolean would make routine technical documents unusable. The tradeoff is explicit — a genuine injection
does reach model context, and review happens after the fact.

Every flagged chunk is therefore logged, one Warning per passage, carrying the file name, file id, session,
**chunk index** and count, the chunk length, and the **search document id** (`{fileId}-{n}`) — but never the
passage text itself, which would put document content into App Insights. The **Agent Operations** workbook
surfaces these as the "Flagged passages for review" table.

#### Reviewing a flagged passage

The logged search document id is a **document key**, and the key is the only handle that reaches one specific
chunk: `id` is the index's key field but is *not* filterable, so `$filter=id eq '...'` is rejected by Search
and there is no query that selects a chunk by id. Reviewing a hit therefore means a **key lookup**, which is
why `lookupDocument` (`GET /indexes('{index}')/docs('{key}')`) is in the gateway's OpenAPI allow-list
([`search-openapi.json`](../infra/modules/apim/api/search-openapi.json)) alongside the query operations:

```shell
curl -s -H "api-key: $APIM_SUBSCRIPTION_KEY" \
  "$AI_SEARCH_ENDPOINT/indexes('agent-index')/docs('<fileId>-<chunkIndex>')?api-version=2024-07-01&\$select=id,title,fileName,content" \
  | jq -r .content
```

`$select` is worth keeping — without it the response carries the 3072-dimension `contentVector` and buries the
text. Read-only and covered by the `Search Index Data Reader` role APIM's managed identity already holds; the
API-level policy applies unchanged, so the client key never reaches Search.

If the passage really is hostile, delete the whole attachment (`DELETE /files/{fileId}`), which purges its
chunks, blobs, and status row. There is no per-chunk delete, by design: a document whose content is adversarial
is not made safe by removing the one chunk that happened to trip a boolean detector.

Screening never blocks and never fails a file. It is skipped entirely when Content Safety isn't configured
(`CONTENT_SAFETY_MODE=off`); `log` and `block` behave identically here, since `CONTENT_SAFETY_MODE` governs
only the per-turn check. Like the per-turn check it **fails open**: if the screening call errors the file is
indexed anyway, logged as a fail-open and counted as `stage=document, outcome=failopen` on
`agent.contentsafety.evaluations` — so "no detections" and "never screened" stay distinguishable.

**Status** — the SPA polls `GET /files/{fileId}?sessionId=...` every ~2s until `indexed` or `failed`, and
keeps the prompt box locked while any attachment is still `processing` (failed uploads offer a retry). All
backing services except Blob/Queue/Table Storage are reached through the APIM gateway.

## The retrieval query

`SearchAdapter.SearchAsync` ([`src/agent_backend/Services/SearchAdapter.cs`](../src/agent_backend/Services/SearchAdapter.cs)) runs a **hybrid + semantic
re-ranked** query via the `Azure.Search.Documents` SDK (v11.7.0), pointed at the **APIM gateway** endpoint
with the APIM subscription key as the `api-key` credential: it embeds the query text (`EmbeddingService`) and
pairs a `VectorizedQuery` over `contentVector` with the keyword search, then sets `QueryType = Semantic` with
the index's `semantic-config` so the semantic ranker re-scores the fused (RRF) result set. The query returns
the top **5** passages — a `MaxResults` constant that drives both `Size` and the vector query's
`KNearestNeighborsCount`. Retrieval is
filtered to `sessionId eq '{sessionId}'` — the id read off the active tool invocation's
`FunctionInvokingChatClient.CurrentContext.Options.AdditionalProperties` (put there per-turn by
`ChatService.BuildRunOptions`; `ResolveSessionScope`), failing closed to no grounding when it is absent. It
projects each hit into a
`TextSearchProvider.TextSearchResult { SourceName, SourceLink, Text }` — `SourceName` is the `Title
(fileName.ext)` citation label, `SourceLink` is an `attachment://{fileId}` handle (**not** the private
`sourceUrl` blob URI) — and never throws, so an empty/absent index (or a gateway hiccup) degrades gracefully
to an ungrounded answer:

```csharp
var client = new SearchClient(
    new Uri(_options.AiSearchEndpoint!),        // APIM AI Search API base
    _options.AiSearchIndex!,
    new AzureKeyCredential(_options.AiSearchSubscriptionKey!));

var response = await client.SearchAsync<SearchDocument>(
    query, new SearchOptions { Size = 5 }, cancellationToken);

var results = new List<TextSearchProvider.TextSearchResult>();
await foreach (var hit in response.Value.GetResultsAsync())
{
    results.Add(new TextSearchProvider.TextSearchResult
    {
        SourceName = BuildSourceName(hit.Document.GetString("title"), hit.Document.GetString("fileName")),
        SourceLink = $"attachment://{hit.Document.GetString("fileId")}",
        Text = hit.Document.GetString("content"),
    });
}
return results;
```

If your index uses different field names, update those `GetString` keys — nothing else changes.
`AgentFactory` already constructs the `TextSearchProvider` around this method.

### Clickable citations → file preview

The `CitationsPrompt` in `AgentFactory` tells the model to end its answer with a `Sources` list where each
line is a markdown link `[n] [Title (fileName.ext)](attachment://{fileId})`, reusing each result's provided
`SourceLink` verbatim. `attachment://` is an app-scheme handle carrying only the opaque `fileId`; the SPA
(`Response` renderer) rewrites it to `GET /files/{fileId}/content?sessionId=…` — appending the `sessionId`
and backend base it alone knows — and opens the original file in a floating preview popup (`AttachmentViewer`,
iframe + download fallback). The endpoint proxies the private blob (blobs aren't publicly reachable), scoping
the lookup to the conversation via the `sessionId`-partitioned status row.

## Behavior notes

- **Empty or missing index:** `SearchAdapter` never throws, so the agent still answers (ungrounded).
- **Tool tracking:** when the model calls the tool, `SearchChatAttachments` is returned in the `/chat` response's
  `usedTools` array and can be surfaced in the frontend and Application Insights.
- **On-demand vs. always-on:** the provider runs in `OnDemandFunctionCalling` mode so the model chooses
  when to retrieve. To ground *every* turn, switch to `TextSearchBehavior.BeforeAIInvoke` in
  [`AgentFactory.cs`](../src/agent_backend/Services/AgentFactory.cs).
- **RAG-only grounding mode:** the SPA's settings panel exposes an "Answer only from attachments" toggle
  (`ChatSettings.ragOnly`) sent per turn as the `ragOnly` request field. When set, `ChatService.ApplyGroundingMode`
  appends `AgentFactory.GroundedOnlyDirective` to the turn's instructions, instructing the model to call
  `SearchChatAttachments` for every substantive question and answer strictly from the retrieved passages —
  saying the attached documents don't cover it rather than falling back on general knowledge. Off (default) keeps
  the standard RAG + general-knowledge behavior where the model retrieves only when a question warrants it.

## References

- [Azure AI Search documentation](https://learn.microsoft.com/azure/search/)
- [Microsoft Agent Framework](https://learn.microsoft.com/agent-framework/)
- [Create an Azure AI Search index](https://learn.microsoft.com/azure/search/search-how-to-create-search-index)
- [Vector search in Azure AI Search](https://learn.microsoft.com/azure/search/vector-search-overview)
- [Deployment Guide](./quickstart.md)
