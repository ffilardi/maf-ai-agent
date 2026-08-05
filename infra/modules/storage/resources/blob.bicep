@description('Name of the parent storage account.')
param accountName string

@description('Enable soft delete for blobs.')
param isBlobSoftDeleteEnabled bool = true

@description('Retention period in days for soft-deleted blobs.')
param blobSoftDeleteRetentionDays int = 7

@description('Enable soft delete for containers.')
param isContainerSoftDeleteEnabled bool = true

@description('Retention period in days for soft-deleted containers.')
param containerSoftDeleteRetentionDays int = 7

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

resource blobServices 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: isBlobSoftDeleteEnabled
      days: blobSoftDeleteRetentionDays
    }
    containerDeleteRetentionPolicy: {
      enabled: isContainerSoftDeleteEnabled
      days: containerSoftDeleteRetentionDays
    }
  }
}

resource diagnosticSettings 'Microsoft.Insights/diagnosticsettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
  name: 'Logging'
  scope: blobServices
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
