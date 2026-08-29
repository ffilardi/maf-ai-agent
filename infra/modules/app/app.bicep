@description('Azure region for the backend App Service and plan.')
param location string = resourceGroup().location

@description('Azure region for the Static Web App (SWA is region-limited).')
param staticWebAppLocation string

@description('Resource tags applied to the app resources.')
param tags object = {}

@description('Name of the frontend Static Web App.')
param webAppFrontendName string

@description('Name of the backend App Service.')
param webAppBackendName string

@description('Name of the backend App Service Plan.')
param webAppServicePlanName string

@description('Deployment slot names to create on the backend App Service.')
param webAppBackendStagingSlots array = []

@description('Resource id of the Log Analytics workspace for diagnostic logs.')
param logAnalyticsWorkspaceId string = ''

@description('Application Insights connection string for backend telemetry.')
param appInsightsConnectionString string = ''

@description('Ship verbose platform logs to Log Analytics.')
param enableVerboseLogs bool = false

@description('Name of the resource group holding shared (common) resources.')
param commonResourceGroupName string = ''

@description('Name of the resource group holding AI resources.')
param aiResourceGroupName string = ''

@description('Name of the Key Vault the backend reads secrets from.')
param keyVaultName string = ''

@description('Name of the Cosmos DB account for conversation history.')
param cosmosDbName string = ''

@description('Name of the storage account for file-ingestion artifacts.')
param storageName string = ''

@description('Name of the Azure AI Search service for RAG.')
param searchServiceName string = ''

@description('Name of the API Management service fronting model traffic.')
param apimServiceName string = ''

@description('Array of selectable AI model deployments for the SPA. The first entry is the default.')
param chatModelDeployments array = []

@description('Embedding model deployment name for the backend.')
param embeddingModelDeployment string = ''

@description('Search index name for the backend. Defaults to "agent-knowledge-index".')
param searchIndexName string = 'agent-knowledge-index'

@description('Storage container name for attachments. Defaults to "attachments".')
param storageContainerName string = 'attachments'

@description('Backend App Service Plan tier. Basic is the functional floor: it enables Always On (the ingestion BackgroundService needs it), 64-bit, and lifts the Free-tier daily CPU quota. Free/Shared (F1/D1) cannot host this backend.')
param appServicePlanSku string = 'Basic'

@description('Backend App Service Plan size code. B1 (1 vCPU / 1.75 GB) is the default — the workload is I/O-bound (LLM/OCR/embeddings offloaded to APIM). Bump to B2 if a large-file ingestion overlapping concurrent streams saturates the single core.')
param appServicePlanSkuCode string = 'B1'

@description('Backend App Service Plan kind.')
param appServicePlanKind string = 'linux'

@description('Backend App Service kind. Defaults to app,linux.')
param webAppServiceKind string = 'app,linux'

@description('Backend App Service Linux FX version. Defaults to DOTNETCORE|10.0.')
param webAppLinuxFxVersion string = 'DOTNETCORE|10.0'

@description('Static Web App SKU (Free | Standard).')
param staticWebAppSku string = 'Free'

@description('Content Safety pre-check mode (off | log | block). Defaults to block (reject flagged turns). Forced off when APIM is absent.')
param contentSafetyMode string = 'block'

@description('Enable Content Safety Prompt Shields (jailbreak / prompt-injection detection) in the Content Safety pre-check.')
param contentSafetyShieldPrompt bool = true

@description('Days after which stored conversation transcripts expire. 0 (default) = never expire.')
param historyTtlDays int = 0

