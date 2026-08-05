@description('Azure region for the API Management service.')
param location string = resourceGroup().location

@description('Resource tags applied to the API Management service.')
param tags object = {}

@description('Name of the API Management service.')
param apimServiceName string

@description('Resource id of the Application Insights component for diagnostics.')
param applicationInsightsId string = ''

@description('Instrumentation key of the Application Insights component.')
param applicationInsightsInstrumentationKey string = ''

@description('Resource id of the Log Analytics workspace for diagnostic logs.')
param logAnalyticsWorkspaceId string = ''

@description('Name of the AI Foundry account fronted by the gateway.')
param foundryAccountName string = ''

@description('Resource id of the AI Foundry account fronted by the gateway.')
param foundryAccountId string = ''

@description('Name of the Azure AI Search service fronted by the gateway.')
param searchServiceName string = ''

@description('Resource id of the Azure AI Search service fronted by the gateway.')
param searchServiceId string = ''

@description('Name of the resource group holding shared (common) resources.')
param commonResourceGroupName string = ''

@description('Name of the Key Vault holding gateway secrets.')
param keyVaultName string = ''

@description('Ship verbose platform logs to Log Analytics.')
param enableVerboseLogs bool = false

module apimService './resources/service.bicep' = {
  name: apimServiceName
  params: {
    location: location
    tags: tags
    name: apimServiceName
    sku: 'Developer'
    skuCount: 1
    applicationInsightsId: applicationInsightsId
    applicationInsightsInstrumentationKey: applicationInsightsInstrumentationKey
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    enableVerboseLogs: enableVerboseLogs
  }
}

module apimServiceRbac01 '../security/keyvault-rbac.bicep' = if (!empty(commonResourceGroupName) && !empty(keyVaultName)) {
  name: '${apimServiceName}-rbac-01'
  scope: resourceGroup(commonResourceGroupName)
  params: {
    serviceName: keyVaultName
    roleNames: ['Key Vault Secrets User']
    principalId: apimService.outputs.principalId
  }
}

module apimServiceRbac02 '../security/foundry-rbac.bicep' = if (!empty(foundryAccountName)) {
  name: '${apimServiceName}-rbac-02'
  params: {
    serviceName: foundryAccountName
    roleNames: ['Cognitive Services OpenAI User', 'Cognitive Services User']
    principalId: apimService.outputs.principalId
  }
}

module apimServiceRbac03 '../security/search-rbac.bicep' = if (!empty(searchServiceName)) {
  name: '${apimServiceName}-rbac-03'
  params: {
    serviceName: searchServiceName
    roleNames: ['Search Index Data Reader', 'Search Index Data Contributor', 'Search Service Contributor']
    principalId: apimService.outputs.principalId
  }
}

module apimFoundryApi './resources/api.bicep' = if (!empty(foundryAccountId) && !empty(foundryAccountName)) {
  name: 'apim-foundry-api'
  params: {
    apimServiceName: apimServiceName
    apiName: 'ai-foundry-api'
    apiDisplayName: 'Azure AI Foundry OpenAI API'
    apiDescription: 'Azure AI Foundry OpenAI Response API'
    apiPath: 'openai'
    apiDefinition: loadTextContent('api/foundry-openapi.json')
    apiPolicy: loadTextContent('policies/foundry-api-policy.xml')
    // Surface the gateway's LLM rate/token-limit accounting headers in diagnostics
    additionalHeadersToLog: [
      'x-ratelimit-limit-requests'
      'x-ratelimit-remaining-requests'
      'x-ratelimit-limit-tokens'
      'x-ratelimit-remaining-tokens'
      'x-apim-ratelimit-consumed-tokens'
      'x-apim-ratelimit-remaining-tokens'
      'x-apim-ratelimit-remaining-quota-tokens'
      'x-ms-deployment-name'
    ]
    backendUrls: [
      'https://${foundryAccountName}.services.ai.azure.com/openai'
    ]
    backendResourceIds: [
      foundryAccountId
    ]
    enableLoadBalancing: true
    applicationInsightsLoggerName: apimService.outputs.applicationInsightsLoggerName
    enableApplicationInsightsDiagnostics: !empty(apimService.outputs.applicationInsightsLoggerName)
  }
  dependsOn: [
    apimServiceRbac02
  ]
}

