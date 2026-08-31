# Quickstart

## Provisioning

1. In the VS Code (local or VS Code for web, if using Codespace via browser), open a terminal window.
2. Sign into your Azure account:

    ```shell
     azd auth login --use-device-code
    ```

3. Initialize the environment (optional):

    ```shell
    azd init
    ```

4. Provision Azure resources and deploy the app code:

    ```shell
    azd up
    ```
    
    This will:
    - Prompt for environment name (if not initialised yet)
    - Prompt for Azure subscription and region (if not selected yet)
    - Provision all Azure resources (App Service, APIM, AI Foundry, Cosmos DB, Key Vault, Storage, Monitoring)
    - Deploy both frontend and backend applications
    - Configure APIM endpoints and AI model load balancing

> [!NOTE]
> Alternative deployment methods:
> - For infra provisioning only, use `azd provision`
> - For code deployment only, use `azd deploy`

5. Configure GitHub CI/CD pipeline (optional, when using your own repository):

    ```shell
    azd pipeline config
    ```

6. Test the web application using a browser
    - Visit the frontend URL (typically `https://app-frontend-{env}-{token}.azurewebsites.net`)
    - Start a conversation with the AI agent
    - Ask questions about content indexed in Azure AI Search (the agent grounds answers via the `SearchChatAttachments` tool)
    - Observe which tools are used for each response

7. Monitor the application
    - Open Application Insights in the Azure portal
    - View real-time metrics, request traces, and custom events
    - Open the **Agent Operations** workbook (Application Insights → Workbooks) for request health, dependency latency, the RAG retrieval audit, and Content Safety detections
    - Open the **API Gateway Operations** workbook (Log Analytics workspace → Workbooks) for per-API and per-endpoint success/failure counts, response times, throttling, and per-caller consumption

## Local Development

Run the two services separately: the backend with the .NET SDK and the frontend with the Vite dev
server. The SPA calls the backend directly from the browser (CORS) — there is no proxy tier.

Common environment variables (see [`src/.env.example`](../src/.env.example) for the full list):
```env
APIM_GATEWAY_ENDPOINT=https://{apim-instance}.azure-api.net
APIM_SUBSCRIPTION_KEY={your-subscription-key}
AI_MODEL_DEPLOYMENTS={deployment-name}
COSMOS_ENDPOINT=https://{cosmos-account}.documents.azure.com:443/
# Cosmos authenticates with Entra ID by default; your az login needs the Cosmos DB Built-in Data
# Contributor SQL role (see getting-started.md). Set COSMOS_USE_RBAC=false + COSMOS_KEY to use a key.
COSMOS_DB=agent_db
COSMOS_CONTAINER=conversations
AI_SEARCH_ENDPOINT=https://{apim-instance}.azure-api.net/search
AI_SEARCH_SUBSCRIPTION_KEY={your-subscription-key}
AI_SEARCH_INDEX=agent-index
# The SPA calls the backend directly from the browser (CORS) — no proxy tier.
ALLOWED_ORIGINS=http://localhost:5173
VITE_AGENT_BACKEND_URL=http://localhost:8000
```

### Backend Development

Run the backend agent directly with the .NET SDK:

```shell
cd src/agent_backend

# Configure environment variables
export APIM_GATEWAY_ENDPOINT="https://{apim-instance}.azure-api.net"
export APIM_SUBSCRIPTION_KEY="{your-subscription-key}"
export AI_MODEL_DEPLOYMENTS="{deployment-name}"
export COSMOS_ENDPOINT="https://{cosmos-account}.documents.azure.com:443/"
# Entra ID by default (see getting-started.md for the SQL role grant); or COSMOS_USE_RBAC=false + COSMOS_KEY
export AI_SEARCH_ENDPOINT="https://{apim-instance}.azure-api.net/search"
export AI_SEARCH_SUBSCRIPTION_KEY="{your-subscription-key}"
export AI_SEARCH_INDEX="agent-index"
# Allow the SPA's origin through CORS (browser → backend directly)
export ALLOWED_ORIGINS="http://localhost:5173"

# Restore and run (listens on port 8000 by default)
dotnet run
```

The backend will be available at `http://localhost:8000` with:
- Chat endpoint: `POST /chat`
- Health check: `GET /ping`
- Root: `GET /` (returns the .NET version)

### Frontend Development

Run the SPA dev server separately (needs Node 20+):

