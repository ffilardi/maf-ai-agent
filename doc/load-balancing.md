# API Management Load Balancing Configuration

How backend load balancing works in this deployment, and how to add backends to a pool. It is implemented by the shared API module [`infra/modules/apim/resources/api.bicep`](../infra/modules/apim/resources/api.bicep), which every API imported into the gateway (AI Foundry, Document Intelligence, Content Safety, AI Search) is deployed from — see the invocations in [`infra/modules/apim/apim.bicep`](../infra/modules/apim/apim.bicep).

## Overview

Load balancing is **already enabled** on all four imported APIs — each is deployed with
`enableLoadBalancing: true` but a single entry in `backendUrls`, i.e. a backend pool of one. This is
deliberate: the pool exists from day one, so adding capacity is a matter of appending URLs rather than
restructuring the deployment. Each API points at one regional Foundry or Search endpoint today.

Adding entries to `backendUrls` lets you:
- Distribute traffic across multiple backend instances
- Implement blue-green deployments
- Achieve high availability through redundancy
- Scale horizontally across multiple regions
- Configure weighted or priority-based traffic distribution

For Azure OpenAI specifically, this is how you spread load across several Foundry deployments or regions
to raise the effective TPM ceiling above a single deployment's quota.

## Features

### Load Balancing Types

1. **Round-Robin** (Default)
   - Equal distribution across all backends
   - Default when all weights are equal or not specified

2. **Weighted Load Balancing**
   - Custom traffic distribution based on weights
   - Useful for gradually shifting traffic between deployments

3. **Priority-Based Load Balancing**
   - Backends organized into priority groups
   - Higher priority backends are preferred
   - Lower priority backends used only when higher priority ones are unavailable

For examples of how to implement each of these load balancing patterns, see [`load-balancing-examples.md`](load-balancing-examples.md).

### Backend Pool Management

- APIM supports up to 30 backends per pool
- Priority groups give failover: traffic only reaches a lower-priority group when every backend in the
  higher-priority group is unavailable
- Weights distribute traffic within a priority group

