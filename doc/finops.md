# FinOps — Cost Visibility, Guardrails & Right-Sizing

## Overview

This document catalogs the **FinOps** controls built into the infrastructure: how spend is made
*visible*, how it is *guarded* against surprises, and the *levers* that let each deployment right-size
to its own scale. It is the cost counterpart to the observability docs ([`logging.md`](logging.md),
[`apim-app-insights.md`](apim-app-insights.md), [`apim-azure-monitor.md`](apim-azure-monitor.md)).

Design philosophy — this repo is a **reusable template/demo**, so every control ships with a **cheap,
zero-config default** that keeps `azd up` working with no extra input, and is **parameterized** so an
adopter can dial it up (or down) per environment. Nothing here adds production resilience/redundancy;
the focus is cost governance.

Most knobs live as **module-level Bicep params with defaults**, tuned by editing the owning module.
Only a few are surfaced at the top level in [`infra/main.bicep`](../infra/main.bicep) (`enableVerboseLogs`, `owner`,
`application`, `costCenter`). None are currently wired to `azd` environment variables —
[`infra/main.parameters.json`](../infra/main.parameters.json) passes only `environment` and `location` — so overrides are made by editing
the Bicep defaults or passing `--parameters` to a manual `az deployment`.

## Control summary

| FinOps capability | Control | Where | Default |
| --- | --- | --- | --- |
| Cost allocation | Resource tags (`owner`/`application`/`cost-center`/`environment`/`managed-by`) | [`infra/main.bicep`](../infra/main.bicep) `var tags` | `unassigned` / `maf-ai-agent` / `unassigned` |
| Cost visibility | Token & cost showback workbook | [`modules/monitor/resources/workbook.bicep`](../infra/modules/monitor/resources/workbook.bicep) | always deployed |
| Spend guardrail | Log Analytics daily ingestion cap | [`modules/monitor/resources/loganalytics.bicep`](../infra/modules/monitor/resources/loganalytics.bicep) | `dailyQuotaGb = 1` |
| Spend guardrail | App Insights telemetry sampling | [`modules/monitor/resources/appinsights.bicep`](../infra/modules/monitor/resources/appinsights.bicep) | `samplingPercentage = 100` |
| Cost optimization | Scoped platform-log ingestion | `enableVerboseLogs` (main → APIM/Cosmos/Foundry/Search/App Service) | `true` (full logs); set `false` for metrics-only |
| Right-sizing | Backend App Service Plan SKU | [`modules/app/app.bicep`](../infra/modules/app/app.bicep) | `Basic` / `B1` |
| Right-sizing | Azure AI Search SKU | [`modules/search/search.bicep`](../infra/modules/search/search.bicep) | `free` (hybrid + semantic ranking) |
| Right-sizing | Foundry model TPM capacity | [`modules/foundry/foundry.bicep`](../infra/modules/foundry/foundry.bicep) | chat `1000`, embedding `150` |
| Right-sizing | Cosmos serverless vs provisioned | [`modules/cosmosdb/resources/account.bicep`](../infra/modules/cosmosdb/resources/account.bicep) | `useServerless = false` |
| Data lifecycle | Storage blob age-out policy | [`modules/storage/resources/account.bicep`](../infra/modules/storage/resources/account.bicep) | delete after `90` days |
| Data lifecycle | Conversation transcript TTL | `MAX_HISTORY_TTL_DAYS` (backend) | `0` = never expire |
| Token governance | APIM `llm-token-limit` / quotas + in-context compaction | [`apim/policies/foundry-api-policy.xml`](../infra/modules/apim/policies/foundry-api-policy.xml), backend | *pre-existing — see below* |

---

## 1. Cost visibility & allocation — tags & showback workbook

Every resource is tagged for cost slicing. [`infra/main.bicep`](../infra/main.bicep) builds one `tags` object and each module
merges its own `azd-service-name` on top via `union(tags, …)`, so a tag added at the root propagates
everywhere:

```bicep
var tags object = {
  'azd-env-name': environment   // required by azd for environment tracking
  environment: environment
  owner: owner                  // param, default 'unassigned'
  application: application       // param, default 'maf-ai-agent'
  'cost-center': costCenter      // param, default 'unassigned'
  'managed-by': 'bicep'
}
```

These become cost-allocation dimensions in **Azure Cost Management** (group/filter by tag) and enable
showback/chargeback. Set real values by editing the param defaults in [`main.bicep`](../infra/main.bicep) or passing
`owner=…`, `application=…`, `costCenter=…` at deploy time.

### Token & cost showback workbook