```shell
cd src/agent_frontend
npm install

# Point the browser at the backend it calls directly (CORS)
export VITE_AGENT_BACKEND_URL="http://localhost:8000"

# Vite dev server with hot reload
npm run dev
```

Access the chat interface at `http://localhost:5173`. Make sure the backend was started with
`ALLOWED_ORIGINS=http://localhost:5173` so the browser's cross-origin requests are accepted.

### Testing the Chat API Directly

You can test the backend chat endpoint using curl:

```shell
curl -X POST "http://localhost:8000/chat" \
  -H "Content-Type: application/json" \
  -d '{
    "sessionId": "test-session-123",
    "chatInput": "What is Azure App Service?",
    "userName": "TestUser"
  }'
```

Expected response:
```json
{
  "sessionId": "test-session-123",
  "answer": "Azure App Service is...",
  "usedTools": ["Search"],
  "tokenUsage": {
    "prompt_tokens": 150,
    "completion_tokens": 85,
    "total_tokens": 235
  }
}
```

### RAG (Azure AI Search) Development

The backend grounds answers using the Agent Framework's `TextSearchProvider`, exposed to the model as
an on-demand `SearchChatAttachments` tool. Retrieval is implemented in [`Services/SearchAdapter.cs`](../src/agent_backend/Services/SearchAdapter.cs), which queries Azure
AI Search **through the APIM gateway** (endpoint = APIM AI Search API base, credential = APIM subscription
key as the `api-key` header; APIM reaches the search service with its managed identity):

```csharp
// Services/SearchAdapter.cs — returns grounding passages for the RAG "Search" tool.
var client = new SearchClient(
    new Uri(_options.AiSearchEndpoint!),        // APIM AI Search API base
    _options.AiSearchIndex!,
    new AzureKeyCredential(_options.AiSearchSubscriptionKey!));

var response = await client.SearchAsync<SearchDocument>(
    query, new SearchOptions { Size = 5 }, cancellationToken);
// ... project each hit's title/sourceUrl/content into TextSearchResult { SourceName, SourceLink, Text }.
```

The provider is wired in [`Services/AgentFactory.cs`](../src/agent_backend/Services/AgentFactory.cs) only when all three `AI_SEARCH_*` settings are
present (`HasAiSearchConfig`), so the `SearchChatAttachments` tool is advertised to the model just when it can be
fulfilled. See the [RAG Guide](./rag.md) for the full retrieval/indexing walkthrough.

## Extending the Solution

### Adding New Infrastructure Resources

The solution follows a modular Bicep architecture:

```
infra/
├── main.bicep                 # Main orchestration file
├── main.parameters.json       # Environment-specific parameters
└── modules/
    ├── foundry/               # AI Foundry & model deployments
    ├── apim/                  # API Management configuration
    │   ├── api/               # API definitions (OpenAPI/Swagger)
    │   ├── policies/          # APIM policy XML files
    │   └── resources/         # APIM service Bicep modules
    ├── app/                   # App Service resources
    ├── cosmosdb/              # Cosmos DB configuration
    ├── search/               # Azure AI Search (RAG index host)
    ├── keyvault/              # Key Vault configuration
    ├── monitor/               # Monitoring and logging
    ├── security/              # RBAC configurations
    └── storage/               # Storage account configuration
```

To add new Azure services:

1. Create or reuse a module under `infra/modules/<service>/`
2. Reference the module from [`infra/main.bicep`](../infra/main.bicep)
3. Grant RBAC permissions via security modules (`infra/modules/security/`)
4. Update [`main.parameters.json`](../infra/main.parameters.json) with any required parameters
5. Add necessary outputs for application configuration

**Example: Adding a new storage service**
```bicep
// In infra/main.bicep
module newStorage './modules/storage/storage.bicep' = {
  name: 'new-storage'
  scope: resourceGroup(commonResourceGroupName)
  params: {
    location: location
    tags: tags
    storageName: 'stnew${token}'
  }
}
```

### Adding Agent Tools

To extend agent capabilities with a new tool (function calling), add an `AIFunction` when building the
agent in [`Services/AgentFactory.cs`](../src/agent_backend/Services/AgentFactory.cs):

1. **Define the tool method:**
```csharp
[Description("Your function description")]
static string MyFunction([Description("A parameter")] string parameter)
    => $"result for {parameter}";
```

2. **Register it on the agent's `ChatOptions.Tools`:**
```csharp
// In Services/AgentFactory.cs, when constructing ChatClientAgentOptions
chatOptions.Tools ??= new List<AITool>();
chatOptions.Tools.Add(AIFunctionFactory.Create(MyFunction));
```

