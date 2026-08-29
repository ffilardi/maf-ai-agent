@description('Azure region for the storage account.')
param location string = resourceGroup().location

@description('Resource tags applied to the storage account.')
param tags object = {}

@description('Name of the storage account.')
param name string

@description('Kind of storage account (e.g. StorageV2).')
param kind string

@description('Storage account SKU (redundancy).')
param sku string

@description('Blob access tier (Hot | Cool).')
param accessTier string

@description('Enable hierarchical namespace (Data Lake Gen2).')
param isHnsEnabled bool = false

@description('Enable the SFTP endpoint.')
param isSftpEnabled bool = false

@description('Managed identity type for the account.')
param identityType string = 'SystemAssigned'

@description('Minimum TLS version accepted by the account.')
param minimumTlsVersion string = 'TLS1_2'

@description('Require HTTPS-only traffic.')
param supportsHttpsTrafficOnly bool = true

@description('Allow anonymous public read access to blobs.')
param allowBlobPublicAccess bool = false

@description('Allow account-key (shared-key) authorization. Off by default: every caller (backend App Service, Foundry) authenticates with a managed identity, so a shared key is only a way around that.')
param allowSharedKeyAccess bool = false

@description('Default to Entra ID (OAuth) authorization in the portal. On, to match allowSharedKeyAccess.')
param defaultOAuth bool = true

@description('Scope allowed for copy operations.')
param allowedCopyScope string = 'PrivateLink'

@description('Allow cross-tenant object replication.')
param allowCrossTenantReplication bool = false

@description('Public network access setting for the account.')
param publicNetworkAccess string = 'Enabled'

@description('Services allowed to bypass network ACLs.')
param networkAclsBypass string = 'AzureServices'

@description('Default action when no network ACL rule matches.')
param networkAclsDefaultAction string = 'Allow'

@description('Virtual network rules allowed to access the account.')
param networkAclsVirtualNetworkRules array = []

@description('IP ranges allowed to access the account.')
param networkAclsIpRules array = []

@description('DNS endpoint type for the account.')
param dnsEndpointType string = 'Standard'

@description('Source of the encryption key.')
param keySource string = 'Microsoft.Storage'

@description('Enable service-side encryption for blob/file services.')
param encryptionEnabled bool = true

@description('Enable infrastructure (double) encryption.')
param infrastructureEncryptionEnabled bool = false

@description('Delete attachment/ingestion blobs older than this many days (lifecycle policy). 0 disables.')
param lifecycleDeleteAfterDays int = 90

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  location: location
  tags: union(tags, { 'azd-service-name': name })
  name: name
  kind: kind
  sku: {
    name: sku
  }
  identity: {
    type: identityType
  }
  properties: {
    minimumTlsVersion: minimumTlsVersion
    supportsHttpsTrafficOnly: supportsHttpsTrafficOnly
    allowBlobPublicAccess: allowBlobPublicAccess
    allowSharedKeyAccess: allowSharedKeyAccess
    defaultToOAuthAuthentication: defaultOAuth
    allowedCopyScope: allowedCopyScope
    accessTier: accessTier
    publicNetworkAccess: publicNetworkAccess
    allowCrossTenantReplication: allowCrossTenantReplication
    networkAcls: {
      bypass: networkAclsBypass
      defaultAction: networkAclsDefaultAction
      virtualNetworkRules: networkAclsVirtualNetworkRules
      ipRules: networkAclsIpRules
    }
    dnsEndpointType: dnsEndpointType
    isHnsEnabled: isHnsEnabled
    isSftpEnabled: isSftpEnabled
    encryption: {
      keySource: keySource
      services: {
        blob: {
          enabled: encryptionEnabled
        }
      }
      requireInfrastructureEncryption: infrastructureEncryptionEnabled
    }
  }
}

resource lifecyclePolicy 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = if (lifecycleDeleteAfterDays > 0) {
  parent: storageAccount
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'age-out-attachments'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: ['blockBlob']
            }
            actions: {
              baseBlob: {
                tierToCool: {
                  daysAfterModificationGreaterThan: lifecycleDeleteAfterDays / 2
                }
                delete: {
                  daysAfterModificationGreaterThan: lifecycleDeleteAfterDays
                }
              }
            }
          }
        }
      ]
    }
  }
}

output id string = storageAccount.id
output name string = storageAccount.name