[`modules/monitor/resources/workbook.bicep`](../infra/modules/monitor/resources/workbook.bicep) deploys an Azure Monitor **workbook** ("Token & Cost
Insights") over telemetry the stack already emits — no new data source, only Log Analytics query cost.
It turns the APIM `llm-emit-token-metric` counter (dimensioned by *API ID*) and the backend's
`RAG retrieval audit` trace into showback views: **total tokens over time**, **tokens by API**, the
**prompt-vs-completion-vs-total** split, and **RAG retrievals over time**, all scoped by a time-range
pill. Multiply the token totals by your model's per-token price for a cost estimate. It is **always
deployed** (no switch, wired from [`main.bicep`](../infra/main.bicep)'s `workbookName`) and its KQL targets the classic App
Insights `customMetrics`/`traces` tables via the component `sourceId` — adjust the metric-name filters if
your emitted names differ. Its operational sibling — request health, dependencies, RAG audit, Content
Safety — is the **Agent Operations** workbook ([`ops-workbook.bicep`](../infra/modules/monitor/resources/ops-workbook.bicep), see [Logging](./logging.md)), which
replaced the stock `azd` Application Insights dashboard.

## 2. Spend guardrails

### Log Analytics daily ingestion cap

[`resources/loganalytics.bicep`](../infra/modules/monitor/resources/loganalytics.bicep) sets `workspaceCapping.dailyQuotaGb = 1` — a hard ceiling that stops a
logging spike from producing a runaway ingestion bill. Retention stays at the free 30-day default.
Set `-1` to disable the cap.

### App Insights sampling

[`resources/appinsights.bicep`](../infra/modules/monitor/resources/appinsights.bicep) exposes `samplingPercentage` (default **100** = keep all
telemetry, best for a demo). Lower it (e.g. `50`) to cap telemetry ingestion cost as traffic grows —
[`monitor.bicep`](../infra/modules/monitor/monitor.bicep) no longer forwards it, so tune it in the module directly.

## 3. Diagnostics cost control — `enableVerboseLogs`

Platform **logs** are the expensive part of Log Analytics ingestion; **metrics** are cheap and drive the
dashboards. The `enableVerboseLogs` flag ([`main.bicep`](../infra/main.bicep), default **`true`**) is threaded to the
noisy services — **APIM, Cosmos, Foundry, Search, App Service**. When `true`, the full `allLogs` +
`audit` category groups are sent; when `false`, their diagnostic settings ship **metrics only**
(`logs: []`).

```bicep
logs: enableVerboseLogs ? [ { categoryGroup: 'allLogs', enabled: enableLogs } … ] : []
```

Audit logs stay disabled by default (`enableAuditLogs`), so `true` means `allLogs` only.
Backend **application** telemetry (including the RAG retrieval audit, see [`logging.md`](logging.md)) flows through
Application Insights and is **unaffected** by this flag.

This is the **first lever to pull if Log Analytics cost is a concern**: platform logs are on out of the
box so gateway and backend request logs are there when you need to troubleshoot, but the workspace's
`dailyQuotaGb = 1` cap means a busy environment can exhaust its daily budget and stop ingesting. Set
`enableVerboseLogs: false` per environment, or raise `dailyQuotaGb` in
[`loganalytics.bicep`](../infra/modules/monitor/resources/loganalytics.bicep), depending on which you
value more.

## 4. Right-sizing levers

### Backend App Service Plan

[`modules/app/app.bicep`](../infra/modules/app/app.bicep) parameterizes the plan (`appServicePlanSku` / `appServicePlanSkuCode`, default
`Basic` / **`B1`**). Basic is the functional floor — the backend runs a continuous `QueueIngestionWorker`
`BackgroundService`, which needs **Always On** (Basic+ only); Free/Shared (`F1`/`D1`) also impose a
60-CPU-min/day quota that stops the app (HTTP 403) and cap the process at 32-bit/2 GB, so they can't host it.
B1 (1 vCPU / 1.75 GB) suits this I/O-bound workload (LLM/OCR/embeddings run off-box via APIM); bump to `B2`
(2 vCPU / 3.5 GB) if a large-file ingestion overlapping concurrent streams saturates the single core, or
`P1v3` for real traffic. Changing SKU is an in-place update (non-destructive). The
frontend adds no plan cost: it is an Azure **Static Web App** on the **Free** SKU (`staticWebAppSku`,
[`modules/app/resources/static-web-app.bicep`](../infra/modules/app/resources/static-web-app.bicep)) — no App Service Plan, no server tier.

### Foundry model capacity

[`modules/foundry/foundry.bicep`](../infra/modules/foundry/foundry.bicep) sets each deployment's **GlobalStandard capacity** (chat `1000`, embedding
`150`). This is a per-model **TPM rate ceiling** in thousands of tokens/min, **not** a fixed charge —
GlobalStandard bills pay-per-token — but a bounded ceiling stops a runaway-spend scenario in a demo.
Raise per environment as throughput needs grow.

### Cosmos serverless option

[`modules/cosmosdb/resources/account.bicep`](../infra/modules/cosmosdb/resources/account.bicep) exposes `useServerless` (default **`false`** = provisioned
throughput + free tier). When `true`, it enables the `EnableServerless` capability and drops the
provisioned throughput cap and free tier (both incompatible with serverless):

```bicep
capabilities: useServerless ? [ { name: 'EnableServerless' } ] : []
capacity:     useServerless ? {} : { totalThroughputLimit: totalThroughputLimit }
enableFreeTier: useServerless ? false : enableFreeTier
```

Serverless bills per-request (RU consumed) — cheaper for bursty/low demo traffic — and sidesteps the
one-free-tier-account-per-subscription limit for a second environment.

> ⚠️ **Opt-in for fresh deployments only.** Cosmos does not allow converting an existing provisioned
> account to serverless in place; flip this before first provision of an environment.

## 5. Data lifecycle & retention

### Storage blob age-out

Uploaded attachments and their Document-Intelligence markdown output are otherwise only purged on
session/file delete, so they accumulate cost indefinitely. [`resources/account.bicep`](../infra/modules/storage/resources/account.bicep) adds a
`managementPolicies` rule (`lifecycleDeleteAfterDays`, default **90**): block blobs are **tiered to Cool**
at half the window (45 days) and **deleted** at the full window (90 days). Set `0` to disable. Keep the
window generous — these blobs back the RAG citation previews.

### Conversation transcript TTL

Cosmos stores transcripts with `ttl = -1` ("never expire") by default so users can resume days later, but
that means unbounded storage/RU growth. The `MAX_HISTORY_TTL_DAYS` env var
(`AgentOptions.MaxHistoryTtlDays`, wired from the `historyTtlDays` param → app setting) bounds it:

- **`0` (default)** → `MessageTtlSeconds = -1` (never expire).
- **`> 0`** → `MessageTtlSeconds = days × 86400`, so Cosmos auto-evicts old messages.

It must map to `-1` and never `null` — a literal `ttl: null` makes Cosmos reject every write with
`BadRequest` (see [`AgentFactory.cs`](../src/agent_backend/Services/AgentFactory.cs) and the Cosmos schema note in [`CLAUDE.md`](../CLAUDE.md)).

## 6. Already-present token governance (context)

The largest AI-workload cost — model tokens — was already well controlled before this FinOps pass, and
remains the primary defense:

- **APIM gateway** ([`modules/apim/policies/foundry-api-policy.xml`](../infra/modules/apim/policies/foundry-api-policy.xml)): `llm-token-limit`
  (500K TPM, 30M-tokens/hour quota — below combined model capacity), `quota-by-key`, `rate-limit-by-key`, and `llm-emit-token-metric`
  (per-API token metric to App Insights — the raw material the **Token & Cost Insights** workbook now
  visualizes, see §1).
- **Backend**: `MAX_CONTEXT_WINDOW_TOKENS` / `MAX_OUTPUT_TOKENS` plus the in-context **compaction
  pipeline** (evicts old RAG tool-result dumps, then truncates oldest turns) cap input tokens per turn.

## Verifying the controls

After `azd provision` (or `az deployment sub what-if` to preview):

```shell
# Tags present on every resource
az resource list -g rg-app-<env>-<token> --query "[].tags"

# Token & cost showback workbook
az monitor app-insights workbook list -g rg-monitor-<env>-<token> -o table

# Log Analytics daily cap
az monitor log-analytics workspace show -g rg-monitor-<env>-<token> -n log-<env>-<token> \
  --query workspaceCapping.dailyQuotaGb

# Storage lifecycle rule
az storage account management-policy show --account-name st<env><token> -g rg-common-<env>-<token>

# App Service Plan SKU and model capacity
az appservice plan show -g rg-app-<env>-<token> -n plan-app-<env>-<token> --query sku
az cognitiveservices account deployment list -g rg-ai-<env>-<token> -n aif-<env>-<token> -o table
```

For the transcript TTL lever, set `MAX_HISTORY_TTL_DAYS=7` locally, send a `/chat` turn, and confirm the
Cosmos document's `ttl` is `604800` (not `-1`, never `null`); unset ⇒ `-1`.

## Not yet implemented (roadmap)

Larger changes deferred for later evaluation: an **environment-tiered cost profile**
(`dev`|`prod` switch driving SKUs across the board), an **APIM SKU strategy** (Developer vs Basic v2 vs
Consumption — pending AI-gateway policy-compatibility checks), and **Azure Policy tag governance** to
enforce the allocation tags at deploy time.
