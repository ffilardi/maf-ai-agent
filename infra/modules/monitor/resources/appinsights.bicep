@description('Azure region for the Application Insights component.')
param location string = resourceGroup().location

@description('Resource tags applied to the Application Insights component.')
param tags object = {}

@description('Name of the Application Insights component.')
param name string

@description('Resource id of the Log Analytics workspace backing the component.')
param logAnalyticsWorkspaceId string

@description('Kind of Application Insights resource. Defaults to "web" for web apps.')
param kind string = 'web'

@description('Public network access for Application Insights query. Defaults to Enabled.')
param publicNetworkAccessForQuery string = 'Enabled'

@description('Public network access for Application Insights ingestion. Defaults to Enabled.')
param publicNetworkAccessForIngestion string = 'Enabled'

@description('App Insights telemetry sampling percentage (0-100) — caps telemetry ingestion cost.')
@minValue(0)
@maxValue(100)
param samplingPercentage int = 100

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  location: location
  tags: union(tags, { 'azd-service-name': name })
  name: name
  kind: kind
  properties: {
    Application_Type: kind
    WorkspaceResourceId: logAnalyticsWorkspaceId
    SamplingPercentage: samplingPercentage
    publicNetworkAccessForQuery: publicNetworkAccessForQuery
    publicNetworkAccessForIngestion: publicNetworkAccessForIngestion
  }
}

output id string = applicationInsights.id
output name string = applicationInsights.name
output connectionString string = applicationInsights.properties.ConnectionString
output instrumentationKey string = applicationInsights.properties.InstrumentationKey
