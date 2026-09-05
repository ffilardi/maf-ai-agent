@description('Azure region for the AI Foundry account.')
param location string = resourceGroup().location

@description('Resource tags applied to the AI Foundry account.')
param tags object = {}

@description('Name of the AI Foundry account.')
param foundryAccountName string

@description('Name of the storage account associated with the Foundry project.')
param storageName string = ''

@description('Name of the Cosmos DB account associated with the Foundry project.')
param cosmosDbName string = ''

@description('Resource id of the Log Analytics workspace for diagnostic logs.')
param logAnalyticsWorkspaceId string = ''

@description('Name of the resource group holding shared (common) resources.')
param commonResourceGroupName string = ''

@description('Ship verbose platform logs to Log Analytics.')
param enableVerboseLogs bool = false

@description('Foundry SKU. Defaults to S0.')
param foundrySku string = 'S0'

@description('Foundry kind. Defaults to AIServices.')
param foundryKind string = 'AIServices'

@description('Disable local (key-based) authentication on the Foundry account. On by default: /openai, /documentintelligence, and /contentsafety are all reached through APIM, which injects its managed identity, so an account key would only bypass the gateway\'s token limits and content-safety pre-check.')
param disableLocalAuth bool = true

@description('Model SKU for the chat model deployment. Defaults to GlobalStandard.')
param chatModelSku string = 'GlobalStandard'

@description('GlobalStandard TPM ceiling (thousands of tokens/min) for the chat model deployment.')
param chatModelCapacity int = 1000

@description('Model SKU for the embedding model deployment. Defaults to GlobalStandard.')
param embeddingModelSku string = 'GlobalStandard'

@description('GlobalStandard TPM ceiling (thousands of tokens/min) for the embedding model deployment.')
param embeddingModelCapacity int = 150

var chatModel = {
  format: 'OpenAI'
  name: 'gpt-5.6-luna'
  version: '2026-03-17'
  sku: {
    name: chatModelSku
    capacity: chatModelCapacity
  }
}

var embeddingModel = {
  format: 'OpenAI'
  name: 'text-embedding-3-large'
  version: '1'
  sku: {
    name: embeddingModelSku
    capacity: embeddingModelCapacity
  }
}

// Foundry
module foundry './resources/account.bicep' = {
  name: foundryAccountName
  params: {
    location: location
    tags: tags
    name: foundryAccountName
    sku: foundrySku
    kind: foundryKind
    modelDeployments: [
      chatModel
      embeddingModel
    ]
    disableLocalAuth: disableLocalAuth
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    enableVerboseLogs: enableVerboseLogs
  }
}

module foundryRbac01 '../security/cosmosdb-rbac.bicep' = if (!empty(commonResourceGroupName) && !empty(cosmosDbName)) {
  name: '${foundryAccountName}-rbac-01'
  scope: resourceGroup(commonResourceGroupName)
  params: {
    serviceName: cosmosDbName
    roleNames: ['Cosmos DB Operator']
    principalId: foundry.outputs.principalId
  }
}

module foundryRbac02 '../security/storage-rbac.bicep' = if (!empty(commonResourceGroupName) && !empty(storageName)) {
  name: '${foundryAccountName}-rbac-02'
  scope: resourceGroup(commonResourceGroupName)
  params: {
    serviceName: storageName
    roleNames: ['Storage Blob Data Contributor']
    principalId: foundry.outputs.principalId
  }
}

// Foundry - Project
module foundryProject './resources/project.bicep' = {
  name: '${foundryAccountName}-project'
  params: {
    location: location
    accountName: foundry.name
    storageName: storageName
    cosmosDbName: cosmosDbName
    commonResourceGroupName: commonResourceGroupName
  }
}

module foundryProjectRbac01 '../security/foundryproject-rbac.bicep' = if (!empty(commonResourceGroupName) && !empty(cosmosDbName)) {
  name: '${foundryAccountName}-project-rbac-01'
  params: {
    accountName: foundryProject.outputs.accountName
    projectName: foundryProject.outputs.projectName
    roleNames: ['Foundry User']
    principalId: foundryProject.outputs.principalId
  }
}

output foundryAccountId string = foundry.outputs.id
output foundryAccountName string = foundry.outputs.name
output foundryAccountUri string = foundry.outputs.endpoint
output foundryProjectId string = foundryProject.outputs.projectId
output foundryProjectName string = foundryProject.outputs.projectName
output chatModelName string = chatModel.name
output embeddingModelName string = embeddingModel.name
