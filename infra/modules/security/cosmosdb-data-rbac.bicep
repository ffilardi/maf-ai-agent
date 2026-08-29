@description('Name of the Cosmos DB account the role assignment is scoped to.')
param serviceName string

@description('Object id of the principal receiving the data-plane role.')
param principalId string

@description('Built-in SQL role: 00000000-...-0001 Data Reader, 00000000-...-0002 Data Contributor.')
param roleDefinitionId string = '00000000-0000-0000-0000-000000000002'

// Cosmos data-plane access is a separate role system from Azure RBAC: the control-plane roles in
// cosmosdb-rbac.bicep (Cosmos DB Operator, Account Reader) grant no access to documents at all, which is why
// this needs its own module rather than another entry in that file's builtInRoles map.
resource service 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = {
  name: serviceName
}

resource roleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15' = {
  parent: service
  name: guid(service.id, principalId, roleDefinitionId)
  properties: {
    principalId: principalId
    roleDefinitionId: '${service.id}/sqlRoleDefinitions/${roleDefinitionId}'
    scope: service.id
  }
}
