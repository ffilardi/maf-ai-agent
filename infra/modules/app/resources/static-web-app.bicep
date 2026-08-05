@description('Azure region for the Static Web App.')
param location string = resourceGroup().location

@description('Resource tags applied to the Static Web App.')
param tags object = {}

@description('Name of the Static Web App.')
param name string

@description('Static Web App SKU (Free | Standard).')
param sku string

@description('Deployment provider for the Static Web App.')
param provider string = 'Custom'

@description('Policy for creating preview (staging) environments.')
param stagingEnvironmentPolicy string = 'Enabled'

@description('Allow the config file to override app settings.')
param allowConfigFileUpdates bool = true

resource app 'Microsoft.Web/staticSites@2024-04-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: sku
    tier: sku
  }
  properties: {
    provider: provider
    stagingEnvironmentPolicy: stagingEnvironmentPolicy
    allowConfigFileUpdates: allowConfigFileUpdates
  }
}

output name string = app.name
output defaultHostname string = app.properties.defaultHostname
