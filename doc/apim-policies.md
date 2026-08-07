# AI Foundry API Policies

The AI Foundry API is secured and optimized through comprehensive APIM policies defined in [`infra/modules/apim/policies/foundry-api-policy.xml`](../infra/modules/apim/policies/foundry-api-policy.xml). These policies implement enterprise-grade security, rate limiting, and monitoring.

Policies apply at two scopes. The **service scope** ("All APIs") runs first and wraps every API; the **API scope** runs where each API policy places its `<base />`. All four imported API policies open every section with `<base />`, so the service-scope policy always executes.

> [!IMPORTANT]
> The service-scope policy must **not** contain `<base />` itself — the element refers to the parent scope's policy and the service scope has no parent. APIM rejects the deployment with `Element <base/> is not allowed in global context`. Conversely it *must* keep `<forward-request />` in its `<backend>` section: that is the scope forwarding actually lives at, and every API policy's `<backend><base /></backend>` chains up to it. Dropping it silently stops the gateway reaching any backend.

## Service-Scope Policy (All APIs)

[`infra/modules/apim/policies/global-policy.xml`](../infra/modules/apim/policies/global-policy.xml), applied by [`infra/modules/apim/resources/global-policy.bicep`](../infra/modules/apim/resources/global-policy.bicep), holds an optional IP allow-list that restricts the gateway to the backend App Service — **without a VNet**:

```xml
<ip-filter action="allow">
    <address>20.x.x.x</address>
    ...
</ip-filter>
```

The address list is not authored by hand. The policy XML declares an `__IP_FILTER__` placeholder (the same substitution idiom `api.bicep` uses for `__BACKEND_ID__`) and the module fills it from the backend App Service's `possibleOutboundIpAddresses`, plus anything in `additionalGatewayAllowedIps`.

| Parameter | Default | Effect |
|---|---|---|
| `restrictGatewayToBackend` | `false` | Master switch. `true` emits the `ip-filter` over the backend's outbound IPs; `false` collapses it to nothing and the gateway stays reachable by any caller holding a valid subscription key |
| `additionalGatewayAllowedIps` | `[]` | Extra IPs or CIDR ranges merged into the allow-list — e.g. a developer workstation. Only meaningful when the switch is `true` |

Both are top-level parameters in [`infra/main.bicep`](../infra/main.bicep); set them in [`infra/main.parameters.json`](../infra/main.parameters.json) and re-run `azd provision`. The policy resource is deployed either way, so flipping the switch back off genuinely removes the restriction — a conditional module would leave the last-applied policy in place.

**What this protects against — and what it does not.** APIM rejects a request whose path matches no imported API with `404`, and a request missing the subscription key with `401`, both *before* inbound policy evaluation. Neither ever reaches this file. Opportunistic internet scanning therefore **cannot** be filtered here; it is already being rejected by the gateway, and the only lever over its cost is log ingestion (see [APIM & Azure Monitor](./apim-azure-monitor.md) › `enableVerboseLogs`). What the allow-list buys is **leaked-key containment**: if the `ai-gateway` subscription key ever escapes, it is only usable from your backend's egress addresses. Treat it as defence in depth layered under the subscription key, not as a replacement for it.

Three consequences before enabling it:

| Consequence | Detail |
| --- | --- |
| Blocks local development | A backend run with `dotnet run` against the deployed APIM gets `403`. Add your workstation IP to `additionalGatewayAllowedIps`. |
| Blocks the APIM test console | The portal's *Test* tab calls through the gateway and is filtered like any other caller. |
| Outbound IPs are not permanent | `possibleOutboundIpAddresses` is a shared per-scale-unit pool. It rotates if the App Service Plan tier changes (`B1`→`B2` will do it) or the app is migrated between platform stamps — re-run `azd provision` after either. |

The allow-list is gateway-scope only; the Developer-SKU developer portal and management endpoints are unaffected by it. If traffic must never reach APIM at all, the only no-VNet option is Azure Front Door + WAF in front of the gateway with APIM restricted to the `X-Azure-FDID` header — disproportionate for a Developer-SKU instance absorbing scanner noise it already rejects.

## Inbound Policies

**1. Managed Identity Authentication**
```xml
<authentication-managed-identity
    resource="https://cognitiveservices.azure.com/"
    output-token-variable-name="managed-id-access-token"
    ignore-error="false"
/>
```
- Authenticates APIM to Azure OpenAI using system-assigned managed identity
- Eliminates the need for API keys stored in APIM
- Token is stored in context variable for header injection

**2. Authorization Header Injection**
```xml
<set-header name="Authorization" exists-action="override">
    <value>@("Bearer " + (string)context.Variables["managed-id-access-token"])</value>
</set-header>
```
- Dynamically injects Bearer token from managed identity authentication
- Ensures secure communication with AI Foundry endpoints

