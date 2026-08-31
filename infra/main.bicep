// ================================================================================
// FILE: main.bicep
// PURPOSE: This file serves as the entry point for the Azure Bicep deployment.
// ================================================================================

targetScope = 'subscription'

@minLength(3)
@maxLength(10)
@description('Environment name for the deployment, used to create unique resource names.')
param environment string

@description('Primary location to deploy all resources.')
param location string

@description('Region for Azure Static Web Apps.')
@allowed([
  'westus2'
  'centralus'
  'eastus2'
  'westeurope'
  'eastasia'
])
param staticWebAppLocation string = 'westus2'

@description('Disable key-based authentication on the Cosmos DB account. Deploy it in TWO passes: the first provision creates the backend\'s Cosmos DB Data Contributor assignment, and only a later provision with this set to true may turn keys off. Flipping it in the same pass that creates the assignment can wedge the deployment and lock the app out of its own data.')
param disableCosmosLocalAuth bool = false

@description('Ship verbose allLogs platform logs to Log Analytics. True (default) = full gateway/resource request logs; set false for metrics-only and lower ingestion cost.')
param enableVerboseLogs bool = true

@description('Restrict the APIM gateway to the backend App Service with a service-scope ip-filter allow-list over the backend\'s outbound IPs. False (default) leaves the gateway open to any caller holding a valid subscription key.')
param restrictGatewayToBackend bool = false

@description('Extra IPs or CIDR ranges allowed through the gateway when restrictGatewayToBackend is true, e.g. a developer workstation running the backend against Azure.')
param additionalGatewayAllowedIps string[] = []

@description('Owner (team or individual) accountable for this deployment. Used for cost allocation.')
param owner string = 'unassigned'

@description('Application / workload name. Used for cost allocation.')
param application string = 'maf-ai-agent'

@description('Cost center or billing code charged for this deployment. Used for cost allocation.')
param costCenter string = 'unassigned'

// Set global tags for all resources
var tags object = {
  'azd-env-name': environment
  environment: environment
  owner: owner
  application: application
  'cost-center': costCenter
  'managed-by': 'bicep'
}

// Set global unique token
var token string = toLower(uniqueString(subscription().id, environment, location))

// ================================================================================
// Logs & Monitoring Services Deployment
// ================================================================================

var monitorResourceGroupName string = 'rg-monitor-${environment}-${token}'
var logAnalyticsName string = 'log-${environment}-${token}'
var applicationInsightsName string = 'appi-${environment}-${token}'
var opsWorkbookName string = 'ops-workbook-${environment}-${token}'
var workbookName string = 'workbook-${environment}-${token}'
var apimWorkbookName string = 'apim-workbook-${environment}-${token}'

resource monitorResourceGroup 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: monitorResourceGroupName
  location: location
  tags: tags
}

module monitor './modules/monitor/monitor.bicep' = {
  name: 'monitor'
  scope: monitorResourceGroup
  params: {
    location: location
    tags: tags
    logAnalyticsName: logAnalyticsName
    applicationInsightsName: applicationInsightsName
    opsWorkbookName: opsWorkbookName
    workbookName: workbookName
    apimWorkbookName: apimWorkbookName
  }
}

// ================================================================================
// Common Services Deployment
// ================================================================================

var commonResourceGroupName string = 'rg-common-${environment}-${token}'
var vaultName string = 'kv-${environment}-${token}'
var storageName string = 'st${replace(environment,'-','')}${token}'
var cosmosDbName string = 'cosmos-${environment}-${token}'

resource commonResourceGroup 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: commonResourceGroupName
  location: location
  tags: tags
}

module keyVault './modules/keyvault/keyvault.bicep' = {
  name: 'keyvault'
  scope: commonResourceGroup
  params: {
    location: location
    tags: tags
    vaultName: vaultName
    logAnalyticsWorkspaceId: monitor.outputs.logAnalyticsWorkspaceId
  }
}

module storage './modules/storage/storage.bicep' = {
  name: 'storage'
  scope: commonResourceGroup
  params: {
    location: location
    tags: tags
    storageName: storageName
    logAnalyticsWorkspaceId: monitor.outputs.logAnalyticsWorkspaceId
  }
}

module cosmosDb './modules/cosmosdb/cosmosdb.bicep' = {
  name: 'cosmosdb'
  scope: commonResourceGroup
  params: {
    location: location
    tags: tags
    cosmosDbName: cosmosDbName
    disableLocalAuth: disableCosmosLocalAuth
    logAnalyticsWorkspaceId: monitor.outputs.logAnalyticsWorkspaceId
    enableVerboseLogs: enableVerboseLogs
  }
}

// ================================================================================
// App & Integration Services Deployment
// ================================================================================

