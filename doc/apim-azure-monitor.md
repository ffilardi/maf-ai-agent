# Azure Monitor Diagnostics Configuration for AI Foundry API

## Overview

This document describes the Azure Monitor diagnostics configuration implemented for the AI Foundry API in Azure API Management (APIM). The configuration enables comprehensive logging and monitoring capabilities with settings that override global APIM diagnostics settings.

**Key Features:**
- **Built-in Integration**: Uses Azure's native `/loggers/azuremonitor` logger (no custom logger resources required)
- **LLM Message Logging**: Enhanced support for Large Language Model request/response logging
- **API-level Override**: Diagnostics settings that override global APIM configurations
- **Comprehensive Telemetry**: Request/response logging, client IP tracking, and error handling

## Implementation Details

### Configuration Parameters

The Azure Monitor diagnostics configuration leverages existing shared parameters in the AI Foundry API Bicep template (`infra/modules/apim/api/aifoundry-api.bicep`):

```bicep
// Shared diagnostics parameters (used by both Application Insights and Azure Monitor)
param enableAzureMonitorDiagnostics bool = false
param samplingPercentage int = 100
param logClientIpAddress bool = true
param alwaysLogErrors bool = true
param verbosity string = 'information'
param headersToLog string[] = []
param payloadBytesToLog int = 8192

// LLM logging parameters for Azure Monitor
param enableLLMMessages bool = false
param logPrompts bool = true
param maxPromptSizeBytes int = 32768
param logCompletions bool = true
param maxCompletionSizeBytes int = 32768
```

### Settings Configuration

The Azure Monitor diagnostics configuration uses shared parameters that can be customized as needed:

| Setting | Default Value | Description |
|---------|---------------|-------------|
| **Override global** | `true` | API-level diagnostics override global APIM settings |
| **Sampling (%)** | `100` | Configurable sampling rate for request capture |
| **Always log errors** | `true` | All errors are logged regardless of sampling |
| **Log client IP address** | `true` | Client IP addresses are included in logs |
| **Verbosity** | `information` | Configurable logging verbosity level |
| **Headers to log** | `[]` (customizable) | Array of specific headers to include in logs |
| **Number of payload bytes to log** | `8192` | Configurable request/response body logging size |
| **Log LLM messages** | `true` | Enable Large Language Model message logging |
| **Log prompts** | `true` | Enable logging of LLM request prompts |
| **Maximum prompt size** | `32768` bytes | Maximum size for prompt logging (up to 262144) |
| **Log completions** | `true` | Enable logging of LLM response completions |
| **Maximum completion size** | `32768` bytes | Maximum size for completion logging (up to 262144) |

### Resources Created

#### Azure Monitor Diagnostics Configuration

Azure Monitor diagnostics for API Management use a built-in logger integration that doesn't require creating custom logger resources. The configuration leverages the built-in `/loggers/azuremonitor` logger path.

```bicep
resource apiAzureMonitorDiagnostics 'Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview' = {
  name: 'azuremonitor'
  parent: api
  properties: {
    loggerId: '/loggers/azuremonitor'
    sampling: {
      samplingType: 'fixed'
      percentage: samplingPercentage
    }
    frontend: {
      request: {
        headers: customHeadersToLog
        body: {
          bytes: payloadBytesToLog
        }
      }
      response: {
        headers: customHeadersToLog
        body: {
          bytes: payloadBytesToLog
        }
      }
    }
    backend: {
      request: {
        headers: customHeadersToLog
        body: {
          bytes: payloadBytesToLog
        }
      }
      response: {
        headers: customHeadersToLog
        body: {
          bytes: payloadBytesToLog
        }
      }
    }
    logClientIp: logClientIpAddress
    verbosity: verbosity
    alwaysLog: alwaysLogErrors ? 'allErrors' : 'none'
    metrics: true
    largeLanguageModel: enableLLMMessages ? {
      logs: 'enabled'
      requests: logPrompts ? {
        messages: 'all'
        maxSizeInBytes: maxPromptSizeBytes
      } : null
      responses: logCompletions ? {
        messages: 'all'
        maxSizeInBytes: maxCompletionSizeBytes
      } : null
    } : null
  }
}
```

## Module Integration

The Azure Monitor diagnostics configuration is enabled through the AI module (`infra/modules/ai/ai.bicep`):

```bicep
module aiFoundryApi '../apim/api/aifoundry-api.bicep' = {
  params: {
    // ... existing parameters
    applicationInsightsLoggerName: applicationInsightsLoggerName
    enableApplicationInsightsDiagnostics: !empty(applicationInsightsLoggerName)
    enableAzureMonitorDiagnostics: true
    enableLLMMessages: true
  }
}
```

To customize the Azure Monitor diagnostics settings, you can override the shared parameters when calling the module.

## Benefits