**3. Backend Pool Selection**
```xml
<set-backend-service id="__BACKEND_ID__" backend-id="__BACKEND_ID__" />
```
- Routes requests to the load-balanced backend pool. `__BACKEND_ID__` is a placeholder substituted at
  deploy time by [`infra/modules/apim/resources/api.bicep`](../infra/modules/apim/resources/api.bicep) —
  it resolves to `ai-foundry-backend-pool` with the default `enableLoadBalancing: true`. See
  [`load-balancing.md`](load-balancing.md#policy-configuration)
- The pool holds one backend per `backendUrls` entry — a single Foundry endpoint today, so add entries to
  spread load across deployments or regions
- Priority groups provide failover, weights provide distribution

**4. Request Quotas (Hourly)**
```xml
<quota-by-key
    calls="18000"
    renewal-period="3600"
    counter-key="@(context.Subscription?.Key ?? "anonymous")"
/>
```
- **Limit:** 18,000 requests per hour per subscription key
- **Renewal:** Every 3600 seconds (1 hour)
- **Tracking:** By subscription key or "anonymous" for keyless requests
- **Purpose:** Prevents excessive usage and cost overruns

**5. Rate Limiting (Per Minute)**
```xml
<rate-limit-by-key
    calls="300"
    renewal-period="60"
    counter-key="@(context.Subscription?.Key ?? "anonymous")"
/>
```
- **Limit:** 300 requests per minute per subscription key
- **Renewal:** Every 60 seconds
- **Sizing:** Kept below combined model RPM capacity (chat 6,000 + embedding 900, at Azure's 6 RPM per 1,000 TPM) as a fair-usage guard, while high enough to absorb multi-file embedding bursts
- **Purpose:** Protects backend from traffic spikes and ensures fair usage

**6. Token Metrics Emission**
```xml
<llm-emit-token-metric>
    <dimension name="API ID" />
</llm-emit-token-metric>
```
- Emits token usage metrics to Application Insights
- Tracks usage by API ID for aggregated monitoring
- Enables detailed cost analysis and usage monitoring

**7. Token-Based Rate Limiting**
```xml
<llm-token-limit
    tokens-per-minute="500000"
    tokens-consumed-header-name="x-apim-ratelimit-consumed-tokens"
    remaining-tokens-header-name="x-apim-ratelimit-remaining-tokens"
    token-quota="30000000"
    token-quota-period="Hourly"
    remaining-quota-tokens-header-name="x-apim-ratelimit-remaining-quota-tokens"
    counter-key="@(context.Subscription?.Key ?? "anonymous")"
    estimate-prompt-tokens="true"
/>
```

**Token Limits:**
- **TPM (Tokens Per Minute):** 500,000 tokens/minute (below combined chat 1,000,000 + embedding 150,000 model capacity)
- **Hourly Quota:** 30,000,000 tokens/hour
- **Tracking:** By subscription key (matches the request-based limits above, so all throttles meter the same consumer)
- **Prompt Estimation:** Automatically estimates prompt token count for requests
- **Response Headers:** Includes consumption and remaining token counts

**Custom Headers Injected:**
- `x-apim-ratelimit-consumed-tokens` - Tokens used in current request
- `x-apim-ratelimit-remaining-tokens` - Tokens remaining in current minute
- `x-apim-ratelimit-remaining-quota-tokens` - Tokens remaining in hourly quota

## Policy Benefits

1. **Security**: Passwordless authentication via managed identity
2. **Cost Control**: Multi-layered rate limiting (requests + tokens)
3. **High Availability**: Automatic load balancing across multiple deployments
4. **Observability**: Comprehensive token metrics and diagnostics
5. **Fair Usage**: Per-subscription rate and token limiting prevents any one consumer from monopolizing capacity
6. **Transparency**: Rate limit headers inform clients of their usage status

## Monitored Headers

The APIM diagnostics configuration captures the following headers for analysis:
- `x-ratelimit-limit-requests` - Azure OpenAI model request limit
- `x-ratelimit-remaining-requests` - Azure OpenAI model remaining requests
- `x-ratelimit-limit-tokens` - Azure OpenAI model token limit
- `x-ratelimit-remaining-tokens` - Azure OpenAI remaining tokens
- `x-apim-ratelimit-consumed-tokens` - Azure APIM consumed tokens
- `x-apim-ratelimit-remaining-tokens` - Azure APIM remaining tokens (per minute)
- `x-apim-ratelimit-remaining-quota-tokens` - Azure APIM remaining quota tokens (hourly)
- `x-ms-deployment-name` - Which model deployment handled the request

## Customizing Policy Limits

To adjust rate limits or quotas, modify [`infra/modules/apim/policies/foundry-api-policy.xml`](../infra/modules/apim/policies/foundry-api-policy.xml):

After modifying the policy, redeploy with `azd up` or `azd deploy` to apply changes.
