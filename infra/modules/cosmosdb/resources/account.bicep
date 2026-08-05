@description('Azure region for the Cosmos DB account.')
param location string = resourceGroup().location

@description('Resource tags applied to the Cosmos DB account.')
param tags object = {}

@description('Name of the Cosmos DB account.')
param name string

@description('Kind of Cosmos DB account to create.')
param kind string

@description('Offer type for the Cosmos DB account.')
param databaseAccountOfferType string

@description('Total throughput (RU/s) limit for the account.')
param totalThroughputLimit int

@description('Use serverless (per-request) billing.')
param useServerless bool = false

@description('Managed identity type for the account.')
param identityType string = 'SystemAssigned'

@description('Default consistency level for reads.')
param defaultConsistencyLevel string = 'Session'

@description('Maximum staleness window in seconds (bounded-staleness only).')
param maxIntervalInSeconds int = 5

@description('Maximum staleness in operations (bounded-staleness only).')
param maxStalenessPrefix int = 100

@description('Failover priority for the write region.')
param failoverPriority int = 0

@description('Make the write region zone-redundant.')
param isZoneRedundant bool = false

@description('Enable automatic regional failover.')
param enableAutomaticFailover bool = false

@description('Enable multi-region writes.')
param enableMultipleWriteLocations bool = false

@description('Restrict account access to selected virtual networks.')
param isVirtualNetworkFilterEnabled bool = false

@description('Enable the Cosmos free tier (one per subscription).')
param enableFreeTier bool = true

@description('Enable analytical storage on the account.')
param enableAnalyticalStorage bool = false

@allowed(['Periodic', 'Continuous'])
@description('Backup policy type for the account.')
param backupType string = 'Periodic'

@description('Interval between periodic backups, in minutes.')
param backupIntervalInMinutes int = 240

@description('Retention window for periodic backups, in hours.')
param backupRetentionIntervalInHours int = 8

@description('Periodic-backup storage redundancy (Local | Zone | Geo).')
param backupStorageRedundancy string = 'Local'

@description('Virtual network rules allowed to access the account.')
param virtualNetworkRules array = []

@description('Services allowed to bypass network ACLs.')
param networkAclBypass string = 'AzureServices'

@description('Resource ids allowed to bypass network ACLs.')
param networkAclBypassResourceIds array = []

@description('IP ranges allowed to access the account.')
param ipRules array = []

@description('Minimum TLS version accepted by the account.')
param minimalTlsVersion string = 'Tls12'

@description('Public network access setting for the account.')
param publicNetworkAccess string = 'Enabled'

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

resource account 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = {
  location: location
  tags: union(tags, { 'azd-service-name': name })
  name: name
  kind: kind
  identity: {
    type: identityType
  }
  properties: {
    databaseAccountOfferType: databaseAccountOfferType
    locations: [
      {
        locationName: location
        failoverPriority: failoverPriority
        isZoneRedundant: isZoneRedundant
      }
    ]
    consistencyPolicy: {
      defaultConsistencyLevel: defaultConsistencyLevel
      maxIntervalInSeconds: maxIntervalInSeconds
      maxStalenessPrefix: maxStalenessPrefix
    }
    capabilities: useServerless ? [{ name: 'EnableServerless' }] : []
    capacity: useServerless
      ? {}
      : {
          totalThroughputLimit: totalThroughputLimit
        }
    virtualNetworkRules: virtualNetworkRules
    ipRules: ipRules
    networkAclBypass: networkAclBypass
    networkAclBypassResourceIds: networkAclBypassResourceIds
    minimalTlsVersion: minimalTlsVersion
    publicNetworkAccess: publicNetworkAccess
    enableMultipleWriteLocations: enableMultipleWriteLocations
    enableAutomaticFailover: enableAutomaticFailover
    isVirtualNetworkFilterEnabled: isVirtualNetworkFilterEnabled
    enableFreeTier: useServerless ? false : enableFreeTier
    enableAnalyticalStorage: enableAnalyticalStorage
    backupPolicy: backupType == 'Periodic'
      ? {
          type: 'Periodic'
          periodicModeProperties: {
            backupIntervalInMinutes: backupIntervalInMinutes
            backupRetentionIntervalInHours: backupRetentionIntervalInHours
            backupStorageRedundancy: backupStorageRedundancy
          }
        }
      : {
          type: 'Continuous'
        }
  }
}

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
output endpoint string = account.properties.documentEndpoint
