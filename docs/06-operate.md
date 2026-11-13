# 06 · Operate — monitoring, alerting, runbooks

> CAF phases: **Govern** and **Manage**. The migration is not done when the last wave closes; it is done when the support team can run it without the people who built it.

## 1. What "healthy" means — SLIs and SLOs

| Flow | SLI | SLO | Measured by |
|---|---|---|---|
| Reporting | Time from `order.created` to row visible in `fact_order` | p95 < 5 min, p99 < 15 min | App Insights custom metric `ReportingLatencySeconds` (consumer computes `now − occurredAt`) |
| Notifications | Order confirmations sent within 10 min | 99.5 % of orders | `NotificationsSent` vs `OrdersCreated` per hour (KQL) |
| Partner API | Availability of `GET /partners/orders` | 99.9 % monthly | APIM `Requests` success rate + availability test from hub |
| Partner sync | Stock import processed within 30 min of receipt | 99 % | Logic App run duration + success |
| Event backbone | Consumer lag | < 1,000 events per consumer group | scheduled query (§3) |
| Poison | Events in `poison-messages` not triaged | 0 older than 1 business day | storage inventory + workbook |

SLOs are agreed with the business owners of each flow, written here, and reviewed quarterly. Error budgets are used to decide whether the team works on features or on reliability — the same rule as any product team.

## 2. Telemetry design

| Signal | Source | Destination | Retention |
|---|---|---|---|
| Resource logs and metrics (all resources) | Diagnostic settings in Bicep | Workload LAW; platform policy also copies to central LAW | 30 d dev / 90 d prod |
| Application traces, dependencies, exceptions | Functions host + App Insights SDK; Logic Apps built-in | App Insights (workspace-based) | same |
| Workflow run history | Logic Apps Standard runtime | Logic App storage + `LogicAppWorkflowRuntime` table | 90 d |
| Custom business metrics (`DuplicateEvents`, `PoisonEvents`, `ReportingLatencySeconds`, `PartnerSyncRows`) | Consumers via `TelemetryClient.GetMetric` | App Insights `customMetrics` | same |
| Audit: who called the partner API | APIM diagnostic (request/response headers, no bodies) | LAW `ApiManagementGatewayLogs` | 90 d |
| SQL auditing | Server-level auditing | LAW | 90 d |

Every log line and trace from the consumers carries `eventId`, `orderId`/`customerId`, `consumer`, `schemaVersion` as custom dimensions. Support can answer "what happened to order 48213?" with one KQL query across Functions, Logic Apps and APIM.

## 3. Alert catalogue

All alerts are defined in [`infra/modules/alerts.bicep`](../infra/modules/alerts.bicep) and route to the Action Group. Severity: 0 = page now, 1 = page in business hours, 2 = ticket, 3 = informational.