module apimDocIntelApi './resources/api.bicep' = if (!empty(foundryAccountId) && !empty(foundryAccountName)) {
  name: 'apim-document-intelligence-api'
  params: {
    apimServiceName: apimServiceName
    apiName: 'ai-document-intelligence-api'
    apiDisplayName: 'Azure AI Document Intelligence API'
    apiDescription: 'Azure AI Document Intelligence Layout API'
    apiPath: 'documentintelligence'
    apiDefinition: loadTextContent('api/document-intelligence-openapi.json')
    apiPolicy: loadTextContent('policies/document-intelligence-api-policy.xml')
    // The Document Intelligence SDK sends the key as Ocp-Apim-Subscription-Key (the native Cognitive Services subscription-key header)
    subscriptionKeyHeaderName: 'Ocp-Apim-Subscription-Key'
    subscriptionKeyQueryName: 'subscription-key'
    backendUrls: [
      'https://${foundryAccountName}.cognitiveservices.azure.com/documentintelligence'
    ]
    backendResourceIds: [
      foundryAccountId
    ]
    enableLoadBalancing: true
    applicationInsightsLoggerName: apimService.outputs.applicationInsightsLoggerName
    enableApplicationInsightsDiagnostics: !empty(apimService.outputs.applicationInsightsLoggerName)
  }
  dependsOn: [
    apimServiceRbac02
  ]
}

module apimContentSafetyApi './resources/api.bicep' = if (!empty(foundryAccountId) && !empty(foundryAccountName)) {
  name: 'apim-content-safety-api'
  params: {
    apimServiceName: apimServiceName
    apiName: 'ai-content-safety-api'
    apiDisplayName: 'Azure AI Content Safety API'
    apiDescription: 'Azure AI Content Safety text moderation + Prompt Shields'
    apiPath: 'contentsafety'
    apiDefinition: loadTextContent('api/content-safety-openapi.json')
    apiPolicy: loadTextContent('policies/content-safety-api-policy.xml')
    // The backend calls Content Safety with the key as Ocp-Apim-Subscription-Key (the native Cognitive Services subscription-key header)
    subscriptionKeyHeaderName: 'Ocp-Apim-Subscription-Key'
    subscriptionKeyQueryName: 'subscription-key'
    backendUrls: [
      'https://${foundryAccountName}.cognitiveservices.azure.com/contentsafety'
    ]
    backendResourceIds: [
      foundryAccountId
    ]
    enableLoadBalancing: true
    applicationInsightsLoggerName: apimService.outputs.applicationInsightsLoggerName
    enableApplicationInsightsDiagnostics: !empty(apimService.outputs.applicationInsightsLoggerName)
  }
  dependsOn: [
    apimServiceRbac02
  ]
}

module apimSearchApi './resources/api.bicep' = if (!empty(searchServiceId) && !empty(searchServiceName)) {
  name: 'apim-search-api'
  params: {
    apimServiceName: apimServiceName
    apiName: 'ai-search-api'
    apiDisplayName: 'Azure AI Search API'
    apiDescription: 'Azure AI Search Query API'
    apiPath: 'search'
    apiDefinition: loadTextContent('api/search-openapi.json')
    apiPolicy: loadTextContent('policies/search-api-policy.xml')
    backendUrls: [
      'https://${searchServiceName}.search.windows.net'
    ]
    backendResourceIds: [
      searchServiceId
    ]
    enableLoadBalancing: true
    applicationInsightsLoggerName: apimService.outputs.applicationInsightsLoggerName
    enableApplicationInsightsDiagnostics: !empty(apimService.outputs.applicationInsightsLoggerName)
  }
  dependsOn: [
    apimServiceRbac03
  ]
}

output apimServiceId string = apimService.outputs.id
output apimServiceName string = apimService.outputs.name
output apimServiceHostName string = apimService.outputs.hostName
output apimServiceDeveloperPortalUrl string = apimService.outputs.developerPortalUrl
output apimServicePrincipalId string = apimService.outputs.principalId
output applicationInsightsLoggerName string = apimService.outputs.applicationInsightsLoggerName
