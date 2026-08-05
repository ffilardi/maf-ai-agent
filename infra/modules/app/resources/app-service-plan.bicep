@description('Azure region for the App Service Plan.')
param location string = resourceGroup().location

@description('Resource tags applied to the App Service Plan.')
param tags object = {}

@description('Name of the App Service Plan.')
param name string

@description('App Service Plan SKU tier.')
param sku string

@description('App Service Plan SKU size code.')
param skuCode string

@description('Reserve the plan for Linux workloads.')
param reserved bool

@description('Kind of App Service Plan (e.g. linux).')
param kind string = ''

@description('Enable zone redundancy for the plan.')
param zoneRedundant bool = false

resource servicePlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  location: location
  tags: union(tags, { 'azd-service-name': name })
  name: name
  sku: {
    name: skuCode
    tier: sku
  }
  kind: kind
  properties: {
    reserved: reserved
    zoneRedundant: zoneRedundant
  }
}

output id string = servicePlan.id
