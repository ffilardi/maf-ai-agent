# Features

## AI Agent Backend (Microsoft Agent Framework)

The agent backend is an ASP.NET Core (.NET 10) minimal API that implements an intelligent AI agent using the [Microsoft Agent Framework](https://learn.microsoft.com/agent-framework/) (`Microsoft.Agents.AI`) with the following capabilities:

- **Agent Framework Integration:** Built on `Microsoft.Agents.AI` for orchestrating AI interactions, with a single shared agent (`maf-agent`) constructed once at startup
- **Azure OpenAI via APIM:** Connects to Azure OpenAI models through the API Management gateway for enterprise-grade security and load balancing
- **Retrieval-Augmented Generation (RAG):** Grounds answers on an Azure AI Search index via the framework's `TextSearchProvider`, exposed to the model as an on-demand `SearchChatAttachments` tool (see the [RAG Guide](./rag.md)). A per-turn **RAG-only toggle** ("Answer only from attachments" in the settings panel, sent as `ragOnly`) restricts answers to retrieved passages with no general-knowledge fallback
- **Conversation Memory:** Cosmos DB-backed conversation persistence via the built-in `CosmosChatHistoryProvider` for maintaining context across sessions — transcripts persist indefinitely (the provider's 24h TTL is disabled) so users can resume days later, with the per-turn Cosmos read capped by `MAX_HISTORY_MESSAGES`. Only user turns + assistant answers are stored: tool-call/tool-result messages are filtered out before persistence (`StripToolPlumbing`), keeping each turn's write under Cosmos's 2 MB batch limit — the raw tool results are audited to App Insights instead (see [Logging](./logging.md))
- **Context Compaction:** Keeps long conversations within the model's context window and bounds per-turn prompt cost via a MAF compaction pipeline — collapses in-context RAG tool-result dumps, then applies a token-budget truncation backstop (see [`overview.md`](overview.md) › *Bounding history*)
- **Tool Tracking:** Derives the tools used per turn from the response's `FunctionCallContent` (returned as `usedTools`)
- **Token Usage Reporting:** Captures and reports token consumption metrics from AI model calls
- **User Context Support:** Optional user name tracking in conversation history
- **Health Checks:** `/ping` endpoint for health monitoring

**Key Components:**

- [`Program.cs`](../src/agent_backend/Program.cs) - Minimal API host, DI wiring, and the `/chat`, `/ping`, `/` endpoints
- [`Services/AgentFactory.cs`](../src/agent_backend/Services/AgentFactory.cs) - Builds the shared `AIAgent` (Azure OpenAI via APIM + optional Cosmos history + optional AI Search `TextSearchProvider`)
- [`Services/ChatService.cs`](../src/agent_backend/Services/ChatService.cs) - Runs the agent per request, maps token usage and `usedTools`, and translates provider errors to HTTP status codes
- [`Services/SearchAdapter.cs`](../src/agent_backend/Services/SearchAdapter.cs) - Azure AI Search retrieval backend for the RAG `SearchChatAttachments` tool
- [`Configuration/AgentOptions.cs`](../src/agent_backend/Configuration/AgentOptions.cs) - Strongly-typed environment configuration with `HasApimConfig`/`HasCosmosConfig`/`HasAiSearchConfig` guards
- [`Models/ChatModels.cs`](../src/agent_backend/Models/ChatModels.cs) - `ChatRequest`/`ChatResponse`/`TokenUsage` records with pinned JSON wire names

## AI Agent Frontend

The agent frontend is a Vite + React (TypeScript) single-page app providing a user interface for interacting with the AI agent. It calls the backend directly from the browser (CORS) and streams answers with the Vercel AI SDK (`@ai-sdk/react`):

- **Web Chat Interface:** Modern, responsive chat UI with real-time token streaming (AI SDK UI Message Stream protocol)
- **Session Management:** Conversation id persisted in `localStorage`; backend owns history in Cosmos (Milestone 1 is a single conversation)
- **Direct Backend Calls:** No proxy tier — the SPA POSTs to the backend's `/chat/stream` and the browser reads the stream
- **Tool Visibility:** Displays which tools were used for each response (from `message.metadata`)
- **Token Metrics:** Shows token usage statistics when available

**Key Files:**

- [`src/components/Chat.tsx`](../src/agent_frontend/src/components/Chat.tsx) - `useChat` wiring + custom transport (`{sessionId, chatInput, userName}` contract)
- `src/components/ai-elements/*` - Conversation / Message / Response / PromptInput (AI Elements-shaped)
- [`src/lib/backend.ts`](../src/agent_frontend/src/lib/backend.ts), [`src/lib/session.ts`](../src/agent_frontend/src/lib/session.ts) - backend URL/types and the persisted conversation id
- [`scripts/gen-swa-config.mjs`](../src/agent_frontend/scripts/gen-swa-config.mjs) - generates `public/staticwebapp.config.json` on `prebuild`: SPA fallback routing for Azure Static Web Apps plus the security `globalHeaders` (CSP naming the provisioned backend origin, `nosniff`, `x-frame-options`, `referrer-policy`, `permissions-policy`, HSTS)

## Azure Infrastructure Services

### API Management (APIM)

- **AI Foundry API:** Proxies requests to multiple Azure AI Foundry model deployments with intelligent load balancing
- **Managed Identity Authentication:** Passwordless authentication to Azure OpenAI using system-assigned managed identity
- **Multi-Layered Rate Limiting:**
  - Request-based: 300 requests/minute, 18,000 requests/hour per subscription (below combined model RPM capacity)
  - Token-based: 500,000 tokens/minute, 30M tokens/hour per subscription (below combined model TPM capacity)
- **Token Metrics:** Real-time token consumption tracking and quota monitoring
- **Subscription Key Security:** All endpoints secured via APIM subscription keys (`api-key` header/query parameter)
- **Application Insights Integration:** Full diagnostics and logging of API calls with custom token metrics
- **Policy-Based Routing:** Advanced routing policies for model endpoint selection and load balancing
- **Response Headers:** Rate limit and quota information included in every response

See [APIM Policies](./apim-policies.md) for detailed policy documentation.

### AI Services

- **AI Foundry Hub & Project:** Azure AI Foundry hub with project (`proj-{env}-01`) for AI model deployments
- **Model Deployments:** gpt-5.4-mini and text-embedding-3-large (GlobalStandard SKUs, multiple instances for load balancing)
- **Azure AI Search:** Free-tier search service hosting the RAG grounding index (queried by the backend's `SearchChatAttachments` tool); runs hybrid + semantic ranking in supported regions — bump `skuName` to `basic` in `infra/modules/search` for production scale/SLA
- **Managed Identity Access:** RBAC-based access using system-assigned managed identities

### Common Services

- **Key Vault:** Centralized secret management for API keys, connection strings, and credentials
- **Cosmos DB:** NoSQL database with:
  - Database: `agent_db`
  - Container: `conversations` (partitioned by `/conversationId`)
  - Used for conversation history persistence via the built-in `CosmosChatHistoryProvider` (user turns + assistant answers only; tool results are excluded and audited to App Insights)
- **Storage Account:** Blob, queue, table and file services for general storage needs

### Application Services

- **App Service Plan:** Linux-based plan hosting the backend (the frontend needs no plan)
- **Frontend Static Web App:** Hosts the agent frontend SPA (Vite/React, `Microsoft.Web/staticSites`, Free SKU — no server tier)
- **Backend Web App:** Hosts the agent backend (.NET 10 / ASP.NET Core with Microsoft Agent Framework, `DOTNETCORE|10.0`)
- **Deploy:** azd deploys the backend as a .NET code deploy and the frontend's built `dist/` to Static Web Apps

### Monitoring Services

- **Log Analytics Workspace:** Centralized log aggregation for all services
- **Application Insights:** APM solution capturing:
  - HTTP request/response telemetry
  - Agent performance metrics (MAF GenAI spans — LLM calls, tool invocations, token usage; message content excluded)
  - Token usage statistics
  - Custom events and traces — including the **RAG retrieval audit trail** (which files/chunks grounded each answer) and chat persist-failure errors (see [Logging](./logging.md))
- **Workbooks:** Three Azure Monitor workbooks — an **Agent Operations** workbook (request health, per-backend dependencies, RAG retrieval audit, Content Safety detections, persist failures, and GenAI spans — see [Logging](./logging.md)), a **Token & Cost Insights** workbook for token/cost showback (see [FinOps](./finops.md)), and an **API Gateway Operations** workbook over the `ApiManagementGatewayLogs` table (per-API and per-endpoint success/failure, response-time percentiles, error reasons, throttling, per-caller consumption — see [APIM & Azure Monitor](./apim-azure-monitor.md))

> [!NOTE]
> Both web apps are deployed with managed identities and have RBAC permissions to access Key Vault, Cosmos DB, and AI Foundry resources.

## Security

This template uses [Managed Identity](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/overview) and Key Vault for secure, passwordless authentication. System-assigned managed identities are configured for both web apps and API Management, with RBAC roles granting least-privilege access to Azure resources.

**Gateway exposure:**

The APIM gateway is public by default and is the only internet-facing surface in front of the AI services. It is guarded in layers:

| Layer | Control |
|---|---|
| Transport | HTTPS-only protocols; TLS 1.0/1.1 and SSL 3.0 plus weak ciphers disabled on both frontend and backend ([`service.bicep`](../infra/modules/apim/resources/service.bicep)) |
| Surface | Only the operations declared in each imported OpenAPI document exist. Any other path is rejected by the gateway with `404` before policy evaluation — the lean definitions *are* the allow-list |
| Authentication | Every API sets `subscriptionRequired: true`. A request without a valid key is rejected with `401`, also before inbound policy evaluation |
| Authorization | The key comes from the `/apis`-scoped `ai-gateway` subscription, so it reaches every imported API but never the APIM management surface |
| Backend auth | APIM injects its own managed identity toward AI Foundry, Document Intelligence, Content Safety, and AI Search — no service admin keys exist to leak |
| Network *(opt-in)* | A service-scope `ip-filter` allow-list can pin the gateway to the backend App Service's outbound IPs, no VNet required — `restrictGatewayToBackend`, default `false` |

Because unmatched paths and keyless requests are both rejected ahead of policy evaluation, opportunistic internet scanning cannot be filtered by policy — it is already being rejected, and its only real cost is log ingestion. The `ip-filter` layer is **leaked-key containment**, not scanner suppression. See [APIM Policies](./apim-policies.md) › *Service-Scope Policy* for what enabling it breaks (local development, the APIM test console) and why the outbound IP list is not permanent.

**RBAC Permissions:**

| Service         | Access to       | Role(s) Assigned                                          |
|-----------------|-----------------|-----------------------------------------------------------|
| Frontend App    | Key Vault       | Key Vault Secrets User                                    |
| Backend App     | Key Vault       | Key Vault Secrets User                                    |
| Backend App     | Cosmos DB       | Cosmos DB Operator; Cosmos DB Account Reader Role         |
| Backend App     | AI Search       | Search Index Data Reader                                  |
| Backend App     | AI Foundry      | Azure AI User (via APIM)                                  |
| API Management  | Key Vault       | Key Vault Secrets User                                    |
| API Management  | AI Foundry      | Routes to multiple AI model deployments                   |
| AI Foundry      | Key Vault       | Key Vault Secrets User                                    |
| AI Foundry      | Cosmos DB       | Cosmos DB Operator; Cosmos DB Account Reader              |
| AI Foundry      | Storage Account | Storage Blob Data Contributor                             |

**Key Vault Secrets:**

- `apim-aifoundry-api-key` - APIM subscription key for AI Foundry API access. Sourced from a dedicated `ai-gateway` subscription scoped to `/apis` (all imported APIs), **not** the built-in `master` subscription — least-privilege, so the key cannot reach the APIM management/admin surface.
- `ai-search-key` - Azure AI Search admin key for the RAG index

**Environment Variables:**
The backend agent requires the following configuration (set via App Service settings):

- `APIM_GATEWAY_ENDPOINT` - API Management gateway URL
- `APIM_SUBSCRIPTION_KEY` - APIM subscription key (from Key Vault)
- `AI_MODEL_DEPLOYMENTS` - Comma-separated selectable chat model deployments (first is the default)
- `AGENT_INSTRUCTIONS` - Overrides the built-in default system prompt (optional)
- `EXPOSE_DEFAULT_PROMPT` - Advertise the effective base prompt on `GET /config` (default `true`; the Azure deploy sets `false`)
- `ALLOW_SYSTEM_PROMPT_OVERRIDE` - Honour a per-request `systemPrompt` (default `true`)
- `COSMOS_ENDPOINT` - Cosmos DB account endpoint
- `COSMOS_USE_RBAC` - Authenticate to Cosmos with the App Service's managed identity (default `true`; the deploy sets it explicitly and no Cosmos key is stored anywhere)
- `COSMOS_KEY` - Cosmos DB access key. Only read when `COSMOS_USE_RBAC=false`
- `COSMOS_DB` - Database name (default: `agent_db`)
- `COSMOS_CONTAINER` - Container name (default: `conversations`)
- `AI_SEARCH_ENDPOINT` - APIM AI Search API base (search routes through the gateway; enables the RAG `SearchChatAttachments` tool when set)
- `AI_SEARCH_SUBSCRIPTION_KEY` - APIM subscription key, sent as the `api-key` header (from Key Vault)
- `AI_SEARCH_INDEX` - Azure AI Search index name (default: `agent-index`)
- `APPLICATIONINSIGHTS_CONNECTION_STRING` - Application Insights connection string
