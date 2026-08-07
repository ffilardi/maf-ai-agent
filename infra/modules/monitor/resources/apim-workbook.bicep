// Azure Monitor Workbook — API-administrator view of the APIM "AI Gateway": per-API / per-operation success and
// failure counts, throughput, response-time percentiles (with the gateway-overhead vs. backend split), error
// reasons, throttling, caller consumption and load-balancer distribution.
@description('Azure region for the workbook.')
param location string = resourceGroup().location

@description('Resource tags applied to the workbook.')
param tags object = {}

@description('Name (GUID) of the workbook resource.')
param name string

@description('Resource id of the Log Analytics workspace holding the ApiManagementGatewayLogs table.')
param logAnalyticsWorkspaceId string

@description('Kind of workbook (e.g. shared).')
param kind string = 'shared'

@description('Category the workbook is grouped under in the gallery.')
param category string = 'workbook'

@description('Workbook schema version.')
param version string = 'Notebook/1.0'

@description('Lock the workbook against edits.')
param isLocked bool = false

@description('Display name shown for the workbook.')
param displayName string = 'API Gateway Operations'

var workspaceScope = [logAnalyticsWorkspaceId]
var workspaceType string = 'microsoft.operationalinsights/workspaces'

// Base fragment: honours the API filter pill, then projects friendly names. ApiId/OperationId arrive as resource paths.
var gatewayLogs string = 'ApiManagementGatewayLogs | where "*" in ({Api}) or ApiId in ({Api}) | extend Api = iff(isempty(ApiId), "(unknown)", extract(@"([^/]+)$", 1, ApiId)), Operation = iff(isempty(OperationId), "(unmatched)", extract(@"([^/]+)$", 1, OperationId))'

