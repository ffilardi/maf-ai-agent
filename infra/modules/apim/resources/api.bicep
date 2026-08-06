@description('Name of the API Management service that hosts this API.')
param apimServiceName string

@description('Logical name of the API resource in APIM.')
param apiName string

@description('Display name shown for the API in the portal.')
param apiDisplayName string

@description('Human-readable description of the API.')
param apiDescription string

@description('Public URL path segment the API is exposed under.')
param apiPath string

@description('OpenAPI definition document (loaded by the caller via loadTextContent).')
param apiDefinition string

@description('Inbound/outbound policy XML for the API (loaded by the caller via loadTextContent).')
param apiPolicy string

@description('Header name callers send the subscription key in.')
param subscriptionKeyHeaderName string = 'api-key'

@description('Query parameter name callers may send the subscription key in.')
param subscriptionKeyQueryName string = 'api-key'

@description('Backend service URLs load-balanced behind this API.')
param backendUrls array = []

@description('Azure resource ids of the backends, used for managed-identity auth.')
param backendResourceIds array = []

@description('Require a subscription key to call this API.')
param subscriptionRequired bool = true

@description('Distribute requests across multiple backends.')
param enableLoadBalancing bool = true

@description('Relative traffic weights per backend for load balancing.')
param backendWeights array = []

@description('Priority order per backend for failover.')
param backendPriorities array = []

@description('Backend the API policy routes to, substituted into the policy\'s __BACKEND_ID__ placeholder. Defaults to the load-balanced pool, or the first individual backend when load balancing is off.')
param policyBackendId string = ''

@description('Name of the Application Insights logger used for diagnostics.')
param applicationInsightsLoggerName string = ''

@description('Emit request/response diagnostics to Application Insights.')
param enableApplicationInsightsDiagnostics bool = false

@description('Diagnostics sampling percentage (0-100).')
param samplingPercentage int = 100

@description('Log the caller client IP address in diagnostics.')
param logClientIpAddress bool = true

@description('Always log failed requests regardless of sampling.')
param alwaysLogErrors bool = true

@allowed(['verbose', 'information', 'error'])
@description('Diagnostics logging verbosity level.')
param verbosity string = 'information'

@description('Maximum request/response payload bytes to log.')
param payloadBytesToLog int = 8192

@description('Request/response header names to include in diagnostics.')
param headersToLog string[] = []

@description('Extra header names to include in diagnostics, merged with headersToLog.')
param additionalHeadersToLog string[] = []

var apiDefinitionFormat = 'openapi+json'
var apiRevision = '1'
var apiBackendId = replace(apiName, '-api', '-backend')
var apiBackendPoolId = '${apiBackendId}-pool'
var apiPolicyFormat = 'rawxml'
var customHeadersToLog = union(headersToLog, additionalHeadersToLog)

// The policy XML declares its backend as __BACKEND_ID__ so routing follows the backends this module
// actually creates: the pool when load balancing is on, the first individual backend when it is off.
var defaultPolicyBackendId = enableLoadBalancing ? apiBackendPoolId : '${apiBackendId}-1'
var effectivePolicyBackendId = empty(policyBackendId) ? defaultPolicyBackendId : policyBackendId
var resolvedApiPolicy = replace(apiPolicy, '__BACKEND_ID__', effectivePolicyBackendId)

resource apimService 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimServiceName
}

// Create individual backends for each URL
resource backends 'Microsoft.ApiManagement/service/backends@2024-05-01' = [
  for (url, i) in backendUrls: {
    name: '${apiBackendId}-${i+1}'
    parent: apimService
    properties: {
      description: '${apiDescription} - Backend ${i+1}'
      url: url
      resourceId: replace('${az.environment().resourceManager}/${backendResourceIds[i]}', '///', '/')
      protocol: 'http'
      tls: {
        validateCertificateChain: true
        validateCertificateName: true
      }
    }
  }
]

// Create backend pool for load balancing
resource backendPool 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = if (enableLoadBalancing) {
  name: apiBackendPoolId
  parent: apimService
  properties: {
    description: '${apiDescription} - Load Balanced Pool'
    type: 'Pool'
    pool: {
      services: [
        for (url, i) in backendUrls: {
          id: backends[i].id
          priority: empty(backendPriorities) ? 1 : backendPriorities[i]
          weight: empty(backendWeights) ? 100 : backendWeights[i]
        }
      ]
    }
  }
  dependsOn: backends
}

resource api 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  name: apiName
  parent: apimService
  properties: {
    path: apiPath
    displayName: apiDisplayName
    apiRevision: apiRevision
    isCurrent: true
    subscriptionRequired: subscriptionRequired
    subscriptionKeyParameterNames: {
      header: subscriptionKeyHeaderName
      query: subscriptionKeyQueryName
    }
    format: apiDefinitionFormat
    value: apiDefinition
    protocols: [
      'https'
    ]
  }
  dependsOn: enableLoadBalancing ? [backendPool] : [backends]
}

resource apiPolicyResource 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  name: 'policy'
  parent: api
  properties: {
    value: resolvedApiPolicy
    format: apiPolicyFormat
  }
  dependsOn: enableLoadBalancing ? [backendPool] : [backends]
}

// Application Insights diagnostics configuration
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
    httpCorrelationProtocol: 'Legacy'
    verbosity: verbosity
    operationNameFormat: 'Name'
    metrics: true
    alwaysLog: alwaysLogErrors ? 'allErrors' : 'none'
  }
}

output apiPath string = '${apimService.properties.gatewayUrl}/${apiPath}'
