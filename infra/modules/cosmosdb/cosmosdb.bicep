@description('Azure region for the Cosmos DB account.')
param location string = resourceGroup().location

@description('Resource tags applied to the Cosmos DB account.')
param tags object = {}

@description('Name of the Cosmos DB account.')
param cosmosDbName string

@description('Resource id of the Log Analytics workspace for diagnostic logs.')
param logAnalyticsWorkspaceId string = ''

@description('Ship verbose platform logs to Log Analytics.')
param enableVerboseLogs bool = false

@description('The kind of Cosmos DB account to create. Default is GlobalDocumentDB for multi-region replication.')
param kind string = 'GlobalDocumentDB'

@description('The offer type for the Cosmos DB account. Default is Standard.')
param databaseAccountOfferType string = 'Standard'

@description('The total throughput limit for the Cosmos DB account.')
param totalThroughputLimit int = 1000

@description('Use Cosmos serverless (per-request) billing. Default false keeps the provisioned + free-tier account.')
param useServerless bool = false

@description('Enable the Cosmos free tier (one per subscription). Disabled for prod-tier accounts.')
param enableFreeTier bool = true

@description('Periodic-backup storage redundancy (Local | Zone | Geo).')
param backupStorageRedundancy string = 'Local'

@description('Zone-redundant write region. Requires an availability-zone-capable location.')
param isZoneRedundant bool = false

@description('Disable local (key-based) authentication on the account. Requires the backend\'s data-plane role assignment to already exist — see main.bicep.')
param disableLocalAuth bool = false

var databases array = [
  {
    name: 'agent_db'
    container: 'conversations'
    partitionKey: '/conversationId'
  }
]

module account './resources/account.bicep' = {
  name: cosmosDbName
  params: {
    location: location
    tags: tags
    name: cosmosDbName
    kind: kind
    databaseAccountOfferType: databaseAccountOfferType
    totalThroughputLimit: totalThroughputLimit
    useServerless: useServerless
    enableFreeTier: enableFreeTier
    backupStorageRedundancy: backupStorageRedundancy
    isZoneRedundant: isZoneRedundant
    disableLocalAuth: disableLocalAuth
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    enableVerboseLogs: enableVerboseLogs
  }
}

module database './resources/db.bicep' = [
  for db in databases: {
    name: '${cosmosDbName}-${db.name}'
    params: {
      accountName: account.outputs.name
      name: db.name
      containerName: db.container
      partitionKey: db.partitionKey
    }
  }
]

output cosmosDbId string = account.outputs.id
output cosmosDbName string = account.outputs.name
output cosmosDbUri string = account.outputs.endpoint
