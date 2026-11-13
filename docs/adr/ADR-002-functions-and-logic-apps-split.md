# ADR-002 · Functions for event consumers, Logic Apps Standard for partner orchestration

**Status:** accepted · **Date:** 2026-01

## Context

Three on-prem jobs are being rebuilt. They differ in shape:

| Job | Shape | Volume | Who looks at it when it fails |
|---|---|---|---|
| Reporting ETL | per event: transform, upsert into SQL | every event | integration engineer |
| Notifications | per event: render template, send email | every `order.created` | integration engineer |
| Partner sync | per partner: multi-step exchange with an external system, retries, business support involvement | 5 partners, dozens of calls per day | **support staff + partner managers** |

The team is .NET-fluent. Two engineers have Logic Apps experience, four have C#.

## Options

1. **Everything in Functions** — one runtime, one skill set, unit-testable. But partner flows need run history that a non-developer can read, per-step retry configuration, and will change often as partners negotiate formats. Building that visibility in code is building a worse Logic Apps.
2. **Everything in Logic Apps Standard** — maximum visibility. But per-event processing at 45 msg/s with stateful workflows is the wrong tool: every run persists its state to storage, throughput per WS1 instance is a fraction of a Function's, and transformation logic in a designer is harder to unit-test and review than C#.
3. **Split by shape** — Functions where the unit of work is one event and the logic is code; Logic Apps where the unit of work is a conversation with an external party and the logic is orchestration.

## Decision

**Option 3.**

- **Functions (.NET 10 isolated, Elastic Premium EP1):** `reporting-consumer`, `notifications-consumer`. Event Hubs trigger, batch processing, idempotency in code, unit tests with the host in-process.
- **Logic Apps Standard (WS1):** `partner-order-export`, `partner-stock-import` (one workflow per partner, generated from a template), `poison-handler`. Stateful, Event Hubs built-in trigger (split-on), HTTP actions with retry policy, run history retained 90 days.

Both run on plans that support VNet integration; the Consumption tiers of either were rejected for that reason alone.

## Consequences

- Two runtimes to deploy and monitor. Mitigated: same App Insights, same Bicep patterns (`storage.bicep` reused), same `CONSUMER_MODE` convention ([ADR-008](ADR-008-shadow-mode-over-feature-flags.md)).
- Logic Apps workflow definitions are JSON in source control; reviewed in PRs like code, with a required run of the workflow in dev before merge. Designer-only changes in the portal are drift and get overwritten — this is a rule, communicated.
- Fixed cost floor: EP1 + WS1 ≈ €300/month per environment even idle. Accepted as the price of private networking; dev is torn down nightly.
- If partner count grows past ~20, per-partner workflows become unwieldy; the planned evolution is one parameterised workflow per direction with partner config in a table. Not needed for 5.