var appResourceGroupName string = 'rg-app-${environment}-${token}'
var webAppFrontendName string = 'stapp-frontend-${environment}-${token}'
var webAppBackendName string = 'app-backend-${environment}-${token}'
var webAppServicePlanName string = 'plan-app-${environment}-${token}'

resource appResourceGroup 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: appResourceGroupName
  location: location
  tags: tags
}

module appServices './modules/app/app.bicep' = {
  name: 'app-services'
  scope: appResourceGroup
  params: {
    location: location
    staticWebAppLocation: staticWebAppLocation
    tags: tags
    webAppFrontendName: webAppFrontendName
    webAppBackendName: webAppBackendName
    webAppServicePlanName: webAppServicePlanName
    appInsightsConnectionString: monitor.outputs.applicationInsightsConnectionString
    logAnalyticsWorkspaceId: monitor.outputs.logAnalyticsWorkspaceId
    commonResourceGroupName: commonResourceGroup.name
    aiResourceGroupName: aiResourceGroup.name
    keyVaultName: keyVault.outputs.vaultName
    cosmosDbName: cosmosDb.outputs.cosmosDbName
    storageName: storage.outputs.accountName
    searchServiceName: search.outputs.searchServiceName
    apimServiceName: apiManagement.outputs.apimServiceName
    chatModelDeployments: [foundry.outputs.chatModelName]
    embeddingModelDeployment: foundry.outputs.embeddingModelName
    enableVerboseLogs: enableVerboseLogs
  }
}

// ================================================================================
// AI Services Deployment
// ================================================================================

var aiResourceGroupName string = 'rg-ai-${environment}-${token}'
var foundryAccountName string = 'aif-${environment}-${token}'
var searchServiceName string = 'srch-${environment}-${token}'
var apimServiceName string = 'apim-${environment}-${token}'

resource aiResourceGroup 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: aiResourceGroupName
  location: location
  tags: tags
}

module foundry 'modules/foundry/foundry.bicep' = {
  name: 'foundry'
  scope: aiResourceGroup
  params: {
    location: location
    tags: tags
    foundryAccountName: foundryAccountName
    storageName: storage.outputs.accountName
    cosmosDbName: cosmosDb.outputs.cosmosDbName
    logAnalyticsWorkspaceId: monitor.outputs.logAnalyticsWorkspaceId
    commonResourceGroupName: commonResourceGroup.name
    enableVerboseLogs: enableVerboseLogs
  }
}

module search './modules/search/search.bicep' = {
  name: 'search'
  scope: aiResourceGroup
  params: {
    location: location
    tags: tags
    searchServiceName: searchServiceName
    logAnalyticsWorkspaceId: monitor.outputs.logAnalyticsWorkspaceId
    enableVerboseLogs: enableVerboseLogs
  }
}

module apiManagement './modules/apim/apim.bicep' = {
  name: 'api-management'
  scope: aiResourceGroup
  params: {
    location: location
    tags: tags
    apimServiceName: apimServiceName
    applicationInsightsId: monitor.outputs.applicationInsightsId
    applicationInsightsInstrumentationKey: monitor.outputs.applicationInsightsInstrumentationKey
    logAnalyticsWorkspaceId: monitor.outputs.logAnalyticsWorkspaceId
    foundryAccountName: foundry.outputs.foundryAccountName
    foundryAccountId: foundry.outputs.foundryAccountId
    searchServiceName: search.outputs.searchServiceName
    searchServiceId: search.outputs.searchServiceId
    keyVaultName: keyVault.outputs.vaultName
    commonResourceGroupName: commonResourceGroup.name
    enableVerboseLogs: enableVerboseLogs
  }
}

module apiManagementGlobalPolicy './modules/apim/resources/global-policy.bicep' = {
  name: 'api-management-global-policy'
  scope: aiResourceGroup
  params: {
    apimServiceName: apiManagement.outputs.apimServiceName
    allowedIpAddresses: restrictGatewayToBackend
      ? union(split(appServices.outputs.webAppBackendOutboundIpAddresses, ','), additionalGatewayAllowedIps)
      : []
  }
}

// Output the application resource group for code deployment via Azure Developer CLI
output AZURE_RESOURCE_GROUP string = appResourceGroup.name

// Output application hostnames
output AZURE_APIM_HOSTNAME string = apiManagement.outputs.apimServiceHostName
output AZURE_APIM_DEVELOPER_PORTAL string = apiManagement.outputs.apimServiceDeveloperPortalUrl
output AZURE_WEB_APP_FRONTEND_HOSTNAME string = appServices.outputs.webAppFrontendHostName
output AZURE_WEB_APP_BACKEND_HOSTNAME string = appServices.outputs.webAppBackendHostName
output VITE_AGENT_BACKEND_URL string = appServices.outputs.webAppBackendHostName
output COSMOS_DB_ENDPOINT string = cosmosDb.outputs.cosmosDbUri
output AI_SEARCH_ENDPOINT string = search.outputs.searchServiceEndpoint