// Backend app settings, merged with the defaults in app-service.bicep.
var appSettings = [
  {
    name: 'APIM_GATEWAY_ENDPOINT'
    value: !empty(apim.name) ? apim.properties.gatewayUrl : ''
  }
  {
    name: 'APIM_SUBSCRIPTION_KEY'
    value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=apim-aifoundry-api-key)'
  }
  {
    name: 'AI_MODEL_DEPLOYMENTS'
    value: join(chatModelDeployments, ',')
  }
  {
    name: 'AI_EMBEDDING_DEPLOYMENT'
    value: embeddingModelDeployment
  }
  {
    name: 'COSMOS_ENDPOINT'
    value: !empty(cosmosDb.name) ? cosmosDb.properties.documentEndpoint : ''
  }
  {
    // No COSMOS_KEY: the backend's managed identity holds the Cosmos DB Data Contributor role (webAppBackendRbac04).
    name: 'COSMOS_USE_RBAC'
    value: 'true'
  }
  {
    name: 'MAX_HISTORY_TTL_DAYS'
    value: string(historyTtlDays)
  }
  {
    name: 'AI_SEARCH_ENDPOINT'
    value: (!empty(apim.name) && !empty(search.name)) ? '${apim.properties.gatewayUrl}/search' : ''
  }
  {
    name: 'AI_SEARCH_SUBSCRIPTION_KEY'
    value: !empty(apim.name) ? '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=apim-aifoundry-api-key)' : ''
  }
  {
    name: 'AI_SEARCH_INDEX'
    value: searchIndexName
  }
  {
    name: 'STORAGE_ACCOUNT_NAME'
    value: storageName
  }
  {
    name: 'STORAGE_CONTAINER'
    value: storageContainerName
  }
  {
    name: 'DOCINTEL_ENDPOINT'
    value: !empty(apim.name) ? apim.properties.gatewayUrl : ''
  }
  {
    // Withhold the effective base prompt from GET /config: it hands an unauthenticated caller the tool contract to craft around.
    name: 'EXPOSE_DEFAULT_PROMPT'
    value: 'false'
  }
  {
    // Content Safety per-turn pre-check; deployed in `block` mode (reject flagged turns) with Prompt Shields on.
    // Drop to `log` (analyze + log, never block) to observe/tune before enforcing.
    name: 'CONTENT_SAFETY_MODE'
    value: !empty(apim.name) ? contentSafetyMode : 'off'
  }
  {
    name: 'CONTENT_SAFETY_SHIELD_PROMPT'
    value: string(contentSafetyShieldPrompt)
  }
  {
    name: 'ALLOWED_ORIGINS'
    value: 'https://${webAppFrontend.outputs.defaultHostname}'
  }
]

// CORS origins for the backend service. Defaults to portal + frontend.
var allowedOrigins = empty(webAppFrontend)
  ? ['https://portal.azure.com']
  : union(['https://portal.azure.com'], ['https://${webAppFrontend.outputs.defaultHostname}'])

// Base Resources
resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = if (!empty(apimServiceName) && !empty(aiResourceGroupName)) {
  name: apimServiceName
  scope: resourceGroup(aiResourceGroupName)
}

resource cosmosDb 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = if (!empty(cosmosDbName) && !empty(commonResourceGroupName)) {
  name: cosmosDbName
  scope: resourceGroup(commonResourceGroupName)
}

resource search 'Microsoft.Search/searchServices@2024-06-01-preview' existing = if (!empty(searchServiceName) && !empty(aiResourceGroupName)) {
  name: searchServiceName
  scope: resourceGroup(aiResourceGroupName)
}

// Vault Secrets
module apimVaultSecret '../keyvault/resources/secret.bicep' = if (!empty(apim.name) && !empty(keyVaultName) && !empty(commonResourceGroupName)) {
  name: 'apim-secret'
  scope: resourceGroup(commonResourceGroupName)
  params: {
    vaultName: keyVaultName
    secretName: 'apim-aifoundry-api-key'
    secretValue: !empty(apim.name) ? listSecrets('${apim.id}/subscriptions/ai-gateway', '2024-05-01').primaryKey : ''
  }
}

// Agent Frontend
module webAppFrontend './resources/static-web-app.bicep' = {
  name: 'agent-frontend'
  params: {
    location: staticWebAppLocation
    tags: union(tags, { 'azd-service-name': 'agent-frontend' })
    name: webAppFrontendName
    sku: staticWebAppSku
  }
}

