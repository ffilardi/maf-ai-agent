# API Management Load Balancing Examples

This document provides examples of how to configure load balancing for the Agent API backend using the enhanced `agent-api.bicep` module.

## Basic Configuration (Single Backend)

```bicep
module webApiBackend '../apim/api/agent-api.bicep' = {
  name: 'agent-backend-api'
  params: {
    apimServiceName: 'my-apim-service'
    backendUrl: 'https://backend1.example.com'
    backendResourceId: 'subscriptions/sub-id/resourceGroups/rg/providers/Microsoft.Web/sites/backend1'
    enableLoadBalancing: false
  }
}
```

## Round-Robin Load Balancing

This configuration distributes requests evenly across multiple backends:

```bicep
module webApiBackend '../apim/api/agent-api.bicep' = {
  name: 'agent-backend-api'
  params: {
    apimServiceName: 'my-apim-service'
    backendUrl: 'https://backend1.example.com'
    backendResourceId: 'subscriptions/sub-id/resourceGroups/rg/providers/Microsoft.Web/sites/backend1'
    enableLoadBalancing: true
    additionalBackendUrls: [
      'https://backend2.example.com'
      'https://backend3.example.com'
    ]
    additionalBackendResourceIds: [
      'subscriptions/sub-id/resourceGroups/rg/providers/Microsoft.Web/sites/backend2'
      'subscriptions/sub-id/resourceGroups/rg/providers/Microsoft.Web/sites/backend3'
    ]
    // Equal weights (default) = round-robin distribution
  }
}
```

## Weighted Load Balancing

This configuration sends different amounts of traffic to each backend based on weights:

```bicep
module webApiBackend '../apim/api/agent-api.bicep' = {
  name: 'agent-backend-api'
  params: {
    apimServiceName: 'my-apim-service'
    backendUrl: 'https://backend1.example.com'
    backendResourceId: 'subscriptions/sub-id/resourceGroups/rg/providers/Microsoft.Web/sites/backend1'
    enableLoadBalancing: true
    additionalBackendUrls: [
      'https://backend2.example.com'
    ]
    additionalBackendResourceIds: [
      'subscriptions/sub-id/resourceGroups/rg/providers/Microsoft.Web/sites/backend2'
    ]
    // Backend1 gets 75% of traffic, Backend2 gets 25%
    backendWeights: [3, 1]
  }
}
```

## Priority-Based Load Balancing

This configuration uses priority groups where higher priority backends are preferred:

```bicep
module webApiBackend '../apim/api/agent-api.bicep' = {
  name: 'agent-backend-api'
  params: {
    apimServiceName: 'my-apim-service'
    backendUrl: 'https://primary-backend.example.com'
    backendResourceId: 'subscriptions/sub-id/resourceGroups/rg/providers/Microsoft.Web/sites/primary'
    enableLoadBalancing: true
    additionalBackendUrls: [
      'https://secondary-backend.example.com'
      'https://fallback-backend.example.com'
    ]
    additionalBackendResourceIds: [
      'subscriptions/sub-id/resourceGroups/rg/providers/Microsoft.Web/sites/secondary'
      'subscriptions/sub-id/resourceGroups/rg/providers/Microsoft.Web/sites/fallback'
    ]
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
module webApiBackend '../apim/api/agent-api.bicep' = {
  name: 'agent-backend-api'
  params: {
    apimServiceName: 'my-apim-service'
    backendUrl: 'https://blue-backend.example.com'   // Current production
    backendResourceId: 'subscriptions/sub-id/resourceGroups/rg/providers/Microsoft.Web/sites/blue'
    enableLoadBalancing: true
    additionalBackendUrls: [
      'https://green-backend.example.com'  // New deployment
    ]
    additionalBackendResourceIds: [
      'subscriptions/sub-id/resourceGroups/rg/providers/Microsoft.Web/sites/green'
    ]
    // Start with 90% blue, 10% green traffic
    backendWeights: [9, 1]
    // Gradually adjust weights: [7, 3], [5, 5], [3, 7], [1, 9], then switch to green only
  }
}
```

## Multi-Region Load Balancing

This configuration distributes load across multiple regions:

```bicep
module webApiBackend '../apim/api/agent-api.bicep' = {
  name: 'agent-backend-api'
  params: {
    apimServiceName: 'my-apim-service'
    backendUrl: 'https://eastus-backend.example.com'
    backendResourceId: 'subscriptions/sub-id/resourceGroups/rg-eastus/providers/Microsoft.Web/sites/backend-eastus'
    enableLoadBalancing: true
    additionalBackendUrls: [
      'https://westus-backend.example.com'
      'https://northeurope-backend.example.com'
    ]
    additionalBackendResourceIds: [
      'subscriptions/sub-id/resourceGroups/rg-westus/providers/Microsoft.Web/sites/backend-westus'
      'subscriptions/sub-id/resourceGroups/rg-northeurope/providers/Microsoft.Web/sites/backend-northeurope'
    ]
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
   - Individual backend circuit breakers
   - Dynamic backend configuration

3. **Use Cases**:
   - High availability
   - Performance optimization
   - Blue-green deployments
   - Multi-region deployments
   - Capacity scaling

## Monitoring and Troubleshooting

- Monitor backend health through Azure Portal
- Use Application Insights for request tracing
- Check API Management analytics for load distribution
- Review logs for backend failures and circuit breaker trips

## Important Notes

1. Load balancing is approximate due to the distributed nature of API Management
2. Different gateway instances don't synchronize load balancing decisions
3. Session affinity is not available in the current API version but can be implemented via policies
4. Circuit breakers work independently on each backend in the pool
