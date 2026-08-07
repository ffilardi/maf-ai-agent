@description('Azure region for the App Service.')
param location string = resourceGroup().location

@description('Resource tags applied to the App Service.')
param tags object = {}

@description('Name of the App Service.')
param name string

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

@description('Keep the app always loaded.')
param alwaysOn bool = true

@description('Application settings for the app.')
param appSettings array = []

@description('Application Insights connection string for app telemetry.')
param appInsightsConnectionString string = ''

@description('Managed identity type for the app.')
param identityType string = 'SystemAssigned'

@description('FTPS deployment state for the app.')
param ftpsState string = 'Disabled'

@description('Run the worker process in 32-bit mode.')
param use32BitWorkerProcess bool = false

@description('Function app scale-out limit (0 = unbounded).')
param functionAppScaleLimit int = 0

@description('CORS allowed origins for the app.')
param allowedOrigins array = ['https://portal.azure.com']

@description('Allow FTP-based publishing.')
param allowFtpPublishing bool = false

@description('Allow SCM (Kudu) basic-auth publishing.')
param allowScmPublishing bool = true

@description('Build the app during deployment.')
param buildOnDeployment string = 'false'

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

@description('Public network access setting for the app.')
param publicNetworkAccess string = 'Enabled'

@description('Health-check probe path for the app.')
param healthCheckPath string = ''

@description('Minimum severity level for file-system application logs.')
param fileSystemLogLevel string = 'Error'

@description('Include detailed error messages in file-system logs.')
param fileSystemDetailedErrorMessages bool = true

@description('Enable failed-request tracing to the file system.')
param fileSystemFailedRequestsTracing bool = false

@description('Enable HTTP request logging to the file system.')
param fileSystemHttpLogsEnabled bool = true

@description('Retention period in days for file-system HTTP logs.')
param fileSystemRetentionInDays int = 7

@description('Retention size cap in MB for file-system HTTP logs.')
param fileSystemRetentionInMb int = 35

@description('Resource id of the Log Analytics workspace for diagnostic logs.')
param logAnalyticsWorkspaceId string = ''

@description('Emit resource logs to Log Analytics.')
param enableLogs bool = true

@description('Emit platform metrics to Log Analytics.')
param enableMetrics bool = true

@description('Emit audit-category logs to Log Analytics.')
param enableAuditLogs bool = false

@description('Ship verbose platform logs to Log Analytics.')
param enableVerboseLogs bool = false

resource app 'Microsoft.Web/sites@2024-04-01' = {
  location: location
  tags: tags
  name: name
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

  resource logs 'config' = {
    name: 'logs'
    properties: {
      applicationLogs: {
        fileSystem: {
          level: fileSystemLogLevel
        }
      }
      detailedErrorMessages: {
        enabled: fileSystemDetailedErrorMessages
      }
      failedRequestsTracing: {
        enabled: fileSystemFailedRequestsTracing
      }
      httpLogs: {
        fileSystem: {
          enabled: fileSystemHttpLogsEnabled
          retentionInDays: fileSystemRetentionInDays
          retentionInMb: fileSystemRetentionInMb
        }
      }
    }
  }
}

resource ftpBasicPublishingCred 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: app
  name: 'ftp'
  properties: {
    allow: allowFtpPublishing
  }
}

resource scmBasicPublishingCred 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: app
  name: 'scm'
  properties: {
    allow: allowScmPublishing
  }
}

resource diagnosticSettings 'Microsoft.Insights/diagnosticsettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
  name: 'Logging'
  scope: app
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: enableVerboseLogs
      ? [
          {
            category: null
            categoryGroup: 'allLogs'
            enabled: enableLogs
          }
          {
            category: null
            categoryGroup: 'audit'
            enabled: enableAuditLogs
          }
        ]
      : []
    metrics: [
      {
        category: 'AllMetrics'
        enabled: enableMetrics
      }
    ]
  }
}

output id string = app.id
output name string = app.name
output defaultHostName string = 'https://${app.properties.defaultHostName}'
output principalId string = app.identity.principalId

// Feeds the APIM gateway allow-list; it changes if the plan tier changes or the app is migrated.
output outboundIpAddresses string = app.properties.possibleOutboundIpAddresses
