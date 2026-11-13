using '../main.bicep'

// Development: cheapest SKUs that still exercise the full private-networking path.
// Object IDs below are placeholders in GUID form; replace them with the real Entra object IDs
// (never with names) before deploying.

param environmentName = 'dev'
param location = 'swedencentral'
param costCenter = 'CC-4710-INTEGRATION'
param owner = 'integration-platform@meridian.example'

// Landing-zone references (connectivity subscription, managed by the platform team).
param vnetAddressSpace = '10.20.0.0/22'
param hubVnetId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-connectivity-swc/providers/Microsoft.Network/virtualNetworks/vnet-hub-swc'
param firewallPrivateIp = '10.0.1.4'

// Observability
param logRetentionInDays = 30
param logDailyQuotaGb = 5
param alertEmailReceivers = [
  'integration-platform@meridian.example'
]
param enableAvailabilityTest = false

// Compute: single instance, no zone redundancy.
param appPlanCapacity = 1
param appPlanZoneRedundant = false
param storageSkuName = 'Standard_ZRS'

// Event Hubs
param eventHubsCapacity = 1
param eventHubsMaximumThroughputUnits = 2
param eventHubsZoneRedundant = true
param onPremProducerObjectId = '11111111-1111-1111-1111-111111111111' // placeholder: on-prem Kafka producer service principal

// SQL: serverless, auto-pause after an hour of inactivity.
param sqlEntraAdminLogin = 'sg-meridian-sql-admins'
param sqlEntraAdminObjectId = '22222222-2222-2222-2222-222222222222' // placeholder: Entra security group
param sqlDatabaseSku = {
  name: 'GP_S_Gen5'
  tier: 'GeneralPurpose'
  family: 'Gen5'
  capacity: 1
}
param sqlAutoPauseDelayMinutes = 60
param sqlZoneRedundant = false
param sqlBackupStorageRedundancy = 'Zone'

// API Management: Developer tier (no SLA) is enough to validate policies and networking.
param apimSku = {
  name: 'Developer'
  capacity: 1
}
param apimZones = []
param apimPublisherEmail = 'integration-platform@meridian.example'
param apimPublisherName = 'Meridian Integration Platform (dev)'
param apimSamplingPercentage = 100
