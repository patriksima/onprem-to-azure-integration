# Architecture decision records

One file per decision that somebody will question later. Format: context → options → decision → consequences. Status is `accepted` unless stated.

| ADR | Decision | Status |
|---|---|---|
| [001](ADR-001-event-hubs-instead-of-kafka.md) | Replace self-managed Kafka with Event Hubs (Kafka endpoint), not with managed Kafka or Service Bus | accepted |
| [002](ADR-002-functions-and-logic-apps-split.md) | Functions for high-frequency event consumers, Logic Apps Standard for partner orchestration | accepted |
| [003](ADR-003-apim-as-partner-facade.md) | API Management in internal VNet mode as the partner façade; tier choice left open until go-live | accepted, open question |
| [004](ADR-004-sql-migration-order.md) | Migrate the reporting database *after* the event consumers, to Azure SQL Database not Managed Instance | accepted |
| [005](ADR-005-crm-stays-on-prem.md) | CRM application and its OLTP database stay on-prem; integration layer designed to make the CRM replaceable | accepted |
| [006](ADR-006-no-service-bus-in-wave-1.md) | No Service Bus in the initial architecture; poison handling via blob + alert | accepted, revisit in wave 3 |
| [007](ADR-007-identity-based-storage-and-no-keys.md) | No shared keys or connection strings anywhere; managed identity for host storage, Event Hubs, SQL | accepted |
| [008](ADR-008-shadow-mode-over-feature-flags.md) | Consumer behaviour switched by one `CONSUMER_MODE` setting rather than a feature-flag service | accepted |
