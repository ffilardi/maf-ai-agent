@description('Azure region for the Log Analytics workspace.')
param location string = resourceGroup().location

@description('Resource tags applied to the Log Analytics workspace.')
param tags object = {}

@description('Name of the Log Analytics workspace.')
param name string

@description('Log Analytics workspace SKU. Defaults to PerGB2018.')
param sku string = 'PerGB2018'

@description('Log Analytics workspace public network access for query. Defaults to Enabled.')
param publicNetworkAccessForQuery string = 'Enabled'

@description('Log Analytics workspace public network access for ingestion. Defaults to Enabled.')
param publicNetworkAccessForIngestion string = 'Enabled'

@description('Log Analytics workspace retention in days. Defaults to 30.')
param retentionInDays int = 30

@description('Log Analytics daily ingestion cap in GB — spend guard against runaway logging. -1 disables.')
param dailyQuotaGb int = 1

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2021-12-01-preview' = {
  location: location
  tags: union(tags, { 'azd-service-name': name })
  name: name
  properties: any({
    sku: {
      name: sku
    }
    features: {
      searchVersion: 1
    }
    retentionInDays: retentionInDays
    workspaceCapping: {
      dailyQuotaGb: dailyQuotaGb
    }
    publicNetworkAccessForIngestion: publicNetworkAccessForIngestion
    publicNetworkAccessForQuery: publicNetworkAccessForQuery
  })
}

output id string = logAnalytics.id
output name string = logAnalytics.name
