@description('Azure region for the Azure AI Search service.')
param location string = resourceGroup().location

@description('Resource tags applied to the search service.')
param tags object = {}

@description('Name of the Azure AI Search service.')
param searchServiceName string

@description('Search service SKU. Free tier supports hybrid + semantic ranking (in supported regions, e.g. australiaeast) subject to Free-tier limits: 50 MB storage, one free service per subscription, no SLA, not recommended for large workloads.')
param skuName string = 'free'

@description('Semantic ranker billing plan (disabled | free | standard). The free plan is a monthly free-query allowance available on every tier, including Free.')
param semanticSearch string = 'free'

@description('Number of search replicas.')
param replicaCount int = 1

@description('Resource id of the Log Analytics workspace for diagnostic logs.')
param logAnalyticsWorkspaceId string = ''

@description('Ship verbose platform logs to Log Analytics.')
param enableVerboseLogs bool = false

module service './resources/service.bicep' = {
  name: searchServiceName
  params: {
    location: location
    tags: tags
    name: searchServiceName
    skuName: skuName
    semanticSearch: semanticSearch
    replicaCount: replicaCount
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    enableVerboseLogs: enableVerboseLogs
  }
}

output searchServiceId string = service.outputs.id
output searchServiceName string = service.outputs.name
output searchServiceEndpoint string = service.outputs.endpoint
