@description('Name of the Key Vault that holds the secret.')
param vaultName string

@description('Name of the secret to create.')
param secretName string

@description('Value stored in the secret.')
@secure()
param secretValue string

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: vaultName
}

resource vaultSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: secretName
  properties: {
    value: secretValue
  }
}

output reference string = '@Microsoft.KeyVault(VaultName=${vault.name};SecretName=${secretName})'
