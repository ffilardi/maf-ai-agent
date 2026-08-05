@description('Name of the service the role assignments are scoped to.')
param serviceName string

@description('Built-in role names to assign to the principal.')
param roleNames array

@description('Object id of the principal receiving the role assignments.')
param principalId string

@description('Type of the principal receiving the role assignments.')
param principalType string = 'ServicePrincipal'

var builtInRoles = {
  'Azure AI User': '53ca6127-db72-4b80-b1b0-d745d6d5456d'
  'Azure AI Project Manager': 'eadc314b-1a2d-4efa-be10-5d325db5065e'
  'Azure AI Account Owner': 'e47c6f54-e4a2-4754-9501-8e0985b135e1'
  'Cognitive Services OpenAI User': '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
  'Cognitive Services User': 'a97b65f3-24c7-4388-baec-2e87135dc908'
}

var roleDefinitionIds = [for roleName in roleNames: builtInRoles[roleName]]

resource service 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
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
