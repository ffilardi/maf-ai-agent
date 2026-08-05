@description('Azure region for the Key Vault.')
param location string = resourceGroup().location

@description('Resource tags applied to the Key Vault.')
param tags object = {}

@description('Name of the Key Vault.')
param vaultName string

@description('Resource id of the Log Analytics workspace for diagnostic logs.')
param logAnalyticsWorkspaceId string = ''


module vault './resources/vault.bicep' = {
  name: vaultName
  params: {
    location: location
    tags: tags
    name: vaultName
    skuFamily: 'A'
    sku: 'standard'
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
  }
}

output vaultId string = vault.outputs.id
output vaultName string = vault.outputs.name
output vaultEndpoint string = vault.outputs.uri
