# ADR-006 · No Service Bus in the initial architecture

**Status:** accepted; revisit at wave 3 · **Date:** 2026-02

## Context

Reviewers of the first draft asked, reasonably: "Where is Service Bus? Event Hubs has no dead-letter queue." The question deserves a recorded answer rather than a diagram with one more box.

## The actual requirement

What the estate needs from messaging:

| Need | Event Hubs | Service Bus |
|---|---|---|
| Kafka-compatible ingestion from the existing publisher | yes | no |
| Replay a time window (consumer bug, backfill) | yes, by offset/time | no (once consumed, gone; would need the app to store events) |
| Multiple independent consumers of the same stream | consumer groups | topic subscriptions |
| Per-key ordering | partition key | sessions |
| Dead-letter | **no** | yes |
| Scheduled / deferred messages | no | yes |
| Transactions across messages | no | yes |
| Request/response, competing consumers for work items | awkward | yes |

Two rows favour Service Bus: dead-lettering and command-style work distribution. Neither is needed by the three flows in scope: all three are *reactions to a fact that happened in the CRM*, i.e. events, and replay matters more than dead-lettering.

## Options for poison handling without a DLQ

1. **Blob container `poison-messages` + alert + replay Logic App** — simple, inspectable, replay reuses the normal path, retention policy on the container.
2. Service Bus queue as a dead-letter target — adds a namespace, a private endpoint, RBAC, and a second messaging concept for the team, in exchange for a DLQ UI that is no better than a blob listing with a workbook.
3. Storage queue — like 2 but weaker tooling; no benefit over blob.

## Decision

**Event Hubs only; poison handling via option 1** ([04 §5](../04-target-architecture.md#5-error-handling-and-idempotency)). The consumer writes the event with error context to blob and checkpoints past it; a scheduled-query alert fires on new blobs; the `poison-handler` Logic App replays on request.

## When this decision is wrong

Add Service Bus when a flow appears that is a **command** rather than an **event** — "reserve this stock", "generate this invoice" — where exactly-one-worker semantics, scheduled delivery, or transactional outbox matter. Wave 3's partner *orders* path is the likely candidate: a partner's `POST /orders` is a command. The current design handles it synchronously through APIM → Logic App → CRM façade, which is adequate for five partners and dozens of orders a day. If it becomes asynchronous, it gets a Service Bus queue with a DLQ, and that queue is the one place a DLQ belongs.

## Consequences

- One messaging service to secure, monitor and explain. The team's mental model is "it is a log; consumers are idempotent; bad events go to blob."
- Poison replay is an operational procedure ([RB-05](../06-operate.md#rb-05--poison-event)), not a button in a portal. Acceptable at expected poison volumes (< 10/month).
- `infra/modules/` is ready for a `servicebus.bicep` with the same conventions when the time comes; it is deliberately not there now.
