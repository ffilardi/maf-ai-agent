@description('Azure region for the Key Vault.')
param location string = resourceGroup().location

@description('Resource tags applied to the Key Vault.')
param tags object = {}

@description('Name of the Key Vault.')
param name string

@description('SKU family for the Key Vault.')
param skuFamily string

@description('SKU tier for the Key Vault.')
param sku string

@description('Use Azure RBAC instead of access policies for authorization.')
param enableRbacAuthorization bool = true

@description('Allow ARM template deployments to retrieve secrets.')
param enabledForTemplateDeployment bool = true

@description('Days a soft-deleted vault is recoverable (7-90).')
@minValue(7)
@maxValue(90)
param softDeleteRetentionInDays int = 7

@description('Block purging a soft-deleted vault. Off by default and irreversible once on: it also blocks `azd down --purge` from reclaiming the vault name, which this repo\'s teardown flow relies on. Turn it on outside demo use.')
param enablePurgeProtection bool = false

@description('Public network access setting for the vault.')
param publicNetworkAccess string = 'Enabled'

@description('Services allowed to bypass network ACLs.')
param networkAclsBypass string = 'AzureServices'

@description('Default action when no network ACL rule matches.')
param networkAclsDefaultAction string = 'Allow'

@description('Virtual network rules allowed to access the vault.')
param networkAclsVirtualNetworkRules array = []

@description('IP ranges allowed to access the vault.')
param networkAclsIpRules array = []

@description('Resource id of the Log Analytics workspace for diagnostic logs.')
param logAnalyticsWorkspaceId string = ''

@description('Emit resource logs to Log Analytics.')
param enableLogs bool = true

@description('Emit audit-category logs to Log Analytics.')
param enableAuditLogs bool = false

@description('Emit platform metrics to Log Analytics.')
param enableMetrics bool = true

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  location: location
  tags: union(tags, { 'azd-service-name': name })
  name: name
  properties: {
    sku: {
      family: skuFamily
      name: sku
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: enableRbacAuthorization
    enabledForTemplateDeployment: enabledForTemplateDeployment
    softDeleteRetentionInDays: softDeleteRetentionInDays
    // Only ever sent as `true` — Key Vault rejects an explicit `false`, and the property can never be turned back off.
    enablePurgeProtection: enablePurgeProtection ? true : null
    publicNetworkAccess: publicNetworkAccess
    networkAcls: {
      bypass: networkAclsBypass
      defaultAction: networkAclsDefaultAction
      virtualNetworkRules: networkAclsVirtualNetworkRules
      ipRules: networkAclsIpRules
    }
  }
}

resource diagnosticSettings 'Microsoft.Insights/diagnosticsettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
  name: 'Logging'
  scope: vault
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'audit'
        enabled: enableAuditLogs
      }
      {
        categoryGroup: 'allLogs'
        enabled: enableLogs
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: enableMetrics
      }
    ]
  }
}

output id string = vault.id
output name string = vault.name
output uri string = vault.properties.vaultUri
