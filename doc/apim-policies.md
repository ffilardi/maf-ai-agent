# AI Foundry API Policies

The AI Foundry API is secured and optimized through comprehensive APIM policies defined in [`infra/modules/apim/policies/foundry-api-policy.xml`](../infra/modules/apim/policies/foundry-api-policy.xml). These policies implement enterprise-grade security, rate limiting, and monitoring.

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
<set-backend-service
    id="aifoundry-pool"
    backend-id="ai-foundry-backend-pool"
/>
```
- Routes requests to the load-balanced backend pool
- Pool contains multiple Azure OpenAI model deployment instances
- Provides automatic failover and distribution

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
