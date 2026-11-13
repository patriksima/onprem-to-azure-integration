# ADR-001 · Event Hubs (Kafka endpoint) replaces self-managed Kafka

**Status:** accepted · **Date:** 2026-01 · **Deciders:** integration architect, Kafka engineer, head of IT

## Context

Three-broker Kafka 2.6 cluster on-prem, two topics, ~1 msg/s average, 45 msg/s peak, 7-day retention. Operated by one engineer. No TLS, no auth. The cluster is the single most person-dependent component in the estate ([02 §5 R1](../02-plan-assessment.md)).

The CRM publisher uses `Confluent.Kafka` 1.x. Consumers are custom jobs that will be rebuilt anyway ([ADR-002](ADR-002-functions-and-logic-apps-split.md)).

## Options

| Option | For | Against |
|---|---|---|
| **A. Azure Event Hubs Standard with Kafka endpoint** | Fully managed; Kafka protocol 1.0+ compatible, so the publisher keeps its client; native triggers for Functions and Logic Apps; private endpoints; MI/RBAC; cheapest by an order of magnitude | Not Kafka: no compaction on Standard, no transactions, no Kafka Streams, no Schema Registry Confluent-compat (Azure has its own); partition count fixed after creation on Standard; 7-day max retention on Standard |
| B. Managed Kafka (Confluent Cloud on Azure, or HDInsight Kafka) | Full Kafka semantics | Another vendor contract or a cluster to patch; cost 5–10×; no native Functions trigger with checkpointing; private networking more involved |
| C. Azure Service Bus | Dead-lettering, sessions, transactions, queues semantics | Not Kafka-compatible — publisher must be rewritten; pull-based competing consumers rather than a log; replay requires the application to store events itself |
| D. Keep Kafka, move it to Azure VMs | Zero application change | Moves the people problem to the cloud and adds VM patching; nothing improves |

## Decision

**Option A.** Event Hubs Standard, Kafka-enabled namespace, one event hub per topic, one consumer group per consumer, partition count 4 (from 6 — see consequences), `disableLocalAuth: true`, private endpoint only.

The publisher changes: bootstrap server, `security.protocol=SASL_SSL`, `sasl.mechanism=OAUTHBEARER` with a token callback using the SPN certificate. Roughly 30 lines of config and code, tested in week 1 of wave 1.

Features we lose (compaction, transactions, Streams) are features the estate does not use. We checked.

## Consequences

- Partition count cannot be increased later on Standard. 4 partitions give ~10× headroom over measured peak; chosen low because parallelism beyond 4 would need a bigger SQL anyway. If this proves wrong, the fix is a new event hub and a consumer-group migration, which the shadow-mode machinery from wave 1 already supports.
- 7-day retention is the replay window. Longer replay = Event Hubs Capture to blob (cheap, enabled in prod, 1-year retention) — not for the consumers' normal path, only for forensics and backfill.
- The Kafka engineer's role changes from operating a cluster to owning event contracts and consumer onboarding. Discussed with him before the decision, not after.
- Migration mechanics (MirrorMaker 2 bridge, reversal) are in [05 §2](../05-migration-plan.md).
- Revisit if: a future workload needs > 32 partitions, log compaction, or > 7-day hot retention. Then Event Hubs Premium or Dedicated, not a return to self-managed Kafka.
