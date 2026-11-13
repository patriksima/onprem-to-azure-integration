# ADR-004 · Reporting database moves after the consumers, to Azure SQL Database

**Status:** accepted · **Date:** 2026-01

## Context

`crm_reporting` (95 GB, 3 GB/month) is written only by the reporting ETL job and read by Power BI and analysts. It sits on the same SQL Server 2016 instance as the CRM OLTP database. The instance must go when the data center goes; the OLTP database stays with the CRM for now ([ADR-005](ADR-005-crm-stays-on-prem.md)) and will move to a new on-prem host.

## Decision 1 — when

**After the event consumers (wave 2, not wave 1).**

If the database moved first, the nightly ETL job would write across the VPN and nothing would improve for anyone. If it moves after the reporting consumer exists, the consumer is the only writer at cutover and the migration is: online sync → stop old writer → final check → switch new writer to production schema. The shadow schema in wave 1 doubles as the rehearsal of the production write path.

## Decision 2 — what to

| Option | For | Against |
|---|---|---|
| **Azure SQL Database, General Purpose** | Cheapest managed option with zone redundancy; serverless in dev; PITR + geo-backup built in; private endpoint; Entra-only auth | No SQL Agent, no cross-database queries, no CLR — none used once the ETL job is gone (verified with Data Migration Assistant in wave 0) |
| Azure SQL Managed Instance | Near-100 % compatibility | ~3× the cost; 4-vCore minimum; slow to provision; compatibility is not needed |
| SQL Server on Azure VM | 100 % compatibility | A VM to patch; the thing we are leaving |
| Synapse / Fabric warehouse | "Reporting" sounds analytical | 95 GB and 12 analysts is not a warehouse problem; Power BI over Azure SQL is sufficient and far cheaper |

**Azure SQL Database, GP 2 vCore zone-redundant in prod, GP serverless 1 vCore in dev.** Hyperscale considered for the future if the database passes ~1 TB; not before.

## Decision 3 — how

Azure Database Migration Service, online mode, for the week before cutover; transactional replication as fallback if DMA flags DMS-incompatible objects. Cutover in the Saturday window; steps and rollback in [05 §3](../05-migration-plan.md#3-wave-2--reporting-database-weeks-1720).

## Consequences

- Power BI gateway must reach the private endpoint: the gateway moves to a VM in the spoke or uses a VNet data gateway. Chosen: **VNet data gateway** (managed, no VM). Platform team confirmed Power BI tenant settings allow it.
- Analysts lose cross-database queries to `crm` (OLTP). Three reports used them; they are rewritten to read from `fact_*` tables populated by the consumer — which is the correct design anyway.
- The consumer's MERGE is keyed on business keys so historic rows (written by the old ETL) and new rows coexist. Verified in shadow.
- Entra-only authentication means the DBA's SQL logins stop working; DBA access via Entra group with PIM. Communicated in wave 0, not at cutover.
