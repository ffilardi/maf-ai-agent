@description('Name of the service the role assignments are scoped to.')
param serviceName string

@description('Built-in role names to assign to the principal.')
param roleNames array

@description('Object id of the principal receiving the role assignments.')
param principalId string

@description('Type of the principal receiving the role assignments.')
param principalType string = 'ServicePrincipal'

var builtInRoles = {
  'Key Vault Secrets User': '4633458b-17de-408a-b874-0445c86b69e6'
  'Key Vault Secrets Officer': 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
}

var roleDefinitionIds = [for roleName in roleNames: builtInRoles[roleName]]

resource service 'Microsoft.KeyVault/vaults@2021-10-01' existing = {
  name: serviceName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for roleDefinitionId in roleDefinitionIds: {
  scope: service
  name: guid(subscription().id, serviceName, principalId, roleDefinitionId)
  properties: {
    principalId: principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalType: principalType
  }
}]
