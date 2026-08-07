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

> [!NOTE]
> `ApiManagementGatewayLogs` records **every** request the gateway receives, including the opportunistic
> internet scanning any public endpoint attracts — probes for `/.env`, `/wp-admin` and similar. Those are
> rejected with `404` (no matching API) or `401` (no subscription key) before any policy runs, so they are
> a log-ingestion cost rather than an exposure, and no APIM policy can suppress them. This switch is the
> blunt lever; the surgical one is a workspace transformation DCR dropping rows with no matched `ApiId`.
> Gateway hardening is covered in [`apim-policies.md`](apim-policies.md) › *Service-Scope Policy*.
>
> ```kusto
> ApiManagementGatewayLogs
> | where TimeGenerated > ago(24h) and ResponseCode in (401, 404)
> | summarize Requests = count() by Url, CallerIpAddress
> | order by Requests desc
> ```

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

## The API Gateway Operations workbook

[`infra/modules/monitor/resources/apim-workbook.bicep`](../infra/modules/monitor/resources/apim-workbook.bicep)
deploys the admin-facing view of the gateway itself — always deployed, wired from
[`main.bicep`](../infra/main.bicep)'s `apimWorkbookName`. Open it under the **Log Analytics workspace →
Workbooks** (or from the `rg-monitor-<env>-<token>` resource-group listing) — not Application Insights,
where the other two live.

That asymmetry is deliberate: `ApiManagementGatewayLogs` is the only sink carrying `ApiId` /
`OperationId`, `IsRequestSuccess`, the `TotalTime` / `BackendTime` / `ClientTime` split and the
`LastError*` fields, and App Insights request rows from the gateway co-mingle there with the backend
agent's own. Because App Insights is workspace-based, one tile can still reach `AppRequests` for the
rate-limit headers.

> Listing it in the App Insights gallery instead (`sourceId: appInsightsId`) looks tempting for
> discoverability, but don't: the tiles would then load in a resource context that has no workspace, and
> the workbook renders empty. Each tile's `crossComponentResources` therefore pins the workspace **by
> resource id**, not through a `{Workspace}` resource-picker parameter — a type-5 picker populates its
> dropdown from that same ambient context and resolves to null anywhere but the workspace blade.

Two pills scope every tile: **time range** (1 h / 1 d / 7 d / 30 d, default 7 d) and a multi-select
**API** filter populated from the `ApiId` values actually seen in the window (defaults to all four
gateway APIs). Sections:

| Section | Tiles |
| ------- | ----- |
| Traffic at a glance | Summary KPIs (calls, succeeded/failed, success %, P50/P95, unique APIs, operations and callers); calls-and-failures over time; success rate over time |
| Per API and per endpoint | Successful vs. unsuccessful calls, failure % and latency **by API**, then **by operation** (`OperationId` + method) — the per-endpoint answer; throughput by API over time |
| Response times | Total time P50/P95/P99; the backend vs. **gateway overhead** (`TotalTime - BackendTime`) vs. client split; slowest endpoints by P95 |
| Errors and throttling | Response codes by class over time; unsuccessful calls by endpoint and status code; top `LastErrorSource` / `LastErrorReason` (policy failures vs. backend); **429s split into gateway-enforced (rate/token-limit policy) vs. upstream Azure OpenAI TPM**; token-limit headroom from the logged `x-apim-ratelimit-remaining-tokens` header |
| Consumption and backend distribution | Calls per caller (`ApimSubscriptionId`); load-balancer distribution by `BackendUrl`; bandwidth and cache hits by API; a recent-failures drill-down list carrying `CorrelationId` for the jump back into App Insights |

Because the whole workbook reads `ApiManagementGatewayLogs`, it goes blank if `enableVerboseLogs` is set
to `false` (see the parameter above) — platform metrics survive, but the per-operation detail does not.
