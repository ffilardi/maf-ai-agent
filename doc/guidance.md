# Guidance

## Region Availability

This template deploys Azure AI Foundry with model a deployment (gpt-5.6-luna) which may not be available in all regions. Check the current model availability and choose a supported region:

- **Model availability:** <https://learn.microsoft.com/azure/ai-services/openai/concepts/models#standard-deployment-model-availability>
- **Region selection:** Pick a region supporting "GlobalStandard" SKU for your required models
- **Recommended regions:** East US, East US 2, Australia East, West Europe

## Quotas

Ensure your subscription has sufficient quota for Azure OpenAI model deployments:

- **Azure OpenAI quotas:** <https://learn.microsoft.com/azure/ai-services/openai/quotas-limits>
- **Request increases:** Azure portal > Help + support > Service and subscription limits (quotas)
- **TPM Requirements:** Each model deployment requires quota allocation (Tokens Per Minute)

## Required Dependencies

**Backend Dependencies (.NET / Microsoft Agent Framework):**

- `Microsoft.Agents.AI` - Microsoft Agent Framework core
- `Microsoft.Agents.AI.OpenAI` - Azure OpenAI chat client integration
- `Microsoft.Agents.AI.CosmosNoSql` - Built-in `CosmosChatHistoryProvider` conversation memory
- `Azure.AI.OpenAI` - Azure OpenAI SDK
- `Azure.Identity` - Azure authentication
- `Azure.Search.Documents` - Azure AI Search query client (add when implementing the real `SearchAdapter` RAG query)

**Frontend Dependencies (Vite + React + TypeScript):**

- `react` / `react-dom` - UI runtime
- `@ai-sdk/react` + `ai` - Vercel AI SDK `useChat` + UI Message Stream protocol client
- `vite` + `@vitejs/plugin-react` - build/dev tooling
- `tailwindcss` (+ `@tailwindcss/vite`), `clsx`, `tailwind-merge`, `lucide-react` - styling/icons

## Environment Configuration

**Required for Backend:**

| Variable | Description | Example |
|----------|-------------|---------|
| `APIM_GATEWAY_ENDPOINT` | API Management gateway URL | `https://apim-env-token.azure-api.net` |
| `APIM_SUBSCRIPTION_KEY` | APIM subscription key | Retrieved from Key Vault |
| `AI_MODEL_DEPLOYMENTS` | Comma-separated selectable chat models; first is the default | `gpt-5.6-luna` |
| `AGENT_INSTRUCTIONS` | Overrides the built-in default system prompt (optional) | _(built-in default)_ |
| `EXPOSE_DEFAULT_PROMPT` | Advertise the effective base prompt on `GET /config`; `false` returns `""` (Azure sets `false`) | `true` |
| `ALLOW_SYSTEM_PROMPT_OVERRIDE` | Honour a per-request `systemPrompt`; `false` ignores it and logs the attempt | `true` |
| `COSMOS_ENDPOINT` | Cosmos DB endpoint | `https://cosmos-env-token.documents.azure.com:443/` |
| `COSMOS_USE_RBAC` | Authenticate to Cosmos with Entra ID (`DefaultAzureCredential`) instead of an account key. The Azure deploy sets `true` | `true` |
| `COSMOS_KEY` | Cosmos DB key. Only read when `COSMOS_USE_RBAC=false` (the rollback path) | _(unset)_ |
| `COSMOS_DB` | Database name | `agent_db` |
| `COSMOS_CONTAINER` | Container name | `conversations` |
| `MAX_HISTORY_MESSAGES` | Caps the most-recent messages read from Cosmos per turn (RU/latency guard) | `100` |
| `MAX_CONTEXT_WINDOW_TOKENS` | Model context window — feeds the in-context compaction token budget | `128000` |
| `MAX_OUTPUT_TOKENS` | Reserved output tokens — subtracted from the window for the compaction budget | `16384` |
| `AI_SEARCH_ENDPOINT` | APIM AI Search API base — search is reached only through the gateway (enables the RAG `SearchChatAttachments` tool) | `https://apim-env-token.azure-api.net/search` |
| `AI_SEARCH_SUBSCRIPTION_KEY` | APIM subscription key (sent as the `api-key` header) | Retrieved from Key Vault |
| `AI_SEARCH_INDEX` | Azure AI Search index name | `agent-index` |
| `ALLOWED_ORIGINS` | CORS allow-list for the SPA origin (comma-separated) | `https://{swa}.azurestaticapps.net` |

**Required for Frontend (build-time, baked into the SPA bundle by Vite):**

| Variable | Description | Example |
|----------|-------------|---------|
| `VITE_AGENT_BACKEND_URL` | Backend base URL the browser calls directly | `http://localhost:8000` |

## Monitoring and Troubleshooting

**Application Insights:**

- View agent request traces in Application Insights > Transaction search
- Monitor token usage via custom metrics
- Track tool invocations (e.g. the `SearchChatAttachments` tool) via the `usedTools` field and custom events
- Set up alerts for error rates or high latency

**Logging:**
All services log to Application Insights with structured logging:

- Request/response payloads (filtered for sensitive data)
- Tool/plugin invocation tracking
- Error traces with stack traces
- Performance metrics

**Common Issues:**

