@description('Azure region for the monitoring resources.')
param location string = resourceGroup().location

@description('Resource tags applied to the monitoring resources.')
param tags object = {}

@description('Resource id of the Application Insights component the workbook queries.')
param logAnalyticsName string

@description('Name for the Log Analytics workspace.')
param applicationInsightsName string

@description('Name for the operational App Insights workbook.')
param opsWorkbookName string

@description('Name for the App Insights workbook.')
param workbookName string

module logAnalytics './resources/loganalytics.bicep' = {
  name: logAnalyticsName
  params: {
    location: location
    tags: tags
    name: logAnalyticsName
  }
}

module applicationInsights './resources/appinsights.bicep' = {
  name: applicationInsightsName
  params: {
    location: location
    tags: tags
    name: applicationInsightsName
    logAnalyticsWorkspaceId: logAnalytics.outputs.id
  }
}

module opsWorkbook './resources/ops-workbook.bicep' = {
  name: opsWorkbookName
  params: {
    location: location
    tags: tags
    name: opsWorkbookName
    appInsightsId: applicationInsights.outputs.id
  }
}

module workbook './resources/workbook.bicep' = {
  name: workbookName
  params: {
    location: location
    tags: tags
    name: workbookName
    appInsightsId: applicationInsights.outputs.id
  }
}

output logAnalyticsWorkspaceId string = logAnalytics.outputs.id
output logAnalyticsWorkspaceName string = logAnalytics.outputs.name
output applicationInsightsId string = applicationInsights.outputs.id
output applicationInsightsName string = applicationInsights.outputs.name
output applicationInsightsConnectionString string = applicationInsights.outputs.connectionString
output applicationInsightsInstrumentationKey string = applicationInsights.outputs.instrumentationKey
output opsWorkbookId string = opsWorkbook.outputs.id
output opsWorkbookName string = opsWorkbook.outputs.name
