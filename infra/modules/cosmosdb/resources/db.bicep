@description('Name of the parent Cosmos DB account.')
param accountName string

@description('Name of the SQL database to create.')
param name string

@description('Name of the container to create in the database.')
param containerName string

@description('Partition key path for the container.')
param partitionKey string

@description('Indexing mode for the container.')
param indexingMode string = 'consistent'

@description('Partition key kind for the container.')
param partitionKeyKind string = 'Hash'

@description('Partition key definition version.')
param partitionKeyVersion int = 2

@description('Conflict resolution policy mode for the container.')
param conflictResolutionPolicyMode string = 'LastWriterWins'

resource account 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' existing = {
  name: accountName
}

resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-05-15' = {
  parent: account
  name: name
  properties: {
    resource: {
      id: name
    }
  }
}

resource container 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-05-15' = {
  parent: database
  name: containerName
  properties: {
    resource: {
      id: containerName
      indexingPolicy: {
        indexingMode: indexingMode
        automatic: true
        includedPaths: [
          {
            path: '/*'
          }
        ]
        excludedPaths: [
          {
            path: '/"_etag"/?'
          }
        ]
      }
      partitionKey: {
        paths: [
          partitionKey
        ]
        kind: partitionKeyKind
        version: partitionKeyVersion
      }
      uniqueKeyPolicy: {
        uniqueKeys: []
      }
      conflictResolutionPolicy: {
        mode: conflictResolutionPolicyMode
        conflictResolutionPath: '/_ts'
      }
    }
  }
}

output id string = database.id
output name string = database.name
output container string = container.name
