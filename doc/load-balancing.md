# API Management Load Balancing Configuration

This enhanced configuration adds load balancing capabilities to the API Management backend using Azure Bicep templates.

## Overview

The load balancing feature allows you to:
- Distribute traffic across multiple backend instances
- Implement blue-green deployments
- Achieve high availability through redundancy
- Scale horizontally across multiple regions
- Configure weighted or priority-based traffic distribution

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

For examples of how to implement each of these load balancing patterns, please check `doc/load-balancing-examples.md`.

### Backend Pool Management

- Support for up to 30 backends per pool
- Individual circuit breaker configuration for each backend
- Dynamic backend health monitoring
- Automatic failover capabilities

## Configuration Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `enableLoadBalancing` | bool | false | Enable load balancing across multiple backends |
| `additionalBackendUrls` | array | [] | Additional backend URLs for load balancing |
| `additionalBackendResourceIds` | array | [] | Additional backend resource IDs |
| `backendWeights` | array | [] | Weights for weighted load balancing |
| `backendPriorities` | array | [] | Priorities for priority-based load balancing |

## Usage Examples

### Basic Single Backend (No Load Balancing)

```bicep
module webApiBackend '../apim/api/agent-api.bicep' = {
  name: 'agent-backend-api'
  params: {
    apimServiceName: 'my-apim-service'
    backendUrl: 'https://backend1.example.com'
    backendResourceId: 'resourceId1'
    enableLoadBalancing: false
  }
}
```

### Round-Robin Load Balancing

```bicep
module webApiBackend '../apim/api/agent-api.bicep' = {
  name: 'agent-backend-api'
  params: {
    apimServiceName: 'my-apim-service'
    backendUrl: 'https://backend1.example.com'
    backendResourceId: 'resourceId1'
    enableLoadBalancing: true
    additionalBackendUrls: [
      'https://backend2.example.com'
      'https://backend3.example.com'
    ]
    additionalBackendResourceIds: [
      'resourceId2'
      'resourceId3'
    ]
  }
}
```

### Weighted Load Balancing (Blue-Green Deployment)

```bicep
module webApiBackend '../apim/api/agent-api.bicep' = {
  name: 'agent-backend-api'
  params: {
    apimServiceName: 'my-apim-service'
    backendUrl: 'https://blue-backend.example.com'
    backendResourceId: 'blueResourceId'
    enableLoadBalancing: true
    additionalBackendUrls: [
      'https://green-backend.example.com'
    ]
    additionalBackendResourceIds: [
      'greenResourceId'
    ]
    backendWeights: [9, 1]  // 90% blue, 10% green
  }
}
```

### Priority-Based Load Balancing

```bicep
module webApiBackend '../apim/api/agent-api.bicep' = {
  name: 'agent-backend-api'
  params: {
    apimServiceName: 'my-apim-service'
    backendUrl: 'https://primary-backend.example.com'
    backendResourceId: 'primaryResourceId'
    enableLoadBalancing: true
    additionalBackendUrls: [
      'https://secondary-backend.example.com'
      'https://fallback-backend.example.com'
    ]
    additionalBackendResourceIds: [
      'secondaryResourceId'
      'fallbackResourceId'
    ]
    backendPriorities: [1, 2, 3]  // Primary, Secondary, Fallback
    backendWeights: [1, 1, 1]     // Equal weights within priority groups
  }
}
```

## Implementation Details

### Backend Resource Creation

The module creates:
1. Individual backend resources for each URL when load balancing is enabled
2. A single backend resource when load balancing is disabled
3. A backend pool resource that aggregates individual backends

### Policy Configuration

The API policy is dynamically configured to use either:
- The single backend ID when load balancing is disabled
- The backend pool ID when load balancing is enabled

### Resource Dependencies

- Individual backends are created first
- Backend pool depends on all individual backends
- API and policy resources depend on the appropriate backend configuration

## Monitoring and Observability

### Built-in Monitoring

- API Management analytics show request distribution
- Individual backend health status
- Circuit breaker status and trip events
- Request/response metrics per backend

### Recommended Monitoring

1. **Application Insights Integration**
   - Request tracing across backends
   - Performance metrics
   - Error tracking

2. **Azure Monitor Logs**
   - Backend health events
   - Load balancing decisions
   - Circuit breaker activities

3. **Custom Dashboards**
   - Traffic distribution visualization
   - Backend performance comparison
   - Failure rate monitoring

## Best Practices

### Load Balancing Strategy

1. **Development/Testing**
   - Use round-robin for equal load distribution
   - Enable circuit breakers for resilience testing

2. **Production Deployments**
   - Use weighted balancing for blue-green deployments
   - Implement gradual traffic shifting
   - Monitor backend performance metrics

3. **Multi-Region Setup**
   - Use priority-based balancing
   - Configure primary and secondary regions
   - Ensure proper health checks

### Circuit Breaker Configuration

```bicep
// Example: Add circuit breaker to individual backends
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
   - Verify all backends are healthy
   - Review circuit breaker status

2. **Backend Unavailability**
   - Check individual backend health
   - Review circuit breaker rules
   - Verify network connectivity

3. **Configuration Errors**
   - Ensure array lengths match for weights/priorities
   - Verify backend URLs are accessible
   - Check resource ID formatting

### Diagnostic Commands

```bash
# Check backend pool status
az apim backend show --service-name <apim-name> --backend-id <backend-pool-id>

# List all backends
az apim backend list --service-name <apim-name>

# Check API policy
az apim api policy show --service-name <apim-name> --api-id <api-id>
```

## Migration Guide

### From Single Backend

1. Update parameters to enable load balancing
2. Add additional backend URLs and resource IDs
3. Configure weights or priorities as needed
4. Deploy and monitor traffic distribution

### Rolling Update Process

1. Deploy new backend instances
2. Add them to the load balancer pool with low weight
3. Gradually increase weight while monitoring
4. Remove old backends once traffic is fully migrated

## API Reference

### Output Variables

| Output | Type | Description |
|--------|------|-------------|
| `backendId` | string | ID of the active backend (single or pool) |
| `loadBalancingEnabled` | bool | Whether load balancing is active |
| `totalBackendsConfigured` | int | Total number of backends configured |
| `apiPath` | string | API gateway path |

### Dependencies

- API Management service (existing)
- Backend resources (App Services, Function Apps, etc.)
- Optional: Application Insights for monitoring
- Optional: Key Vault for secrets management