3. **Update agent instructions if needed** (the `AGENT_INSTRUCTIONS` constant in [`AgentFactory.cs`](../src/agent_backend/Services/AgentFactory.cs)) so
   the model knows when to use the new capability.

### Customizing Conversation Storage

Conversation memory is provided by the framework's built-in `CosmosChatHistoryProvider`
(wired in [`Services/AgentFactory.cs`](../src/agent_backend/Services/AgentFactory.cs) via `WithCosmosDBChatHistoryProvider`). It owns its own document
schema and partitions on `/conversationId`. To customize persistence, adjust the provider configuration
there, or supply a different `AIContextProvider` implementation.

`AgentFactory` also tunes two provider knobs the extension doesn't expose: it caps the per-turn Cosmos
read at `MAX_HISTORY_MESSAGES` (default 100, via `MaxMessagesToRetrieve`) and disables the provider's
default 24h expiry (`MessageTtlSeconds = null`) so transcripts persist indefinitely. On top of that it
appends a `CompactionProvider` that trims the loaded history in-context before each model call — collapsing
old RAG tool-result dumps then applying a token-budget backstop sized by `MAX_CONTEXT_WINDOW_TOKENS` −
`MAX_OUTPUT_TOKENS`. See [`overview.md`](overview.md) › *Bounding history* for how the layers interact.

### Modifying APIM Policies

APIM policies control request routing, authentication, rate limiting, and transformation. The main policy file is located at [`infra/modules/apim/policies/foundry-api-policy.xml`](../infra/modules/apim/policies/foundry-api-policy.xml).

**Key Policy Components:**

1. **Authentication (Managed Identity)**
```xml
<authentication-managed-identity
    resource="https://cognitiveservices.azure.com/"
    output-token-variable-name="managed-id-access-token"
/>
```

2. **Rate Limiting (Requests)**
```xml
<rate-limit-by-key calls="300" renewal-period="60" />
<quota-by-key calls="18000" renewal-period="3600" />
```

3. **Token Limiting**
```xml
<llm-token-limit
    tokens-per-minute="500000"
    token-quota="30000000"
    token-quota-period="Hourly"
/>
```

**Common Customizations:**

**Increase rate limits for higher traffic:**
```xml
<rate-limit-by-key
    calls="500"
    renewal-period="60"
    counter-key="@(context.Subscription?.Key ?? "anonymous")"
/>
```

**Add custom headers to requests:**
```xml
<inbound>
    <base />
    <set-header name="X-Custom-Header" exists-action="override">
        <value>custom-value</value>
    </set-header>
    <!-- ... rest of policies -->
</inbound>
```

**Add request/response logging:**
```xml
<outbound>
    <base />
    <log-to-eventhub>
        @{
            return new JObject(
                new JProperty("request-id", context.RequestId),
                new JProperty("subscription-key", context.Subscription?.Key),
                new JProperty("tokens-consumed", context.Variables["tokens-consumed"])
            ).ToString();
        }
    </log-to-eventhub>
</outbound>
```

**Testing Policy Changes Locally:**

Before deploying, you can test policy expressions using APIM's policy test console in the Azure Portal:
1. Navigate to your APIM instance
2. Select APIs > AI Foundry API
3. Select "All operations" or specific operation
4. Click "Test" tab
5. Modify policies inline and test with sample requests

After modifying policies, redeploy with `azd up` or `azd deploy`.

**Policy Best Practices:**
- Always test policy changes in a development environment first
- Monitor Application Insights after policy changes for unexpected behavior
- Use policy fragments for reusable policy components
- Document custom policy logic with XML comments
- Keep rate limits aligned with Azure OpenAI quota allocations

See [APIM Policies](./apim-policies.md) for complete policy documentation.

**API version discovery**

Use Azure CLI locally or in Codespaces/Dev Containers to list provider API versions when introducing new resources:

```shell
az provider show --namespace Microsoft.Web --query "resourceTypes[?resourceType=='sites'].apiVersions" -o tsv
```

## Cleaning-up

To remove all resources at once, including the resource groups, and purge any soft-deleted service, just run:

```shell
azd down --purge
```

> [!NOTE]
> Azd will scan and list all the resource(s) to be deleted and their respective groups, within the current environment, asking for a confirmation before proceeding. Keep the terminal open during the process until it's done.