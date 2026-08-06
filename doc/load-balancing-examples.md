# API Management Load Balancing Examples

This document provides examples of how to configure load balancing for an APIM-fronted backend using
the shared [`infra/modules/apim/resources/api.bicep`](../infra/modules/apim/resources/api.bicep) module.
Every API imported into the gateway — AI Foundry, Document Intelligence, Content Safety, AI Search — is
deployed from this module, so the same `backendUrls` / `backendWeights` / `backendPriorities` parameters
apply to each of them. Paths below are relative to
[`infra/modules/apim/apim.bicep`](../infra/modules/apim/apim.bicep), which is where the module is invoked.

All four APIs ship with `enableLoadBalancing: true` and a single `backendUrls` entry — a pool of one — so
these examples are what adding capacity looks like, not a migration. See
[`load-balancing.md`](load-balancing.md) for the module's behaviour and constraints.

The non-load-balancing parameters (`apiName`, `apiDisplayName`, `apiDescription`, `apiPath`, `apiDefinition`,
`apiPolicy`) are elided as `// ... API definition parameters` for brevity.

> [!IMPORTANT]
> The module names its pool `{apiName minus "-api"}-backend-pool` — `example-api` below produces
> `example-backend-pool`. The API's policy XML must select that id explicitly with
> `<set-backend-service backend-id="example-backend-pool" />`; nothing wires it up automatically.

## Basic Configuration (Single Backend)

```bicep
module apiBackend './resources/api.bicep' = {
  name: 'example-api'
  params: {
    apimServiceName: 'my-apim-service'
    // ... API definition parameters
    backendUrls: ['https://backend1.example.com']
    backendResourceIds: ['subscriptions/sub-id/resourceGroups/rg/providers/Microsoft.Web/sites/backend1']
    enableLoadBalancing: false
  }
}
```

## Round-Robin Load Balancing

This configuration distributes requests evenly across multiple backends:

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
      'subscriptions/sub-id/resourceGroups/rg/providers/Microsoft.Web/sites/backend1'
      'subscriptions/sub-id/resourceGroups/rg/providers/Microsoft.Web/sites/backend2'
      'subscriptions/sub-id/resourceGroups/rg/providers/Microsoft.Web/sites/backend3'
    ]
    enableLoadBalancing: true
    // Equal weights (default) = round-robin distribution
  }
}
```

## Weighted Load Balancing

This configuration sends different amounts of traffic to each backend based on weights:

```bicep
module apiBackend './resources/api.bicep' = {
  name: 'example-api'
  params: {
    apimServiceName: 'my-apim-service'
    // ... API definition parameters
    backendUrls: [
      'https://backend1.example.com'
      'https://backend2.example.com'
    ]
    backendResourceIds: [
      'subscriptions/sub-id/resourceGroups/rg/providers/Microsoft.Web/sites/backend1'
      'subscriptions/sub-id/resourceGroups/rg/providers/Microsoft.Web/sites/backend2'
    ]
    enableLoadBalancing: true
    // Backend1 gets 75% of traffic, Backend2 gets 25%
    backendWeights: [3, 1]
  }
}
```

## Priority-Based Load Balancing

This configuration uses priority groups where higher priority backends are preferred:

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
      'subscriptions/sub-id/resourceGroups/rg/providers/Microsoft.Web/sites/primary'
      'subscriptions/sub-id/resourceGroups/rg/providers/Microsoft.Web/sites/secondary'
      'subscriptions/sub-id/resourceGroups/rg/providers/Microsoft.Web/sites/fallback'
    ]
    enableLoadBalancing: true
    // Priority 1 (highest), Priority 2, Priority 3 (lowest)
    backendPriorities: [1, 2, 3]
    // Equal weights within each priority group
    backendWeights: [1, 1, 1]
  }
}
```

## Blue-Green Deployment Example

This configuration allows you to gradually shift traffic from old to new deployment:

```bicep
module apiBackend './resources/api.bicep' = {
  name: 'example-api'
  params: {
    apimServiceName: 'my-apim-service'
    // ... API definition parameters
    backendUrls: [
      'https://blue-backend.example.com'   // Current production
      'https://green-backend.example.com'  // New deployment
    ]
    backendResourceIds: [
      'subscriptions/sub-id/resourceGroups/rg/providers/Microsoft.Web/sites/blue'
      'subscriptions/sub-id/resourceGroups/rg/providers/Microsoft.Web/sites/green'
    ]
    enableLoadBalancing: true
    // Start with 90% blue, 10% green traffic
    backendWeights: [9, 1]
    // Gradually adjust weights: [7, 3], [5, 5], [3, 7], [1, 9], then switch to green only
  }
}
```

## Multi-Region Load Balancing

This configuration distributes load across multiple regions:

```bicep
module apiBackend './resources/api.bicep' = {
  name: 'example-api'
  params: {
    apimServiceName: 'my-apim-service'
    // ... API definition parameters
    backendUrls: [
      'https://eastus-backend.example.com'
      'https://westus-backend.example.com'
      'https://northeurope-backend.example.com'
    ]
    backendResourceIds: [
      'subscriptions/sub-id/resourceGroups/rg-eastus/providers/Microsoft.Web/sites/backend-eastus'
      'subscriptions/sub-id/resourceGroups/rg-westus/providers/Microsoft.Web/sites/backend-westus'
      'subscriptions/sub-id/resourceGroups/rg-northeurope/providers/Microsoft.Web/sites/backend-northeurope'
    ]
    enableLoadBalancing: true
    // Primary region gets more traffic
    backendPriorities: [1, 1, 2]  // EastUS and WestUS primary, NorthEurope secondary
    backendWeights: [3, 2, 1]     // EastUS 50%, WestUS 33%, NorthEurope 17% within priority groups
  }
}
```

## Key Features Supported

1. **Load Balancing Methods**:
   - Round-robin (equal weights)
   - Weighted (custom weights)
   - Priority-based (priority groups)

2. **Backend Management**:
   - Up to 30 backends per pool
   - One APIM backend resource created per `backendUrls` entry
   - Priority groups for failover, weights for distribution within a group

3. **Use Cases**:
   - High availability
   - Performance optimization
   - Blue-green deployments
   - Multi-region deployments
   - Capacity scaling

## Monitoring and Troubleshooting

- Monitor backend health through the Azure Portal
- Use Application Insights for request tracing — see [`apim-app-insights.md`](apim-app-insights.md)
- Check API Management analytics for load distribution
- Review `ApiManagementGatewayLogs` for backend failures, once `enableVerboseLogs` is on — see
  [`apim-azure-monitor.md`](apim-azure-monitor.md)

## Important Notes

1. Load balancing is approximate due to the distributed nature of API Management
2. Different gateway instances don't synchronize load balancing decisions
3. Session affinity is not available in the current API version but can be implemented via policies
4. Every backend in these examples needs APIM's managed identity granted the matching data-plane role,
   the same way [`infra/modules/security/`](../infra/modules/security) grants it on the Foundry account
   and the Search service
5. Circuit breakers are not configured by the module — see
   [`load-balancing.md`](load-balancing.md#circuit-breakers)
