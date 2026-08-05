# API Diagnostics Configuration

## Overview

This document explains how Application Insights diagnostics have been configured at the API level in Azure API Management using Bicep Infrastructure as Code.

## Implementation

### Configuration Parameters

The Azure Monitor diagnostics configuration leverages existing shared parameters in the AI Foundry API Bicep template (`infra/modules/apim/api/aifoundry-api.bicep`):

```bicep
// Shared diagnostics parameters (used by both Application Insights and Azure Monitor)
param applicationInsightsLoggerName string = ''
param enableApplicationInsightsDiagnostics bool = false
param samplingPercentage int = 100
param logClientIpAddress bool = true
param alwaysLogErrors bool = true
param verbosity string = 'information'
param headersToLog string[] = []
param payloadBytesToLog int = 8192
```

### API Diagnostics Resource

Added an `apiDiagnostics` resource in `/infra/modules/apim/api/aifoundry-api.bicep` that configures Application Insights logging for the AI Foundry API:

```bicep
resource apiDiagnostics 'Microsoft.ApiManagement/service/apis/diagnostics@2024-05-01' = if (enableApplicationInsightsDiagnostics && !empty(applicationInsightsLoggerName)) {
  name: 'applicationinsights'
  parent: api
  properties: {
    loggerId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.ApiManagement/service/${apimServiceName}/loggers/${applicationInsightsLoggerName}'
    sampling: {
      samplingType: 'fixed'
      percentage: samplingPercentage
    }
    frontend: {
      request: {
        headers: headersToLog
        body: {
          bytes: payloadBytesToLog
        }
      }
      response: {
        headers: headersToLog
        body: {
          bytes: payloadBytesToLog
        }
      }
    }
    backend: {
      request: {
        headers: headersToLog
        body: {
          bytes: payloadBytesToLog
        }
      }
      response: {
        headers: headersToLog
        body: {
          bytes: payloadBytesToLog
        }
      }
    }
    logClientIp: logClientIpAddress
    httpCorrelationProtocol: 'Legacy'
    verbosity: verbosity
    operationNameFormat: 'Name'
    metrics: true
    alwaysLog: alwaysLogErrors ? 'allErrors' : 'none'
  }
}
```

### Configuration Parameters

Added the following configurable parameters to the API module:

- `applicationInsightsLoggerName`: The name of the Application Insights logger
- `enableApplicationInsightsDiagnostics`: Enable/disable diagnostics (default: true)
- `samplingPercentage`: Sampling percentage (1-100, default: 100)
- `logClientIpAddress`: Log client IP addresses (default: true)
- `alwaysLogErrors`: Always log errors (default: true)
- `verbosity`: Logging verbosity level (verbose/information/error, default: information)
- `headersToLog`: Headers to log (default: empty)
- `payloadBytesToLog`: Payload bytes to log (default: 8192, max: 8192)

### Module Integration

The Application Insights diagnostics configuration is enabled through the AI module (`infra/modules/ai/ai.bicep`):

```bicep
module aiFoundryApi '../apim/api/aifoundry-api.bicep' = {
  params: {
    // ... existing parameters
    applicationInsightsLoggerName: applicationInsightsLoggerName
    enableApplicationInsightsDiagnostics: !empty(applicationInsightsLoggerName)
  }
}
```

To customize the Application Insights diagnostics settings, you can override the shared parameters when calling the module.

Updated the module chain to pass the Application Insights logger name:

1. **APIM Service** (`/infra/modules/apim/resources/apim-service.bicep`): Added output for the logger name
2. **APIM Module** (`/infra/modules/apim/apim.bicep`): Pass through the logger name output
3. **Main Template** (`/infra/main.bicep`): Pass the logger name from APIM to AI module
4. **AI Module** (`/infra/modules/ai/ai.bicep`): Pass the logger name to the API module

## Features Enabled

The configuration enables the following Application Insights features as shown in the Azure Portal screenshot:

- ✅ **Enable**: Application Insights logging is enabled
- ✅ **Destination**: Connected to the existing Application Insights instance via logger
- ✅ **Sampling (%)**: Configurable sampling percentage (default: 100%)
- ✅ **Always log errors**: Enabled by default
- ✅ **Log client IP address**: Enabled by default
- ✅ **Support custom metrics**: Enabled by default
- ✅ **Verbosity**: Configurable (Information level by default)
- ✅ **Headers to log**: Configurable (Accept-Language by default)
- ✅ **Number of payload bytes to log**: Configurable (8192 bytes by default)

## Benefits

1. **Comprehensive Monitoring**: Track all API requests and responses
2. **Performance Analytics**: Monitor API performance and identify bottlenecks
3. **Error Tracking**: Automatic error logging and alerting
4. **Custom Metrics**: Support for business-specific metrics
5. **Configurable Sampling**: Control logging volume for high-traffic APIs
6. **Security Compliance**: Option to log client IP addresses for audit trails

## Deployment

The diagnostics will be automatically enabled when you deploy the infrastructure using:

```bash
azd deploy
```

The configuration is conditional - it will only be created if:
- `enableApplicationInsightsDiagnostics` is true (default)
- `applicationInsightsLoggerName` is not empty (automatically populated from APIM service)

## Monitoring

After deployment, you can view the API diagnostics in:
- Azure Portal > API Management > APIs > [Your API] > Settings > Diagnostics logs
- Application Insights > Logs for detailed query and analysis
- Application Insights > Live Metrics for real-time monitoring