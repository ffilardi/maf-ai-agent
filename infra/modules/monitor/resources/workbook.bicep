// Azure Monitor Workbook — token showback from the gateway's `llm-emit-token-metric` (dimensioned by "API ID")
// plus the backend's RAG audit trace, as tokens-over-time / tokens-by-API / RAG-activity views (KQL over customMetrics/traces).
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

var workbookContent = {
  version: version
  isLocked: isLocked
  items: [
    {
      type: 1
      content: {
        json: '## Token & Cost Insights\nToken consumption and RAG activity for showback/chargeback. Tokens come from the APIM `llm-emit-token-metric` policy (dimensioned by API ID); RAG retrievals from the backend audit trace. Use the time range to scope. Multiply tokens by your model\'s per-token price for a cost estimate.'
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
        query: 'customMetrics | where name contains "Token" | summarize Tokens = sum(valueSum) by bin(timestamp, 1h) | order by timestamp asc'
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
        query: 'customMetrics | where name contains "Token" | extend api = tostring(customDimensions["API ID"]) | summarize Tokens = sum(valueSum) by api | order by Tokens desc'
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
        query: 'customMetrics | where name contains "Token" | summarize Tokens = sum(valueSum) by name, bin(timestamp, 1h) | order by timestamp asc'
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
