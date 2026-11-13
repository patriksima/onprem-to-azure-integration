using '../main.bicep'

// Production: zone-redundant everywhere the service supports it, 90-day retention, two notification
// targets. Object IDs below are placeholders in GUID form; replace them with the real Entra object IDs
// before deploying.

param environmentName = 'prod'
param location = 'swedencentral'
param costCenter = 'CC-4710-INTEGRATION'
param owner = 'integration-platform@meridian.example'

// Landing-zone references (connectivity subscription, managed by the platform team).
param vnetAddressSpace = '10.21.0.0/22'
param hubVnetId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-connectivity-swc/providers/Microsoft.Network/virtualNetworks/vnet-hub-swc'
param firewallPrivateIp = '10.0.1.4'

// Observability
param logRetentionInDays = 90
param logDailyQuotaGb = -1
param alertEmailReceivers = [
  'integration-oncall@meridian.example'
  'integration-platform@meridian.example'
]
param enableAvailabilityTest = false

// Compute: three instances so each App Service plan has one instance per availability zone.
param appPlanCapacity = 3
param appPlanZoneRedundant = true
param storageSkuName = 'Standard_GZRS'

// Event Hubs
param eventHubsCapacity = 2
param eventHubsMaximumThroughputUnits = 10
param eventHubsZoneRedundant = true
param onPremProducerObjectId = '11111111-1111-1111-1111-111111111112' // placeholder: on-prem Kafka producer service principal (prod)

// SQL: provisioned 2 vCores, zone redundant, geo-redundant backups.
param sqlEntraAdminLogin = 'sg-meridian-sql-admins'
param sqlEntraAdminObjectId = '22222222-2222-2222-2222-222222222222' // placeholder: Entra security group
param sqlDatabaseSku = {
  name: 'GP_Gen5'
  tier: 'GeneralPurpose'
  family: 'Gen5'
  capacity: 2
}
param sqlAutoPauseDelayMinutes = -1
param sqlZoneRedundant = true
param sqlBackupStorageRedundancy = 'GeoZone'

// API Management: Premium, one unit. Add zones (and raise capacity to match) when the partner SLA
// requires zone redundancy; multi-region is a separate decision.
param apimSku = {
  name: 'Premium'
  capacity: 1
}
param apimZones = []
param apimPublisherEmail = 'integration-platform@meridian.example'
param apimPublisherName = 'Meridian Integration Platform'
param apimSamplingPercentage = 25