> [!NOTE]
> Circuit breakers and active health probes are **not** configured by
> [`infra/modules/apim/resources/api.bicep`](../infra/modules/apim/resources/api.bicep) — the backends it
> creates carry only a URL, a resource id for managed-identity auth, and TLS validation. See
> [Circuit breakers](#circuit-breakers) below for how to add them.

## Configuration Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `enableLoadBalancing` | bool | false | Create the backend pool. Set to `true` for every API in [`apim.bicep`](../infra/modules/apim/apim.bicep) — see the warning under [Policy configuration](#policy-configuration) before turning it off |
| `backendUrls` | array | [] | Backend URLs; one APIM backend resource is created per entry |
| `backendResourceIds` | array | [] | Azure resource ids of the backends, used for managed-identity auth (positionally paired with `backendUrls`) |
| `backendWeights` | array | [] | Weights for weighted load balancing (defaults to 100 each) |
| `backendPriorities` | array | [] | Priorities for priority-based load balancing (defaults to 1 each) |

## Usage Examples

### Basic Single Backend (No Load Balancing)

```bicep
module apiBackend './resources/api.bicep' = {
  name: 'example-api'
  params: {
    apimServiceName: 'my-apim-service'
    // ... API definition parameters
    backendUrls: ['https://backend1.example.com']
    backendResourceIds: ['resourceId1']
    enableLoadBalancing: false
  }
}
```

### Round-Robin Load Balancing

```bicep
module apiBackend './resources/api.bicep' = {
  name: 'example-api'
  params: {
    apimServiceName: 'my-apim-service'
    // ... API definition parameters
    backendUrls: [
      'https://backend1.example.com'
      'https://backend2.example.com'
      'https://backend3.example.com'
    ]
    backendResourceIds: [
      'resourceId1'
      'resourceId2'
      'resourceId3'
    ]
    enableLoadBalancing: true
  }
}
```

### Weighted Load Balancing (Blue-Green Deployment)

```bicep
module apiBackend './resources/api.bicep' = {
  name: 'example-api'
  params: {
    apimServiceName: 'my-apim-service'
    // ... API definition parameters
    backendUrls: [
      'https://blue-backend.example.com'
      'https://green-backend.example.com'
    ]
    backendResourceIds: [
      'blueResourceId'
      'greenResourceId'
    ]
    enableLoadBalancing: true
    backendWeights: [9, 1]  // 90% blue, 10% green
  }
}
```

### Priority-Based Load Balancing

```bicep
module apiBackend './resources/api.bicep' = {
  name: 'example-api'
  params: {
    apimServiceName: 'my-apim-service'
    // ... API definition parameters
    backendUrls: [
      'https://primary-backend.example.com'
      'https://secondary-backend.example.com'
      'https://fallback-backend.example.com'
    ]
    backendResourceIds: [
      'primaryResourceId'
      'secondaryResourceId'
      'fallbackResourceId'
    ]
    enableLoadBalancing: true
    backendPriorities: [1, 2, 3]  // Primary, Secondary, Fallback
    backendWeights: [1, 1, 1]     // Equal weights within priority groups
  }
}
```

## Implementation Details

### Backend Resource Creation

The module creates:
1. One backend resource per entry in `backendUrls`, always — named `{apiName minus "-api"}-backend-{n}`,
   e.g. `ai-foundry-backend-1`
2. A backend pool named `{apiName minus "-api"}-backend-pool`, e.g. `ai-foundry-backend-pool`, but only
   when `enableLoadBalancing` is `true`

Weights and priorities are read positionally from `backendWeights` / `backendPriorities`, defaulting to
weight `100` and priority `1` when those arrays are empty.

### Policy configuration

Each API's policy selects the backend by hard-coded id, not by a Bicep expression:

```xml
<set-backend-service id="ai-foundry-backend-pool" backend-id="ai-foundry-backend-pool" />
```

> [!WARNING]
> Because the pool id is written into the policy XML, `enableLoadBalancing: false` would leave the policy
> pointing at a backend pool that was never created, and requests would fail. To run without a pool you
> must also change the `backend-id` in the corresponding
> [`policies/*.xml`](../infra/modules/apim/policies) file to an individual backend such as
> `ai-foundry-backend-1`.

### Resource Dependencies

- Individual backends are created first
- Backend pool depends on all individual backends
- The API and its policy depend on the pool when load balancing is enabled, on the individual backends otherwise

## Monitoring and Observability

### What this deployment already gives you

- API Management analytics show request distribution across the pool
- Per-API Application Insights request diagnostics, including the backend response code and the gateway's
  rate-limit headers — see [`apim-app-insights.md`](apim-app-insights.md)
- Token metrics per API id from the `llm-emit-token-metric` policy — see [`apim-azure-monitor.md`](apim-azure-monitor.md)

### Worth adding when you run more than one backend

- A Log Analytics query grouping `ApiManagementGatewayLogs` by `BackendUrl` to confirm the split matches
  the configured weights (requires `enableVerboseLogs`, see [`apim-azure-monitor.md`](apim-azure-monitor.md))
- An alert on the failure rate of any single backend, so a degraded region is visible before the pool
  drains capacity into it

## Best Practices

### Load Balancing Strategy

1. **Development/Testing**
   - Use round-robin for equal load distribution

2. **Production Deployments**
   - Use weighted balancing for blue-green deployments
   - Implement gradual traffic shifting
   - Monitor backend performance metrics

3. **Multi-Region Setup**
   - Use priority-based balancing
   - Configure primary and secondary regions

### Circuit breakers

Not configured today. To add one, extend the `backends` resource loop in
[`infra/modules/apim/resources/api.bicep`](../infra/modules/apim/resources/api.bicep) with a
`circuitBreaker` property — APIM trips the backend out of the pool for `tripDuration` once the failure
condition is met:

```bicep
// Add to the properties of each backend in the loop
circuitBreaker: {
  rules: [
    {
      failureCondition: {
        count: 3
        errorReasons: ['Server errors']
        interval: 'PT1H'
        statusCodeRanges: [
          {
            min: 500
            max: 599
          }
        ]
      }
      name: 'ServerErrorBreaker'
      tripDuration: 'PT1H'
      acceptRetryAfter: true
    }
  ]
}
```

### Performance Considerations

- Load balancing is approximate due to distributed architecture
- Gateway instances don't synchronize load balancing decisions
- Consider backend capacity when setting weights
- Monitor for hot spots and adjust weights accordingly

## Troubleshooting

### Common Issues

1. **Uneven Load Distribution**
   - Check backend weights configuration
   - Verify all backends are reachable
   - Remember distribution is approximate across gateway instances

2. **Backend Unavailability**
   - Check the individual backend resources in the portal
   - Verify network connectivity and that the backend URL is correct
   - Confirm APIM's managed identity still holds the data-plane role on the target resource

3. **Configuration Errors**
   - Ensure `backendWeights` / `backendPriorities` are the same length as `backendUrls` — the module
     indexes them positionally and a short array will fail the deployment
   - Verify `backendResourceIds` is positionally aligned with `backendUrls`
   - Check that the `backend-id` in the API policy matches the pool the module created

### Diagnostic Commands

```bash
# Check backend pool status
az apim backend show --service-name <apim-name> --backend-id <backend-pool-id>

# List all backends
az apim backend list --service-name <apim-name>

# Check API policy
az apim api policy show --service-name <apim-name> --api-id <api-id>
```

## Adding a second backend

The pool already exists, so no restructuring is needed:

1. Append the new endpoint to `backendUrls` and its resource id to `backendResourceIds` in the relevant
   module call in [`infra/modules/apim/apim.bicep`](../infra/modules/apim/apim.bicep)
2. Grant APIM's managed identity the same data-plane role on the new resource that
   [`infra/modules/security/`](../infra/modules/security) grants on the existing one — otherwise the
   backend authenticates as nobody and every request through it fails
3. Configure `backendWeights` or `backendPriorities` as needed
4. `azd provision`, then confirm the distribution matches the weights

### Rolling Update Process

1. Deploy new backend instances
2. Add them to the load balancer pool with low weight
3. Gradually increase weight while monitoring
4. Remove old backends once traffic is fully migrated

## API Reference

### Output Variables

| Output | Type | Description |
|--------|------|-------------|
| `apiPath` | string | Fully qualified API gateway URL (`{gatewayUrl}/{apiPath}`) |

### Dependencies

- API Management service (created by [`infra/modules/apim/resources/service.bicep`](../infra/modules/apim/resources/service.bicep))
- Backend resources — in this deployment the Azure AI Foundry account and the Azure AI Search service
- APIM's system-assigned managed identity holding the data-plane role on each backend
  ([`infra/modules/security/`](../infra/modules/security))
- Optional: Application Insights, for the per-API request diagnostics