| Alert | Condition | Sev | Runbook |
|---|---|---|---|
| Reporting consumer failing | Function `requests/failed` > 0 in 5 min | 1 | [RB-01](#rb-01-consumer-failing) |
| Notifications consumer failing | same | 1 | RB-01 |
| Function App down | `HealthCheckStatus` < 100 for 5 min | 0 | RB-01 |
| Logic App run failed | `LogicAppWorkflowRuntime` status == Failed, any in 5 min | 2 | [RB-02](#rb-02-logic-app-run-failed) |
| Consumer lag | `IncomingMessages − OutgoingMessages` per consumer group > 1,000 over 15 min, **or** incoming > 0 and consumer executions == 0 over 15 min | 1 | [RB-03](#rb-03-consumer-lag) |
| Event Hubs throttled | `ThrottledRequests` > 0 in 5 min | 2 | [RB-04](#rb-04-event-hubs-throttling) |
| Event Hubs server errors | `ServerErrors` > 0 in 5 min | 1 | RB-04 |
| Poison event received | new blob in `poison-messages` (StorageBlobLogs PutBlob) | 2 | [RB-05](#rb-05-poison-event) |
| Azure SQL CPU | `cpu_percent` > 80 for 15 min | 2 | [RB-06](#rb-06-sql-pressure) |
| Azure SQL storage | `storage_percent` > 85 | 2 | RB-06 |
| APIM 5xx | `FailedRequests` (backend 5xx) > 5 in 5 min | 1 | [RB-07](#rb-07-partner-api-errors) |
| APIM capacity | `Capacity` > 75 % for 15 min | 2 | RB-07 |
| APIM availability test | 2 of 3 locations fail | 0 | RB-07 |
| Key Vault availability | `Availability` < 100 % for 5 min | 1 | escalate to platform |
| Key Vault secret near expiry | Event Grid `SecretNearExpiry` (30 d) | 3 | [RB-08](#rb-08-secret-rotation) |
| VPN tunnel down (platform alert, subscribed) | `TunnelIngressBytes` == 0 for 10 min | 0 | platform runbook; our impact: publisher spools locally for up to 1 h |

Alert fatigue is a design failure. Every alert here has a named action; alerts that fired three times without an action are deleted or re-tuned in the monthly review.

## 4. Runbooks

Runbooks are short on purpose. They tell the on-call person where to look first and what is safe to do without an architect.

### RB-01 · Consumer failing

1. App Insights → Failures → filter `cloud_RoleName == reporting-consumer`. Top exception type tells you which of the three cases you are in.
2. **SQL exceptions** (timeout, login failed): check Azure SQL metrics (RB-06); check MI role membership has not been removed (`SELECT * FROM sys.database_principals`). Safe action: none needed, retries will catch up once SQL recovers; lag alert will tell you if not.
3. **Deserialization / validation exceptions**: a producer-side schema change. Events are landing in poison (RB-05). Safe action: confirm with CRM team; do not redeploy.
4. **Host-level (storage, checkpoint)**: Function App → Diagnose and solve. Safe action: restart Function App. Processing resumes from last checkpoint; duplicates are handled.
5. Still failing after 30 min → escalate to integration team on-call architect.

### RB-02 · Logic App run failed

1. Logic App → Workflows → the one in the alert → Run history → failed run. The failed action is highlighted; its outputs include the HTTP response.
2. **Partner endpoint 4xx/5xx**: retries (4×) are exhausted; the event has been written to poison. Contact partner per the partner contact sheet in Key Vault tag `partnerContact`. Replay via RB-05 when they confirm.
3. **CRM façade unreachable**: check VPN alert; check CRM façade health endpoint from hub jump host. Safe action: none; Logic App will replay from poison after RB-05.
4. Resubmit is available from run history for a single run — safe because downstream calls are idempotent (`Idempotency-Key` header = `eventId`).

### RB-03 · Consumer lag

1. Which consumer group? Workbook "Event backbone" → lag per group.
2. Lag growing, consumer **running**: throughput problem. Check Function instance count (EP1 max 3 in prod); check SQL CPU. Safe action: raise `maximumElasticWorkerCount` by 1 (bounded by partition count — 4 — beyond which it does nothing).
3. Lag growing, consumer **not running** (0 executions): Function App stopped or trigger disabled. Safe action: restart; verify `AzureWebJobsStorage__accountName` resolves (DNS).
4. Lag after a deliberate replay (RB-05): expected; note it in the channel.

### RB-04 · Event Hubs throttling

Standard tier: 1 TU = 1 MB/s in, 2 MB/s out. Auto-inflate is enabled to 4 TU in dev, 8 in prod. Throttling at the cap means either a producer burst (check `IncomingBytes`) or a consumer re-reading from the start. Safe action: raise auto-inflate max by 2 TU (cost ≈ €20/TU/month). Persistent → architect: time to look at Premium or a second namespace.

### RB-05 · Poison event

1. Blob `poison-messages/{consumer}/{date}/{eventId}.json` contains the event, the error, and the attempt count.
2. Classify: **transient downstream** (partner down, SQL down) → replay once downstream is healthy; **bad data** (schema, business rule) → raise with CRM team, do not replay until fixed, move blob to `poison-messages/triaged/`.
3. Replay: Logic App `poison-handler` → HTTP trigger with `{ "eventId": "..." }`; it re-publishes to the original hub with header `replayOf=eventId`. The consumer's idempotency check will *skip* it if it was actually processed — so if you are replaying because processing failed *after* the idempotency record was written, delete the `processed_events` row first (documented SQL in the handler's description).
4. Poison older than one business day without triage shows in the daily workbook and is discussed at standup.

### RB-06 · SQL pressure

1. Query Performance Insight → top queries by CPU in the last hour.
2. Reporting consumer's `MERGE` is the usual suspect after a replay. Safe action: wait if it is a replay. Otherwise check missing index recommendations.
3. Power BI refresh schedules: analysts sometimes add hourly refreshes of full tables. Safe action: ask; move refresh out of business hours.
4. Scale: GP 2 → 4 vCore is online and takes minutes. Do it if p95 latency SLO is at risk; log it for cost review.

### RB-07 · Partner API errors

1. APIM → Analytics → filter 5xx; `ApiManagementGatewayLogs` shows `BackendResponseCode` and `LastErrorReason`.
2. Backend is the Logic App callback URL. If Logic App is healthy and APIM gets 503 → check `snet-apim` NSG and route table were not changed (platform change calendar).
3. 401/403 spikes from one partner: their certificate expired or subscription key rotated. Partner contact sheet.
4. Capacity > 75 %: Developer tier (dev) has no scale; Premium (prod) → add a unit (≈ €2,600/month — needs approval, so do it only if the SLO is at risk, and raise ADR-003's open question).

### RB-08 · Secret rotation

Key Vault secrets with an `expires` date: ACS connection string (yearly), partner API credentials (per partner contract), on-prem SPN certificate (yearly). Rotation: create new version → services pick it up within 24 h (KV references cache) or on restart → verify → disable old version after 7 days. The SPN certificate additionally requires the on-prem publisher config update; owner and calendar entry in the integration team's rota.

## 5. Governance

| Topic | Rule |
|---|---|
| Changes | Everything via PR to `main`; `what-if` and PSRule must pass; one approval from another integration engineer; prod deploys via pipeline with environment approval |
| Drift | Scheduled `what-if` nightly; any drift opens a ticket; manual portal changes in prod are reverted by the next deployment, by design |
| Cost | Budget alerts at 80 % / 100 % of monthly forecast per subscription; monthly cost review with the two observations from [04 §8](04-target-architecture.md#8-cost) as standing agenda |
| Access | No standing user access to prod resources; PIM activation with justification; MI-only for workloads |
| Tags | `workload`, `environment`, `costCenter`, `owner`, `managedBy` enforced by platform policy; Bicep sets them on every resource |
| Backups | Azure SQL PITR 7 d (dev) / 35 d (prod), geo-redundant backup to paired region; Logic App storage account soft delete 14 d; Event Hubs retention 7 d is the replay window, not a backup |
| DR | Documented RTO 4 h / RPO 1 h for the integration layer; rehearsed once a year by redeploying `infra/` to the paired region in a drill subscription |
| Review | Quarterly WAF review using the table in [04 §7](04-target-architecture.md#7-well-architected-framework-review) as the baseline — what changed, what trade-off is no longer acceptable |

## 6. Handover criteria

The integration team hands the workload to run-state when:

- [ ] every alert has fired at least once in a test and the runbook was followed by someone who did not write it
- [ ] support has resolved three real incidents during hypercare using only the runbooks
- [ ] the "what happened to order X" query is a saved query in LAW and support has used it
- [ ] on-call rota and escalation path are in the service catalogue
- [ ] the decommission checklist from [05 §5](05-migration-plan.md#5-wave-4--decommission-weeks-3340) is complete or has dated owners

---
Previous: [05 · Migration plan](05-migration-plan.md) · See also: [Architecture decision records](adr/)