var workbookContent = {
  version: version
  isLocked: isLocked
  items: [
    {
      type: 1
      content: {
        json: '## API Gateway Operations\nHow the APIM "AI Gateway" is being consumed, from the dedicated `ApiManagementGatewayLogs` table: successful vs. unsuccessful calls per API and per operation, throughput, response times, error reasons, throttling, and per-caller consumption. **Total time** is the full gateway-observed latency; **backend time** is the upstream service (Azure AI Foundry / AI Search) — the difference is gateway overhead plus retries across load-balanced backends. Backend agent health lives in the **Agent Operations** workbook and token spend in **Token & Cost Insights**.'
      }
    }
    {
      type: 9
      content: {
        version: 'KqlParameterItem/1.0'
        style: 'pills'
        parameters: [
          {
            name: 'TimeRange'
            label: 'Time range'
            type: 4
            value: { durationMs: 604800000 }
            typeSettings: {
              selectableValues: [
                { durationMs: 3600000 }
                { durationMs: 86400000 }
                { durationMs: 604800000 }
                { durationMs: 2592000000 }
              ]
            }
          }
          {
            name: 'Api'
            label: 'API'
            type: 2
            multiSelect: true
            quote: '\''
            delimiter: ','
            value: ['*']
            query: 'ApiManagementGatewayLogs | summarize by ApiId | project Value = ApiId, Label = extract(@"([^/]+)$", 1, ApiId), Selected = false | union (print Value = "*", Label = "All APIs", Selected = true) | order by Label asc'
            crossComponentResources: workspaceScope
            timeContextFromParameter: 'TimeRange'
            queryType: 0
            resourceType: workspaceType
            typeSettings: { additionalResourceOptions: [], showDefault: false }
          }
        ]
      }
    }
    {
      type: 1
      content: { json: '### Traffic at a glance' }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '${gatewayLogs} | summarize Calls = count(), Succeeded = countif(IsRequestSuccess), Failed = countif(not(IsRequestSuccess)), APIs = dcount(ApiId), Operations = dcount(OperationId), Callers = dcount(ApimSubscriptionId), ["P50 ms"] = round(percentile(TotalTime, 50)), ["P95 ms"] = round(percentile(TotalTime, 95)) | extend ["Success %"] = round(100.0 * Succeeded / iff(Calls == 0, 1, Calls), 2)'
        size: 0
        title: 'Summary — calls, success rate, latency, unique callers'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: workspaceType
        crossComponentResources: workspaceScope
        visualization: 'table'
      }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '${gatewayLogs} | summarize Calls = count(), Failed = countif(not(IsRequestSuccess)) by bin(TimeGenerated, {TimeRange:grain}) | order by TimeGenerated asc'
        size: 0
        title: 'Calls and failures over time'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: workspaceType
        crossComponentResources: workspaceScope
        visualization: 'timechart'
      }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '${gatewayLogs} | summarize ["Success %"] = round(100.0 * countif(IsRequestSuccess) / count(), 2) by bin(TimeGenerated, {TimeRange:grain}) | order by TimeGenerated asc'
        size: 0
        title: 'Success rate over time (%)'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: workspaceType
        crossComponentResources: workspaceScope
        visualization: 'timechart'
      }
    }
    {
      type: 1
      content: { json: '### Per API and per endpoint' }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '${gatewayLogs} | summarize Calls = count(), Succeeded = countif(IsRequestSuccess), Failed = countif(not(IsRequestSuccess)), ["P50 ms"] = round(percentile(TotalTime, 50)), ["P95 ms"] = round(percentile(TotalTime, 95)), ["Avg backend ms"] = round(avg(BackendTime)) by Api | extend ["Failure %"] = round(100.0 * Failed / Calls, 2) | order by Calls desc'
        size: 0
        title: 'By API — successful vs. unsuccessful calls and latency'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: workspaceType
        crossComponentResources: workspaceScope
        visualization: 'table'
      }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '${gatewayLogs} | summarize Calls = count(), Succeeded = countif(IsRequestSuccess), Failed = countif(not(IsRequestSuccess)), ["P95 ms"] = round(percentile(TotalTime, 95)) by Api, Operation, Method | extend ["Failure %"] = round(100.0 * Failed / Calls, 2) | order by Calls desc | take 50'
        size: 0
        title: 'By endpoint — successful vs. unsuccessful calls per operation'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: workspaceType
        crossComponentResources: workspaceScope
        visualization: 'table'
      }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '${gatewayLogs} | summarize Calls = count() by Api, bin(TimeGenerated, {TimeRange:grain}) | order by TimeGenerated asc'
        size: 0
        title: 'Throughput by API over time'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: workspaceType
        crossComponentResources: workspaceScope
        visualization: 'timechart'
      }
    }
    {
      type: 1
      content: { json: '### Response times' }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '${gatewayLogs} | summarize P50 = round(percentile(TotalTime, 50)), P95 = round(percentile(TotalTime, 95)), P99 = round(percentile(TotalTime, 99)) by bin(TimeGenerated, {TimeRange:grain}) | order by TimeGenerated asc'
        size: 0
        title: 'Total response time (P50 / P95 / P99, ms)'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: workspaceType
        crossComponentResources: workspaceScope
        visualization: 'timechart'
      }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '${gatewayLogs} | summarize ["Backend ms"] = round(avg(BackendTime)), ["Gateway overhead ms"] = round(avg(TotalTime - BackendTime)), ["Client ms"] = round(avg(ClientTime)) by bin(TimeGenerated, {TimeRange:grain}) | order by TimeGenerated asc'
        size: 0
        title: 'Where the time goes — backend vs. gateway overhead vs. client'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: workspaceType
        crossComponentResources: workspaceScope
        visualization: 'timechart'
      }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '${gatewayLogs} | summarize Calls = count(), ["P95 total ms"] = round(percentile(TotalTime, 95)), ["P95 backend ms"] = round(percentile(BackendTime, 95)), ["Max ms"] = max(TotalTime) by Api, Operation | where Calls > 0 | order by ["P95 total ms"] desc | take 20'
        size: 0
        title: 'Slowest endpoints (P95)'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: workspaceType
        crossComponentResources: workspaceScope
        visualization: 'table'
      }
    }
    {
      type: 1
      content: { json: '### Errors and throttling' }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '${gatewayLogs} | summarize Calls = count() by Class = strcat(substring(tostring(ResponseCode), 0, 1), "xx"), bin(TimeGenerated, {TimeRange:grain}) | order by TimeGenerated asc'
        size: 0
        title: 'Response codes over time (by class)'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: workspaceType
        crossComponentResources: workspaceScope
        visualization: 'timechart'
      }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '${gatewayLogs} | where not(IsRequestSuccess) | summarize Failures = count() by Api, Operation, ResponseCode, BackendResponseCode | order by Failures desc | take 30'
        size: 0
        title: 'Unsuccessful calls by endpoint and status code'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: workspaceType
        crossComponentResources: workspaceScope
        visualization: 'table'
      }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '${gatewayLogs} | where isnotempty(LastErrorReason) | summarize Occurrences = count(), Sample = any(LastErrorMessage) by LastErrorSource, LastErrorReason, Api | order by Occurrences desc | take 30'
        size: 0
        title: 'Top gateway error reasons (policy vs. backend)'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: workspaceType
        crossComponentResources: workspaceScope
        visualization: 'table'
      }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '${gatewayLogs} | where ResponseCode == 429 or BackendResponseCode == 429 | summarize ["Gateway throttled (policy)"] = countif(ResponseCode == 429 and BackendResponseCode != 429), ["Backend throttled (TPM)"] = countif(BackendResponseCode == 429) by bin(TimeGenerated, {TimeRange:grain}) | order by TimeGenerated asc'
        size: 0
        title: 'Throttling — gateway rate/token limits vs. upstream 429s'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: workspaceType
        crossComponentResources: workspaceScope
        visualization: 'timechart'
      }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: 'AppRequests | extend Remaining = coalesce(tostring(Properties["Response-x-apim-ratelimit-remaining-tokens"]), tostring(Properties["x-apim-ratelimit-remaining-tokens"])) | where isnotempty(Remaining) | summarize ["Min remaining tokens"] = min(tolong(Remaining)) by bin(TimeGenerated, {TimeRange:grain}) | order by TimeGenerated asc'
        size: 0
        title: 'Token-limit headroom (Foundry API — populated by the logged x-apim-ratelimit-* headers)'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: workspaceType
        crossComponentResources: workspaceScope
        visualization: 'timechart'
      }
    }
    {
      type: 1
      content: { json: '### Consumption and backend distribution' }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '${gatewayLogs} | summarize Calls = count(), Failed = countif(not(IsRequestSuccess)), APIs = dcount(ApiId), ["P95 ms"] = round(percentile(TotalTime, 95)) by Subscription = iff(isempty(ApimSubscriptionId), "(none)", ApimSubscriptionId) | order by Calls desc | take 20'
        size: 0
        title: 'Consumption by caller (APIM subscription)'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: workspaceType
        crossComponentResources: workspaceScope
        visualization: 'table'
      }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '${gatewayLogs} | where isnotempty(BackendUrl) | summarize Calls = count(), Failed = countif(not(IsRequestSuccess)), ["P95 backend ms"] = round(percentile(BackendTime, 95)) by BackendUrl | order by Calls desc'
        size: 0
        title: 'Load-balancer distribution by backend'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: workspaceType
        crossComponentResources: workspaceScope
        visualization: 'barchart'
      }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '${gatewayLogs} | summarize ["Request MB"] = round(sum(RequestSize) / 1048576.0, 2), ["Response MB"] = round(sum(ResponseSize) / 1048576.0, 2), ["Cache hits"] = countif(Cache == "hit"), Calls = count() by Api | order by ["Response MB"] desc'
        size: 0
        title: 'Bandwidth and cache effectiveness by API'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: workspaceType
        crossComponentResources: workspaceScope
        visualization: 'table'
      }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '${gatewayLogs} | where not(IsRequestSuccess) | project TimeGenerated, Api, Operation, Method, Url, ResponseCode, BackendResponseCode, TotalTime, LastErrorReason, LastErrorMessage, CorrelationId | order by TimeGenerated desc | take 50'
        size: 0
        title: 'Recent failed calls (drill-down — CorrelationId ties back to App Insights)'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: workspaceType
        crossComponentResources: workspaceScope
        visualization: 'table'
      }
    }
  ]
}

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(logAnalyticsWorkspaceId, '-apim-workbook')
  location: location
  kind: kind
  tags: union(tags, { 'azd-service-name': name })
  properties: {
    displayName: displayName
    serializedData: string(workbookContent)
    category: category
    sourceId: logAnalyticsWorkspaceId
    version: version
  }
}

output id string = workbook.id
output name string = workbook.name