1. **"Agent not ready" error:**
   - Check that APIM_GATEWAY_ENDPOINT and APIM_SUBSCRIPTION_KEY are set
   - Verify AI model deployment exists and is accessible via APIM

2. **"Conversation store not configured":**
   - Ensure COSMOS_ENDPOINT is set, plus COSMOS_KEY if you set `COSMOS_USE_RBAC=false`
   - Verify Cosmos DB database and container exist
   - With RBAC (the default), a 403 on the first turn means the caller's principal is missing the **Cosmos DB
     Built-in Data Contributor** SQL role — a data-plane role that the control-plane ones don't imply

3. **RAG `SearchChatAttachments` tool not used / no grounding:**
   - Ensure `AI_SEARCH_ENDPOINT`, `AI_SEARCH_SUBSCRIPTION_KEY`, and `AI_SEARCH_INDEX` are all set (the tool stays dormant unless all three are present)
   - Verify the index exists and is populated (an empty index degrades to an ungrounded answer)

4. **Token usage not reported:**
   - Ensure model responses include usage metadata
   - Check Application Insights for token metrics

5. **Rate limit errors (429 responses):**
   - Check response headers for rate limit information:
     - `x-apim-ratelimit-remaining-tokens` - Tokens left in current minute
     - `x-apim-ratelimit-remaining-quota-tokens` - Tokens left in hourly quota
   - Consider adjusting policy limits in [`foundry-api-policy.xml`](../infra/modules/apim/policies/foundry-api-policy.xml)
   - Review per-subscription usage in Application Insights

6. **Managed identity authentication failures:**
   - Verify APIM has system-assigned managed identity enabled
   - Ensure RBAC role "Cognitive Services User" is assigned to APIM identity
   - Check APIM policy configuration for correct resource URL

7. **`403 Forbidden` from the gateway with a valid subscription key:**
   - The service-scope `ip-filter` is active (`restrictGatewayToBackend` is `true`) and the caller is not on the allow-list
   - Expected when running the backend locally or using the APIM test console — add the caller's IP to `additionalGatewayAllowedIps`
   - After changing the App Service Plan tier, or if Azure migrated the app, the backend's `possibleOutboundIpAddresses` have rotated — re-run `azd provision` to refresh the allow-list
   - `ApiManagementGatewayLogs | where ResponseCode == 403 | project TimeGenerated, CallerIpAddress, Url, LastErrorReason` in Log Analytics shows which addresses were blocked

## Security Best Practices

1. **Never commit secrets** - Use Key Vault for all sensitive configuration
2. **Use managed identities** - Enable system-assigned identities for all Azure services
3. **Apply least privilege** - Grant only necessary RBAC roles
4. **Enable diagnostic logs** - Send all logs to Log Analytics
5. **Rotate keys regularly** - Use Key Vault secret versioning
6. **Secure APIM endpoints** - Always require subscription keys (`subscriptionRequired: true` on every imported API)
7. **Monitor access** - Review Key Vault and Cosmos DB access logs
8. **Keep the OpenAPI definitions lean** - Only the declared operations exist at the gateway; every other path is rejected with `404` before any policy runs, so the definition is the real attack-surface allow-list
9. **Contain a leaked gateway key** - Set `restrictGatewayToBackend` to `true` to apply a service-scope `ip-filter` over the backend App Service's outbound IPs, restricting the gateway to the backend without a VNet — see [`apim-policies.md`](apim-policies.md) › *Service-Scope Policy*. Layer it under the subscription key, never instead of it
10. **Expect internet background noise** - A public gateway attracts opportunistic scanning for unsecured endpoints and leaked files. Those requests never match an imported API and never carry a key, so they are already being rejected; they are a log-ingestion cost, not an exposure. Tune with `enableVerboseLogs` rather than with policy

## Performance Optimization

1. **Conversation history bounding** - Two complementary layers, both set in `AgentFactory.Create`: `MAX_HISTORY_MESSAGES` caps how many messages the `CosmosChatHistoryProvider` reads per turn (Cosmos RU/latency), and an in-context compaction pipeline (`ToolResultCompactionStrategy` → `ContextWindowCompactionStrategy`, budget from `MAX_CONTEXT_WINDOW_TOKENS` − `MAX_OUTPUT_TOKENS`) trims what the model sees to control prompt size — see [`overview.md`](overview.md) › *Bounding history*
2. **APIM caching** - Consider caching policies for frequently accessed endpoints
3. **Model selection** - Use gpt-5.6-luna for faster, cost-effective responses when appropriate
4. **Concurrent requests** - APIM load balances across multiple model deployments
5. **Connection pooling** - Cosmos DB client reuses connections automatically
6. **Rate limit tuning** - Adjust APIM policy limits based on actual usage patterns:
   - Monitor rate limit headers in responses
   - Align token limits with Azure OpenAI TPM quota
   - Consider per-subscription limits for multi-tenant scenarios
7. **Token optimization** - Minimize token usage:
   - Limit conversation history (`MAX_HISTORY_MESSAGES` + compaction)
   - Use concise system prompts
   - Implement prompt caching where applicable
   - Monitor token metrics in Application Insights

**Performance Monitoring:**

- Track `x-apim-ratelimit-consumed-tokens` header for per-request token usage
- Monitor Application Insights for token consumption trends
- Set up alerts for approaching rate limits or quota thresholds
- Review backend pool distribution in APIM analytics