// App Service Plan (Backend)
module webAppServicePlan './resources/app-service-plan.bicep' = {
  name: 'web-app-service-plan'
  params: {
    location: location
    tags: tags
    name: webAppServicePlanName
    sku: appServicePlanSku
    skuCode: appServicePlanSkuCode
    kind: appServicePlanKind
    reserved: appServicePlanKind == 'linux' ? true : false
  }
}

// Agent Backend
module webAppBackend './resources/app-service.bicep' = {
  name: 'agent-backend'
  params: {
    location: location
    tags: union(tags, { 'azd-service-name': 'agent-backend' })
    name: webAppBackendName
    servicePlanId: webAppServicePlan.outputs.id
    kind: webAppServiceKind
    linuxFxVersion: webAppLinuxFxVersion
    healthCheckPath: '/ping'
    allowedOrigins: allowedOrigins
    appInsightsConnectionString: appInsightsConnectionString
    appSettings: appSettings
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    enableVerboseLogs: enableVerboseLogs
  }
}

module webAppBackendRbac01 '../security/keyvault-rbac.bicep' = if (!empty(commonResourceGroupName) && !empty(keyVaultName)) {
  name: '${webAppBackendName}-rbac-01'
  scope: resourceGroup(commonResourceGroupName)
  params: {
    serviceName: keyVaultName
    roleNames: ['Key Vault Secrets User']
    principalId: webAppBackend.outputs.principalId
  }
}

module webAppBackendRbac02 '../security/cosmosdb-rbac.bicep' = if (!empty(commonResourceGroupName) && !empty(cosmosDbName)) {
  name: '${webAppBackendName}-rbac-02'
  scope: resourceGroup(commonResourceGroupName)
  params: {
    serviceName: cosmosDbName
    roleNames: ['Cosmos DB Operator']
    principalId: webAppBackend.outputs.principalId
  }
}

// Data-plane access to the conversation store. Cosmos keeps documents behind its own SQL role system, so the
// control-plane 'Cosmos DB Operator' above grants none of it.
module webAppBackendRbac04 '../security/cosmosdb-data-rbac.bicep' = if (!empty(commonResourceGroupName) && !empty(cosmosDbName)) {
  name: '${webAppBackendName}-rbac-04'
  scope: resourceGroup(commonResourceGroupName)
  params: {
    serviceName: cosmosDbName
    principalId: webAppBackend.outputs.principalId
  }
}

module webAppBackendRbac03 '../security/storage-rbac.bicep' = if (!empty(commonResourceGroupName) && !empty(storageName)) {
  name: '${webAppBackendName}-rbac-03'
  scope: resourceGroup(commonResourceGroupName)
  params: {
    serviceName: storageName
    roleNames: [
      'Storage Blob Data Contributor'
      'Storage Queue Data Contributor'
      'Storage Table Data Contributor'
    ]
    principalId: webAppBackend.outputs.principalId
  }
}

// Agent Backend Staging Slots
module webAppBackendSlot './resources/app-service-slot.bicep' = [
  for slot in webAppBackendStagingSlots: {
    name: '${webAppBackendName}-${slot.name}'
    params: {
      location: location
      tags: union(tags, { 'azd-service-name': '${webAppBackendName}-${slot.name}' })
      name: slot.name
      appServiceName: webAppBackend.outputs.name
      servicePlanId: webAppServicePlan.outputs.id
      kind: webAppServiceKind
      linuxFxVersion: webAppLinuxFxVersion
      allowedOrigins: allowedOrigins
      appSettings: appSettings
      appInsightsConnectionString: appInsightsConnectionString
    }
  }
]

output webAppFrontendName string = webAppFrontend.outputs.name
output webAppFrontendHostName string = 'https://${webAppFrontend.outputs.defaultHostname}'
output webAppBackendId string = webAppBackend.outputs.id
output webAppBackendName string = webAppBackend.outputs.name
output webAppBackendHostName string = webAppBackend.outputs.defaultHostName
output webAppBackendPrincipalId string = webAppBackend.outputs.principalId
output webAppBackendOutboundIpAddresses string = webAppBackend.outputs.outboundIpAddresses
