@description('Name of the service the role assignments are scoped to.')
param serviceName string

@description('Built-in role names to assign to the principal.')
param roleNames array

@description('Object id of the principal receiving the role assignments.')
param principalId string

@description('Type of the principal receiving the role assignments.')
param principalType string = 'ServicePrincipal'

var builtInRoles = {
  'Search Index Data Reader': '1407120a-92aa-4202-b7e9-c0e197c71c8f'
  'Search Index Data Contributor': '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
  'Search Service Contributor': '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
}

var roleDefinitionIds = [for roleName in roleNames: builtInRoles[roleName]]

resource service 'Microsoft.Search/searchServices@2024-06-01-preview' existing = {
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
