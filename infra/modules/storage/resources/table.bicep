@description('Name of the parent storage account.')
param accountName string

@description('Resource id of the Log Analytics workspace for diagnostic logs.')
param logAnalyticsWorkspaceId string = ''

@description('Emit resource logs to Log Analytics.')
param enableLogs bool = true

@description('Emit audit-category logs to Log Analytics.')
param enableAuditLogs bool = false

@description('Emit platform metrics to Log Analytics.')
param enableMetrics bool = true

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: accountName
}

resource tableServices 'Microsoft.Storage/storageAccounts/tableServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {}
}

resource diagnosticSettings 'Microsoft.Insights/diagnosticsettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
  name: 'Logging'
  scope: tableServices
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
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
    metrics: [
      {
        category: 'AllMetrics'
        enabled: enableMetrics
      }
    ]
  }
}
