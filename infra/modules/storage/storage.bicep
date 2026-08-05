@description('Azure region for the storage account.')
param location string = resourceGroup().location

@description('Resource tags applied to the storage account.')
param tags object = {}

@description('Name of the storage account.')
param storageName string

@description('Resource id of the Log Analytics workspace for diagnostic logs.')
param logAnalyticsWorkspaceId string = ''

@description('Storage account kind. Defaults to StorageV2 (general-purpose v2).')
param kind string = 'StorageV2'

@description('Storage account SKU. Defaults to Standard_LRS.')
param sku string = 'Standard_LRS'

@description('Storage account access tier. Defaults to Hot.')
param accessTier string = 'Hot'

@description('Delete attachment/ingestion blobs older than this many days (lifecycle policy). 0 disables.')
param lifecycleDeleteAfterDays int = 90

module account './resources/account.bicep' = {
  name: storageName
  params: {
    location: location
    tags: tags
    name: storageName
    kind: kind
    sku: sku
    accessTier: accessTier
    lifecycleDeleteAfterDays: lifecycleDeleteAfterDays
  }
}

module blob './resources/blob.bicep' = {
  name: '${storageName}-blob'
  params: {
    accountName: account.outputs.name
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
  }
}

module file './resources/file.bicep' = {
  name: '${storageName}-file'
  params: {
    accountName: account.outputs.name
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
  }
}

module table './resources/table.bicep' = {
  name: '${storageName}-table'
  params: {
    accountName: account.outputs.name
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
  }
}

module queue './resources/queue.bicep' = {
  name: '${storageName}-queue'
  params: {
    accountName: account.outputs.name
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
  }
}

output accountId string = account.outputs.id
output accountName string = account.outputs.name
