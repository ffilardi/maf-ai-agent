@description('Azure region for the deployment slot.')
param location string = resourceGroup().location

@description('Resource tags applied to the slot.')
param tags object = {}

@description('Name of the deployment slot.')
param name string

@description('Name of the parent App Service.')
param appServiceName string

@description('Resource id of the App Service Plan.')
param servicePlanId string

@description('Kind of App Service (e.g. app,linux).')
param kind string

@description('Linux runtime stack version (FX version).')
param linuxFxVersion string = ''

@description('.NET Framework version for Windows apps.')
param netFrameworkVersion string = ''

@description('Startup command line for the app.')
param appCommandLine string = ''

@description('Keep the slot always loaded.')
param alwaysOn bool = false

@description('Application settings for the slot.')
param appSettings array = []

@description('Managed identity type for the slot.')
param identityType string = 'SystemAssigned'

@description('FTPS deployment state for the slot.')
param ftpsState string = 'Disabled'

@description('Run the worker process in 32-bit mode.')
param use32BitWorkerProcess bool = false

@description('Function app scale-out limit (0 = unbounded).')
param functionAppScaleLimit int = 0

@description('Build the app during deployment.')
param buildOnDeployment string = 'true'

@description('Run the app directly from the deployment package.')
param runFromPackage string = '0'

@description('Require HTTPS for all traffic.')
param httpsOnly bool = true

@description('Enable client-affinity (sticky-session) cookies.')
param clientAffinityEnabled bool = false

@description('Require a client certificate for inbound requests.')
param clientCertEnabled bool = false

@description('Client-certificate negotiation mode.')
param clientCertMode string = 'Required'

@description('CORS allowed origins for the slot.')
param allowedOrigins array = ['https://portal.azure.com']

@description('Public network access setting for the slot.')
param publicNetworkAccess string = 'Enabled'

@description('Health-check probe path for the slot.')
param healthCheckPath string = ''

@description('Application Insights connection string for slot telemetry.')
param appInsightsConnectionString string = ''

resource app 'Microsoft.Web/sites@2024-04-01' existing = {
  name: appServiceName
}

resource appSlot 'Microsoft.Web/sites/slots@2024-04-01' = {
  parent: app
  name: name
  location: location
  tags: tags
  kind: kind
  identity: {
    type: identityType
  }
  properties: {
    serverFarmId: servicePlanId
    siteConfig: {
      linuxFxVersion: linuxFxVersion
      appCommandLine: appCommandLine
      ftpsState: ftpsState
      alwaysOn: alwaysOn
      healthCheckPath: healthCheckPath
      use32BitWorkerProcess: use32BitWorkerProcess
      netFrameworkVersion: netFrameworkVersion
      functionAppScaleLimit: functionAppScaleLimit
      cors: { allowedOrigins: allowedOrigins }
      appSettings: union(appSettings, [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsightsConnectionString
        }
        {
          name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: buildOnDeployment
        }
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: runFromPackage
        }
      ])
    }
    httpsOnly: httpsOnly
    clientAffinityEnabled: clientAffinityEnabled
    clientCertEnabled: clientCertEnabled
    clientCertMode: clientCertMode
    publicNetworkAccess: publicNetworkAccess
  }
}

output id string = appSlot.id
output name string = appSlot.name
output defaultHostName string = 'https://${appSlot.properties.defaultHostName}/'
