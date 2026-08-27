// Azure Monitor Workbook — operational health for the backend agent, driven by KQL over the app's telemetry
// (request health, per-backend dependencies, RAG audit trail, Content Safety screening, persist failures, MAF GenAI spans). Cost/token showback lives in workbook.bicep.
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

// The Content Safety screening counter (ContentSafetyService), split by stage: `turn` is the per-message pre-check
// (which can block), `document` is detective-only prompt-injection screening of an upload. `failopen` means screening
// errored and the content was allowed through unscreened — for turns in block mode that is blocking silently disabled.
var safetyOutcomes string = 'customMetrics | where name == "agent.contentsafety.evaluations" | extend Stage = tostring(customDimensions.stage), Outcome = tostring(customDimensions.outcome) | summarize Screenings = sum(valueSum) by bin(timestamp, 15m), Series = strcat(Stage, "/", Outcome) | render timechart'

// Two numbers for a metric alert to mirror: fail-open share of turn screenings and of document screenings.
var safetyFailOpenRate string = 'customMetrics | where name == "agent.contentsafety.evaluations" | extend Stage = tostring(customDimensions.stage), Outcome = tostring(customDimensions.outcome) | summarize Screenings = sum(valueSum) by Stage, Outcome | summarize Total = sum(Screenings), FailOpen = sumif(Screenings, Outcome == "failopen") by Stage | where Total > 0 | project Metric = strcat("Fail-open ", Stage, "s"), FailOpen, Percent = round(100.0 * FailOpen / Total, 1)'

// Per-passage review queue. Screening is detective only: every flagged chunk is indexed anyway, so this table is the
// place a human confirms or dismisses a hit. DocumentId is the search key, so a confirmed hit can be traced to the
// exact indexed chunk; delete the whole attachment (DELETE /files/{fileId}) to remove it.
var documentDetections string = 'traces | where message startswith "Prompt-injection screening flagged" | project timestamp, FileName = tostring(customDimensions.FileName), FileId = tostring(customDimensions.FileId), SessionId = tostring(customDimensions.SessionId), Chunk = tostring(customDimensions.ChunkIndex), Chunks = tostring(customDimensions.ChunkCount), Chars = tostring(customDimensions.ChunkChars), DocumentId = tostring(customDimensions.DocumentId) | order by timestamp desc | take 50'

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
        query: safetyOutcomes
        size: 0
        title: 'Content Safety screenings by stage/outcome (fail-open = screening was skipped, not clean)'
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
        query: safetyFailOpenRate
        size: 4
        title: 'Fail-open rate (% reaching the model unscreened)'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.insights/components'
        visualization: 'tiles'
      }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: documentDetections
        size: 0
        title: 'Flagged passages for review (indirect prompt injection — indexed, not blocked)'
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
