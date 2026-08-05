@description('Azure region for the Azure AI Search service.')
param location string = resourceGroup().location

@description('Resource tags applied to the search service.')
param tags object = {}

@description('Name of the Azure AI Search service.')
param name string

@description('Search service SKU.')
param skuName string = 'free'

@description('Managed identity type for the search service. Kept None: the outbound service identity is unused here (APIM authenticates inbound to the data plane) and is not offered on the Free tier.')
param identityType string = 'None'

@description('Number of search replicas.')
param replicaCount int = 1

@description('Number of search partitions.')
param partitionCount int = 1

@description('Hosting mode for the search service.')
param hostingMode string = 'default'

@description('Public network access setting for the search service.')
param publicNetworkAccess string = 'enabled'

@description('Semantic search tier (disabled | free | standard).')
param semanticSearch string = 'free'

@description('Resource id of the Log Analytics workspace for diagnostic logs.')
param logAnalyticsWorkspaceId string = ''

@description('Emit resource logs to Log Analytics.')
param enableLogs bool = true

@description('Emit platform metrics to Log Analytics.')
param enableMetrics bool = true

@description('Ship verbose platform logs to Log Analytics.')
param enableVerboseLogs bool = false

resource search 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: name
  location: location
  tags: union(tags, { 'azd-service-name': name })
  sku: {
    name: skuName
  }
  identity: {
    type: identityType
  }
  properties: {
    replicaCount: replicaCount
    partitionCount: partitionCount
    hostingMode: hostingMode
    publicNetworkAccess: publicNetworkAccess
    semanticSearch: semanticSearch
    authOptions: {
      aadOrApiKey: {
        aadAuthFailureMode: 'http401WithBearerChallenge'
      }
    }
  }
}

resource diagnosticSettings 'Microsoft.Insights/diagnosticsettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
  name: 'Logging'
  scope: search
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: enableVerboseLogs
      ? [
          {
            category: null
            categoryGroup: 'allLogs'
            enabled: enableLogs
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

output id string = search.id
output name string = search.name
output endpoint string = 'https://${search.name}.search.windows.net'
