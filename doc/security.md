# Security posture

The standing security record for this repo: what was deliberately left unfixed, and what was examined and found
sound. It exists so a later review — human or agent — does not re-open settled questions.

Provenance: the OWASP-Top-10-for-LLM review and the application/infrastructure review, both dated **2026-08-25**.
The findings they raised (LLM10, LLM01, LLM07, LLM05, and C1–C6) are all implemented; the per-change rationale
lives in the pull requests that landed them (#6–#14). Only the decisions that produced *no* code are recorded here,
because nothing else preserves them.

## Accepted risk

**No authentication, no user scoping.** `GET /chat/sessions` enumerates every conversation in the container,
transcripts and attachments are readable by any caller, and `sessionId` is client-supplied with no ownership
check — so it is also the only unspoofable input the rate limiter could partition on, which is why the global
concurrency/rate pair in `Configuration/RateLimiting.cs` is the real backstop.

This is **deliberate**: the repo is a single-user demo whose purpose is to showcase Microsoft Agent Framework
capabilities. Do not re-flag it.

If it is ever promoted past demo status, the fix is App Service Easy Auth, then a `userId` claim folded into
three places: the Cosmos partition key, the ingestion-status partition key, and the AI Search `sessionId` filter.
Everything else in the codebase is written to hold with or without that change — nothing assumes an
authenticated caller.

## Verified sound — do not re-flag

- **Injection.** Cosmos queries are parameterized throughout (`ConversationStore` uses `QueryDefinition` +
  `WithParameter`); every OData filter is built through `OData.Literal` quote-doubling (`Services/OData.cs`),
  used by `SearchAdapter`, `SearchIndexer`, and `IngestionStatusStore`.
- **Secrets.** None hardcoded. The only key left in app settings is the APIM subscription key, mounted as a Key
  Vault reference; Cosmos, Storage, Search, Document Intelligence, and Content Safety are all managed identity.
  No template calls `listKeys`.
- **Attachment serving.** `GET /files/{fileId}/content` derives its content type from the validated extension,
  serves only an inline allowlist, forces `attachment` for everything else, and sets `nosniff`.
- **SPA rendering.** `AttachmentViewer` renders uploaded HTML in a `sandbox=""` iframe (no scripts, no
  same-origin). `response.tsx` uses `react-markdown` without `rehype-raw` and preserves its `defaultUrlTransform`
  for every scheme except `attachment://`.
- **Transport.** No TLS-validation overrides, no weak hashes, no `HttpClientHandler` customization.
- **Gateway.** All four APIM policies strip client-supplied `api-key` / `Ocp-Apim-Subscription-Key` before
  injecting the managed identity, so a caller cannot present its own credential to a backend service.
- **CI.** Both GitHub workflows are `workflow_dispatch`-only, use OIDC federation, and interpolate no untrusted
  expressions into `run:` blocks.
- **RAG scope.** `SearchAdapter.ResolveSessionScope` fails closed: no session scope means no grounding, never an
  unfiltered cross-session query.
- **Telemetry.** `EnableSensitiveData = false` on the OTel pipeline; the retrieval audit manifest and the
  ingestion screening warnings log identifiers, scores, and lengths only — never passage text. System-prompt
  overrides are audited by length and `sessionId`, never text.
