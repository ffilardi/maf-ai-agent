@description('Azure region for the Foundry project.')
param location string = resourceGroup().location

@description('Name of the parent Foundry account.')
param accountName string

@description('Managed identity type for the project.')
param identityType string = 'SystemAssigned'

@description('Name of the Foundry project.')
param projectName string = 'default-project'

@description('Description of the Foundry project.')
param projectDescription string = 'Default Project for ${accountName}'

@description('Name of the storage account connected to the project.')
param storageName string = ''

@description('Name of the Cosmos DB account connected to the project.')
param cosmosDbName string = ''

@description('Name of the resource group holding shared (common) resources.')
param commonResourceGroupName string = ''

// AI Foundry Account
resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: accountName
}

// AI Foundry Project
resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' = {
  parent: account
  name: projectName
  location: location
  identity: {
    type: identityType
  }
  properties: {
    displayName: projectName
    description: projectDescription
  }
}

// Storage Account Connection
resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' existing = if (!empty(storageName)) {
  name: storageName
  scope: resourceGroup(commonResourceGroupName)
}

resource storageConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (!empty(storageName)) {
  parent: project
  name: 'storage-connection'
  properties: {
    category: 'AzureStorageAccount'
    target: storageAccount.properties.primaryEndpoints.blob
    authType: 'AAD'
    useWorkspaceManagedIdentity: false
    metadata: {
      ResourceId: storageAccount.id
      ApiType: 'Azure'
      location: storageAccount.location
    }
  }
}

// CosmosDB Connection
resource cosmosDb 'Microsoft.DocumentDB/databaseAccounts@2025-05-01-preview' existing = if (!empty(cosmosDbName)) {
  name: cosmosDbName
  scope: resourceGroup(commonResourceGroupName)
}

resource cosmosDbConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (!empty(cosmosDbName)) {
  parent: project
  name: 'cosmosdb-connection'
  properties: {
    category: 'CosmosDB'
    target: cosmosDb.properties.documentEndpoint
    authType: 'AAD'
    useWorkspaceManagedIdentity: false
    metadata: {
      ResourceId: cosmosDb.id
      ApiType: 'Azure'
      location: cosmosDb.location
    }
  }
}

output projectId string = project.id
output accountName string = accountName
output projectName string = project.name
output principalId string = project.identity.principalId
