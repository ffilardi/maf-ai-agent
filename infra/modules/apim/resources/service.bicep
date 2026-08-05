@description('Azure region for the API Management service.')
param location string = resourceGroup().location

@description('Resource tags applied to the API Management service.')
param tags object = {}

@description('Name of the API Management service.')
param name string

@description('API Management SKU tier.')
param sku string

@description('Number of scale units for the SKU.')
param skuCount int

@description('Availability zones the service is spread across.')
param availabilityZones array = []

@description('Managed identity type for the service.')
param identityType string = 'SystemAssigned'

@description('Publisher email shown in the developer portal.')
param publisherEmail string = 'noreply@email.com'

@description('Publisher name shown in the developer portal.')
param publisherName string = 'n/a'

@description('Resource id of the Application Insights component for diagnostics.')
param applicationInsightsId string = ''

@description('Instrumentation key of the Application Insights component.')
param applicationInsightsInstrumentationKey string = ''

@description('Resource id of the Log Analytics workspace for diagnostic logs.')
param logAnalyticsWorkspaceId string = ''

@description('Emit resource logs to Log Analytics.')
param enableLogs bool = true

@description('Emit audit-category logs to Log Analytics.')
param enableAuditLogs bool = false

@description('Emit platform metrics to Log Analytics.')
param enableMetrics bool = true

@description('Ship verbose platform logs to Log Analytics.')
param enableVerboseLogs bool = false

resource apimService 'Microsoft.ApiManagement/service@2024-05-01' = {
  location: location
  tags: union(tags, { 'azd-service-name': name })
  name: name
  sku: {
    name: sku
    capacity: (sku == 'Consumption') ? 0 : ((sku == 'Developer') ? 1 : skuCount)
  }
  zones: ((length(availabilityZones) == 0) ? null : availabilityZones)
  identity: {
    type: identityType
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    customProperties: sku == 'Consumption'
      ? {} // Custom properties are not supported for Consumption SKU
      : {
          'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA': 'false'
          'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA': 'false'
          'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TLS_RSA_WITH_AES_128_GCM_SHA256': 'false'
          'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TLS_RSA_WITH_AES_256_CBC_SHA256': 'false'
          'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TLS_RSA_WITH_AES_128_CBC_SHA256': 'false'
          'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TLS_RSA_WITH_AES_256_CBC_SHA': 'false'
          'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TLS_RSA_WITH_AES_128_CBC_SHA': 'false'
          'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TripleDes168': 'false'
          'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls10': 'false'
          'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls11': 'false'
          'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Ssl30': 'false'
          'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Tls10': 'false'
          'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Tls11': 'false'
          'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Ssl30': 'false'
        }
  }
}

resource apimGatewaySubscription 'Microsoft.ApiManagement/service/subscriptions@2024-05-01' = {
  parent: apimService
  name: 'ai-gateway'
  properties: {
    displayName: 'AI Gateway (all APIs)'
    scope: '/apis'
    state: 'active'
    allowTracing: false
  }
}

resource apimLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = if (!empty(applicationInsightsId) && !empty(applicationInsightsInstrumentationKey)) {
  parent: apimService
  name: '${name}-logger'
  properties: {
    credentials: {
      instrumentationKey: applicationInsightsInstrumentationKey
    }
    description: 'API Management Logger to Application Insights'
    loggerType: 'applicationInsights'
    resourceId: applicationInsightsId
    isBuffered: false
  }
}

resource diagnosticSettings 'Microsoft.Insights/diagnosticsettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
  name: 'Logging'
  scope: apimService
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: enableVerboseLogs
      ? [
          {
            category: null
            categoryGroup: 'allLogs'
            enabled: enableLogs
          }
          {
            category: null
            categoryGroup: 'audit'
            enabled: enableAuditLogs
          }
        ]
      : []
    metrics: [
      {
        category: 'AllMetrics'
        enabled: enableMetrics
      }
    ]
  }
}

output id string = apimService.id
output name string = apimService.name
output publicIPAddresses string = apimService.properties.publicIPAddresses[0]
output hostName string = apimService.properties.hostnameConfigurations[0].hostName
output developerPortalUrl string = replace(apimService.properties.developerPortalUrl, 'https://', '')
output principalId string = apimService.identity.principalId
output applicationInsightsLoggerName string = (!empty(applicationInsightsId) && !empty(applicationInsightsInstrumentationKey))
  ? apimLogger.name
  : ''
