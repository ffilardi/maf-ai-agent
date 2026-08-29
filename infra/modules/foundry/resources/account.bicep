@description('Azure region for the Cognitive Services / Foundry account.')
param location string = resourceGroup().location

@description('Resource tags applied to the account.')
param tags object = {}

@description('Name of the Cognitive Services / Foundry account.')
param name string

@description('Account SKU (e.g. S0).')
param sku string

@description('Account kind (e.g. AIServices).')
param kind string

@description('Managed identity type for the account.')
param identityType string = 'SystemAssigned'

@description('Model deployments to create on the account.')
param modelDeployments array = []

@description('Public network access setting for the account.')
param publicNetworkAccess string = 'Enabled'

@description('Allow AI Foundry project management on the account.')
param allowProjectManagement bool = true

@description('Disable local (key-based) authentication. On by default: all traffic reaches the account through APIM, which injects its managed identity, so an account key is only a way around the gateway.')
param disableLocalAuth bool = true

@description('Restrict outbound network access from the account.')
param restrictOutboundNetworkAccess bool = false

@description('Responsible AI content-filter policy name.')
param raiPolicyName string = 'Microsoft.DefaultV2'

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

// AI Foundry Account
resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' = {
  location: location
  tags: union(tags, { 'azd-service-name': name })
  name: name
  sku: {
    name: sku
  }
  kind: kind
  identity: {
    type: identityType
  }
  properties: {
    publicNetworkAccess: publicNetworkAccess
    allowProjectManagement: allowProjectManagement
    customSubDomainName: name
    disableLocalAuth: disableLocalAuth
    restrictOutboundNetworkAccess: restrictOutboundNetworkAccess
    allowedFqdnList: [
      'ai.azure.com'
      'search.windows.net'
      'cognitiveservices.azure.com'
      'azure-api.net'
    ]
  }
}

// AI Foundry Models Deployment
@batchSize(1)
resource modelDeploymentResources 'Microsoft.CognitiveServices/accounts/deployments@2024-04-01-preview' = [
  for deployment in modelDeployments: {
    parent: account
    name: deployment.name
    sku: deployment.sku
    properties: {
      model: {
        format: deployment.format
        name: deployment.name
        version: deployment.version
      }
      raiPolicyName: raiPolicyName
    }
  }
]

resource diagnosticSettings 'Microsoft.Insights/diagnosticsettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
  name: 'Logging'
  scope: account
  properties: {
    workspaceId: logAnalyticsWorkspaceId
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

output id string = account.id
output name string = account.name
output endpoint string = account.properties.endpoint
output principalId string = account.identity.principalId
