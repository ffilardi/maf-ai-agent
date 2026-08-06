// Azure Monitor Workbook — token showback from the gateway's `llm-emit-token-metric` (dimensioned by "API ID")
// plus the backend's own telemetry: the `agent.tokens.*` counters and the "Token usage audit" trace
// (`TokenUsageTelemetry.cs`) — chat turns only, but the trace carries the sessionId, which is what makes the
// per-conversation views possible. Rendered as tokens-over-time / tokens-by-API / per-conversation / RAG-activity
// views (KQL over customMetrics/traces).
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
param displayName string = 'Token & Cost Insights'

// Gateway token metrics only: `contains` is case-insensitive in KQL, so "Token" would otherwise also match the
// backend's own `agent.tokens.*` counters and double-count them into the gateway tiles.
var gatewayTokens string = 'customMetrics | where name contains "Token" and name !startswith "agent."'

// The backend's own counters — the other side of the filter above. Chat turns only (no embedding traffic), but they
// carry the `model` and `streaming` dimensions and the cached/reasoning breakdown the gateway metric never emits.
var backendTokens string = 'customMetrics | where name startswith "agent."'

// The per-turn cost audit trace emitted by TokenUsageTelemetry; its structured properties land in customDimensions.
var tokenAudit string = 'traces | where message has "Token usage audit" | extend sessionId = tostring(customDimensions["SessionId"]), model = tostring(customDimensions["Model"]), prompt = tolong(tostring(customDimensions["PromptTokens"])), completion = tolong(tostring(customDimensions["CompletionTokens"])), cached = tolong(tostring(customDimensions["CachedTokens"]))'

var workbookContent = {
  version: version
  isLocked: isLocked
  items: [
    {
      type: 1
      content: {
        json: '## Token & Cost Insights\nToken consumption and RAG activity for showback/chargeback. Gateway tiles come from the APIM `llm-emit-token-metric` policy (dimensioned by API ID) and cover **every** LLM call, embeddings included; the per-model tile comes from the backend\'s `agent.tokens.*` counters and the per-conversation tiles from its "Token usage audit" trace — both chat turns only, so they read lower than the gateway totals by roughly the embedding spend. RAG retrievals come from the retrieval audit trace. Use the time range to scope, and multiply tokens by your model\'s per-token price for a cost estimate.'
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
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '${gatewayTokens} | summarize Tokens = sum(valueSum) by bin(timestamp, 1h) | order by timestamp asc'
        size: 0
        title: 'Total tokens over time'
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
        query: '${gatewayTokens} | extend api = tostring(customDimensions["API ID"]) | summarize Tokens = sum(valueSum) by api | order by Tokens desc'
        size: 0
        title: 'Tokens by API'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.insights/components'
        visualization: 'barchart'
      }
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '${gatewayTokens} | summarize Tokens = sum(valueSum) by name, bin(timestamp, 1h) | order by timestamp asc'
        size: 0
        title: 'Prompt vs completion vs total tokens'
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
        query: '${backendTokens} | extend model = tostring(customDimensions["model"]) | summarize Prompt = sumif(valueSum, name == "agent.tokens.prompt"), Cached = sumif(valueSum, name == "agent.tokens.cached"), Completion = sumif(valueSum, name == "agent.tokens.completion"), Reasoning = sumif(valueSum, name == "agent.tokens.reasoning"), Turns = sumif(valueSum, name == "agent.turns") by model | extend Tokens = Prompt + Completion, ["Cached % of prompt"] = round(100.0 * Cached / iff(Prompt == 0, 1.0, Prompt), 1), ["Reasoning % of completion"] = round(100.0 * Reasoning / iff(Completion == 0, 1.0, Completion), 1), ["Tokens per turn"] = round((Prompt + Completion) / iff(Turns == 0, 1.0, Turns)) | order by Tokens desc'
        size: 0
        title: 'Chat tokens by model — cached and reasoning split'
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
        query: '${tokenAudit} | summarize Turns = count(), PromptTokens = sum(prompt), CachedTokens = sum(cached), CompletionTokens = sum(completion), Tokens = sum(prompt + completion), Models = make_set(model) by sessionId | top 20 by Tokens desc'
        size: 0
        title: 'Heaviest conversations (top 20, by tokens)'
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
        query: '${tokenAudit} | summarize Conversations = dcount(sessionId), Turns = count(), Tokens = sum(prompt + completion) | extend ["Tokens per conversation"] = iff(Conversations == 0, 0.0, todouble(Tokens) / Conversations), ["Tokens per turn"] = iff(Turns == 0, 0.0, todouble(Tokens) / Turns)'
        size: 0
        title: 'Unit economics — tokens per conversation and per turn'
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
        query: 'traces | where message has "RAG retrieval audit" | summarize Retrievals = count() by bin(timestamp, 1h) | order by timestamp asc'
        size: 0
        title: 'RAG retrievals over time'
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.insights/components'
        visualization: 'timechart'
      }
    }
  ]
}

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(appInsightsId, '-workbook')
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
