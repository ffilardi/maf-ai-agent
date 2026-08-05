// Azure Monitor Workbook — operational health for the backend agent, driven by KQL over the app's telemetry
// (request health, per-backend dependencies, RAG audit trail, Content Safety detections, persist failures, MAF GenAI spans). Cost/token showback lives in workbook.bicep.
@description('Azure region for the workbook.')
param location string = resourceGroup().location

@description('Resource tags applied to the workbook.')
param tags object = {}

@description('Name (GUID) of the workbook resource.')
param name string

@description('Resource id of the Application Insights component the workbook queries.')
param appInsightsId string

@description('Kind of workbook (e.g. shared).')
param kind string = 'shared'

@description('Category the workbook is grouped under in the gallery.')
param category string = 'workbook'

@description('Workbook schema version.')
param version string = 'Notebook/1.0'

@description('Lock the workbook against edits.')
param isLocked bool = false

@description('Display name shown for the workbook.')
param displayName string = 'Agent Operations'

var workbookContent = {
  version: version
  isLocked: isLocked
  items: [
    {
      type: 1
      content: {
        json: '## Agent Operations\nBackend health for the MAF agent, driven by the telemetry documented in `doc/logging.md`: request health, per-backend dependencies (APIM / Cosmos / AI Search), the RAG retrieval audit trail, Content Safety, and end-of-turn persist failures. Use the time range to scope. Token / cost showback lives in the **Token & Cost Insights** workbook.'
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
        ]
      }
    }
    {
      type: 1
      content: { json: '### Request health' }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: 'requests | summarize Total = count(), Failed = countif(success == false) by bin(timestamp, 1h) | order by timestamp asc'
        size: 0
        title: 'Requests and failures over time'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.insights/components'
        visualization: 'timechart'
      }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: 'requests | summarize P50 = percentile(duration, 50), P95 = percentile(duration, 95) by bin(timestamp, 1h) | order by timestamp asc'
        size: 0
        title: 'Server response time (P50 / P95, ms)'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.insights/components'
        visualization: 'timechart'
      }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: 'requests | summarize Calls = count(), Failed = countif(success == false), P95 = percentile(duration, 95) by name | extend FailPct = round(100.0 * Failed / Calls, 1) | order by Calls desc'
        size: 0
        title: 'By route'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.insights/components'
        visualization: 'table'
      }
    }
    {
      type: 1
      content: { json: '### Dependencies (APIM gateway, Cosmos, AI Search)' }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: 'dependencies | summarize Calls = count(), Failures = countif(success == false), P95 = percentile(duration, 95) by type, target | order by P95 desc'
        size: 0
        title: 'Dependency latency and failures by target'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.insights/components'
        visualization: 'table'
      }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: 'dependencies | where success == false | summarize Failures = count() by target, bin(timestamp, 1h) | order by timestamp asc'
        size: 0
        title: 'Dependency failures over time'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.insights/components'
        visualization: 'timechart'
      }
    }
    {
      type: 1
      content: { json: '### RAG retrieval audit' }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: 'traces | where message startswith "RAG retrieval audit" | extend hits = toint(customDimensions.HitCount) | summarize Retrievals = count(), Chunks = sum(hits) by bin(timestamp, 1h) | order by timestamp asc'
        size: 0
        title: 'Retrievals and grounded chunks over time'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.insights/components'
        visualization: 'timechart'
      }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: 'traces | where message startswith "RAG retrieval audit" | extend chunk = parse_json(tostring(customDimensions.Manifest)) | mv-expand chunk | summarize Hits = count(), AvgScore = round(avg(todouble(chunk.Score)), 3) by Source = tostring(chunk.Source) | order by Hits desc | take 20'
        size: 0
        title: 'Top grounding sources (by chunk hits, avg reranker score)'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.insights/components'
        visualization: 'table'
      }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: 'traces | where message startswith "RAG retrieval audit" | where customDimensions.HitCount == 0 | project timestamp, sessionId = tostring(customDimensions.SessionId), query = tostring(customDimensions.Query) | order by timestamp desc | take 50'
        size: 0
        title: 'Ungrounded turns (zero-hit retrievals)'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.insights/components'
        visualization: 'table'
      }
    }
    {
      type: 1
      content: { json: '### Content Safety and reliability' }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: 'traces | where message startswith "Content safety flagged" | summarize Detections = count() by Categories = tostring(customDimensions.Categories), Mode = tostring(customDimensions.Mode), PromptAttack = tostring(customDimensions.Attack) | order by Detections desc'
        size: 0
        title: 'Content Safety detections (tune before flipping mode to block)'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.insights/components'
        visualization: 'table'
      }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: 'traces | where message startswith "Model responded but history persist failed" | project timestamp, sessionId = tostring(customDimensions.SessionId), message | order by timestamp desc | take 50'
        size: 0
        title: 'Answered but not saved (Cosmos persist failures)'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.insights/components'
        visualization: 'table'
      }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: 'exceptions | summarize Count = count() by problemId, type | order by Count desc | take 20'
        size: 0
        title: 'Top server exceptions'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.insights/components'
        visualization: 'table'
      }
    }
    {
      type: 1
      content: { json: '### GenAI agent spans (LLM calls and tool invocations)' }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: 'dependencies | where target has "AgentBackend.Agent" or name has_any ("chat", "tool", "invoke_agent", "execute_tool") | summarize Calls = count(), Failures = countif(success == false), P95 = percentile(duration, 95) by name | order by Calls desc'
        size: 0
        title: 'LLM and tool operations'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.insights/components'
        visualization: 'table'
      }
    }
  ]
}

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(appInsightsId, '-ops-workbook')
  location: location
  kind: kind
  tags: union(tags, { 'azd-service-name': name })
  properties: {
    displayName: displayName
    serializedData: string(workbookContent)
    category: category
    sourceId: appInsightsId
    version: version
  }
}

output id string = workbook.id
output name string = workbook.name
