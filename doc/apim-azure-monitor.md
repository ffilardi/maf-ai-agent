# Azure Monitor Diagnostics for API Management

## Overview

The API Management gateway emits telemetry to two Azure Monitor destinations, both provisioned by Bicep:

| Destination | Scope | Provisioned in | Documented in |
|---|---|---|---|
| **Application Insights** | Per imported API (`ai-foundry-api`, `ai-document-intelligence-api`, `ai-content-safety-api`, `ai-search-api`) | [`infra/modules/apim/resources/api.bicep`](../infra/modules/apim/resources/api.bicep) | [`apim-app-insights.md`](apim-app-insights.md) |
| **Log Analytics** | The APIM service as a whole | [`infra/modules/apim/resources/service.bicep`](../infra/modules/apim/resources/service.bicep) | This page |

Application Insights carries the per-request diagnostics (sampling, headers, payload bytes, client IP).
Log Analytics carries the platform-level resource logs and metrics. They are independent: turning one off
does not affect the other.

## Service-level diagnostic settings

[`infra/modules/apim/resources/service.bicep`](../infra/modules/apim/resources/service.bicep) creates a
`Microsoft.Insights/diagnosticsettings` resource named `Logging`, scoped to the APIM service:

```bicep
resource diagnosticSettings 'Microsoft.Insights/diagnosticsettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
  name: 'Logging'
  scope: apimService
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: enableVerboseLogs
      ? [
          { category: null, categoryGroup: 'allLogs', enabled: enableLogs }
          { category: null, categoryGroup: 'audit', enabled: enableAuditLogs }
        ]
      : []
    metrics: [
      { category: 'AllMetrics', enabled: enableMetrics }
    ]
  }
}
```

`logAnalyticsDestinationType: 'Dedicated'` routes logs into resource-specific tables
(`ApiManagementGatewayLogs`) rather than the shared `AzureDiagnostics` table.

The whole resource is conditional on `logAnalyticsWorkspaceId` — the workspace id flows
[`infra/main.bicep`](../infra/main.bicep) (`monitor.outputs.logAnalyticsWorkspaceId`) →
[`infra/modules/apim/apim.bicep`](../infra/modules/apim/apim.bicep) → `resources/service.bicep`. If the
monitor module is not deployed, no diagnostic setting is created and APIM emits nothing to Log Analytics.

### Parameters

| Parameter | Default | Effect |
|---|---|---|
| `enableVerboseLogs` | `true` | Master switch for the `logs` array. When `false` the array is empty and **only metrics** reach Log Analytics |
| `enableLogs` | `true` | Enables the `allLogs` category group — only takes effect when `enableVerboseLogs` is `true` |
| `enableAuditLogs` | `false` | Enables the `audit` category group — only takes effect when `enableVerboseLogs` is `true` |
| `enableMetrics` | `true` | Enables the `AllMetrics` category. Not gated by `enableVerboseLogs` |

> [!IMPORTANT]
> `enableVerboseLogs` is a top-level parameter in [`infra/main.bicep`](../infra/main.bicep), default
> **`true`**, threaded to every resource that has diagnostic settings — APIM, the Foundry account, App
> Service, Cosmos DB and AI Search. It is one switch for the whole deployment, so turning it off for APIM
> turns off verbose logs everywhere. Platform logs are the expensive half of Log Analytics ingestion and
> the workspace ships with a **1 GB/day cap**
> ([`loganalytics.bicep`](../infra/modules/monitor/resources/loganalytics.bicep), `dailyQuotaGb`), so a
> busy environment can hit the cap and stop ingesting for the rest of the day. Set the parameter to
> `false` in [`infra/main.parameters.json`](../infra/main.parameters.json), or raise the cap — see
> [`finops.md`](finops.md).

Per-request diagnostics do **not** depend on this switch: the Application Insights API diagnostics in
[`apim-app-insights.md`](apim-app-insights.md) are always on whenever an App Insights logger exists.

## Token metrics from the gateway policy

Token accounting is emitted by policy rather than by diagnostic settings.
[`infra/modules/apim/policies/foundry-api-policy.xml`](../infra/modules/apim/policies/foundry-api-policy.xml)
runs:

```xml
<llm-emit-token-metric>
    <dimension name="API ID" />
</llm-emit-token-metric>
```

which publishes prompt / completion / total token custom metrics against the APIM Application Insights
logger, dimensioned by API id.

The same policy's `llm-token-limit` returns the gateway's rate-limit accounting as response headers
(`x-apim-ratelimit-consumed-tokens`, `x-apim-ratelimit-remaining-tokens`,
`x-apim-ratelimit-remaining-quota-tokens`). Those header names — plus the upstream `x-ratelimit-*` and
`x-ms-deployment-name` headers — are passed as `additionalHeadersToLog` when
[`infra/modules/apim/apim.bicep`](../infra/modules/apim/apim.bicep) deploys the AI Foundry API, so they
are captured in the Application Insights request diagnostics.

## Not configured

- **API-level `azuremonitor` diagnostics.** There is no
  `Microsoft.ApiManagement/service/apis/diagnostics` resource named `azuremonitor` in
  [`infra/modules/apim/resources/api.bicep`](../infra/modules/apim/resources/api.bicep) — only the
  `applicationinsights` one.
- **LLM prompt/completion message logging.** Capturing the model request and response bodies at the
  gateway requires that `azuremonitor` diagnostic with a `largeLanguageModel` block. Without it the
  gateway records token counts and metadata, not message content. The backend's own retrieval and
  token telemetry is described in [`logging.md`](logging.md).

## Verifying

Gateway requests are queryable in Log Analytics (this is what `enableVerboseLogs` turns on):

```kusto
ApiManagementGatewayLogs
| where TimeGenerated > ago(1h)
| summarize count(), avg(TotalTime) by ApiId, BackendResponseCode
| order by count_ desc
```

Platform metrics are unaffected by `enableVerboseLogs` and are always available:

```kusto
AzureMetrics
| where ResourceProvider == "MICROSOFT.APIMANAGEMENT"
| where TimeGenerated > ago(1h)
| summarize avg(Average) by MetricName, bin(TimeGenerated, 5m)
```

The **Agent Operations** workbook
([`infra/modules/monitor/resources/ops-workbook.bicep`](../infra/modules/monitor/resources/ops-workbook.bicep))
is the visual layer over this telemetry — see [`logging.md`](logging.md).