1. **Unified Configuration**: Shared parameters ensure consistent diagnostics configuration across Application Insights and Azure Monitor
2. **Flexible Sampling**: Configurable sampling rate allows balance between monitoring completeness and cost
3. **Error Visibility**: All errors are logged regardless of sampling rate
4. **Security Compliance**: Client IP addresses are logged for audit purposes
5. **Performance Monitoring**: Information-level verbosity provides detailed performance metrics
6. **Configurable Payload Logging**: Adjustable payload size (default 8192 bytes) for debugging vs. privacy balance
7. **Custom Headers**: Configurable headers array allows specific header tracking based on needs

## Monitoring and Analysis

With these settings enabled, you can:

- Monitor all AI Foundry API requests in Azure Monitor
- Analyze error patterns and response times
- Track usage by client IP addresses
- Correlate requests using custom headers
- Generate compliance reports with complete audit trails
- **Log LLM prompts and completions** for model evaluation and auditing
- **Track token usage** for billing and optimization purposes
- **Analyze model performance** with detailed request/response data
- **Export data to Azure AI Foundry** for model evaluation workflows

## Important Notes

- **32 KB Limit**: Azure Monitor enforces a 32 KB limit per log entry
- **Cost Considerations**: High sampling rates and payload logging may increase monitoring costs
- **Privacy**: Default payload logging (8192 bytes) can be adjusted based on sensitivity requirements
- **Override Behavior**: API-level diagnostics settings override any global APIM diagnostics configuration
- **Shared Parameters**: Both Application Insights and Azure Monitor diagnostics use the same parameter set for consistency
- **Preview API**: Uses 2024-06-01-preview API version for LLM logging capabilities
- **Message Size Limits**: LLM messages up to 32KB are sent in single entries; larger messages are chunked
- **Maximum Message Size**: LLM prompts and completions can be up to 2MB each

## Customization Examples

### Reduce Payload Logging for Privacy
```bicep
module aiFoundryApi '../apim/api/aifoundry-api.bicep' = {
  params: {
    // ... other parameters
    payloadBytesToLog: 0  // Disable payload logging for sensitive data
  }
}
```

### Add Custom Headers for Tracking
```bicep
module aiFoundryApi '../apim/api/aifoundry-api.bicep' = {
  params: {
    // ... other parameters
    headersToLog: ['Accept-Language', 'User-Agent', 'X-Custom-Tracking-Id']
  }
}
```

### Reduce Sampling for High-Volume APIs
```bicep
module aiFoundryApi '../apim/api/aifoundry-api.bicep' = {
  params: {
    // ... other parameters
    samplingPercentage: 10  // Sample only 10% of requests
  }
}
```

### Disable LLM Logging for Privacy
```bicep
module aiFoundryApi '../apim/api/aifoundry-api.bicep' = {
  params: {
    // ... other parameters
    enableLLMMessages: false  // Disable all LLM message logging
  }
}
```

### Customize LLM Message Sizes
```bicep
module aiFoundryApi '../apim/api/aifoundry-api.bicep' = {
  params: {
    // ... other parameters
    maxPromptSizeBytes: 16384      // 16KB for prompts
    maxCompletionSizeBytes: 65536  // 64KB for completions
  }
}
```

## LLM Logging Capabilities

The Azure Monitor diagnostics configuration now includes comprehensive LLM (Large Language Model) logging capabilities using the 2024-06-01-preview API version.

### Key Features
- **Prompt Logging**: Capture AI model input prompts up to 32KB by default (configurable up to 262144 bytes)
- **Completion Logging**: Capture AI model responses up to 32KB by default (configurable up to 262144 bytes)
- **Token Metrics**: Track prompt tokens, completion tokens, and total token usage for billing optimization
- **Message Chunking**: Large messages (>32KB) are automatically split and logged with sequence numbers for reconstruction
- **Model Tracking**: Log the specific AI model deployment used for each request

### Use Cases
- **Billing and Cost Management**: Accurate token consumption tracking for cost allocation and optimization
- **Model Evaluation**: Export logged data to Azure AI Foundry for model performance assessment
- **Compliance and Auditing**: Complete audit trail of AI interactions for regulatory requirements
- **Debugging and Optimization**: Analyze prompt effectiveness and model response quality
- **Usage Analytics**: Understand AI model utilization patterns across applications and users

### Data Export and Analysis
Logged LLM data can be queried from Azure Monitor logs and exported for:
- **Azure AI Foundry Integration**: Import data for model evaluation workflows
- **Custom Analytics**: Build dashboards and reports using Log Analytics
- **Cost Optimization**: Analyze token usage patterns to optimize costs
- **Quality Assessment**: Evaluate model performance using built-in or custom metrics

### Log Structure
LLM logs are stored in the `ApiManagementGatewayLlmLog` table with the following key fields:
- `CorrelationId`: Links request and response entries
- `TokenUsage`: Prompt, completion, and total token counts
- `ModelDeployment`: The AI model deployment used
- `RequestMessage`/`ResponseMessage`: Actual prompt and completion content
- `SequenceNumber`: For chunked messages larger than 32KB
