@description('Name of the parent storage account.')
param accountName string

@description('Enable the share soft-delete retention policy.')
param retentionPolicyEnabled bool = false

@description('Retention period in days for soft-deleted shares.')
param retentionPolicyDays int = 30

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

resource fileServices 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    shareDeleteRetentionPolicy: {
      days: retentionPolicyDays
      enabled: retentionPolicyEnabled
    }
  }
}

resource diagnosticSettings 'Microsoft.Insights/diagnosticsettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
  name: 'Logging'
  scope: fileServices
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
