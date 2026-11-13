// Azure SQL logical server + the crm-reporting database that replaces the on-prem reporting replica.
// Entra-only authentication: there is no SQL login at all, so there is no password to rotate, leak
// or put in a parameter file. The Function App connects with its managed identity.

@description('Base name, e.g. "mer-int-dev".')
param baseName string

@description('Azure region.')
param location string

@description('Resource tags.')
param tags object

@description('Public maintenance configuration for the database. SQL_<Region>_DB_2 = Fri–Sun 22:00–06:00 local, which matches the agreed change window; SQL_Default lets Azure pick any time.')
param maintenanceWindowName string = 'SQL_SwedenCentral_DB_2'

@description('Display name (UPN or group name) of the Entra principal that administers the server. Use a group, not a person.')
param entraAdminLogin string

@description('Object ID of the Entra administrator principal.')
param entraAdminObjectId string

@description('Tenant ID of the Entra administrator principal.')
param entraAdminTenantId string = tenant().tenantId

@description('Database SKU. Dev: GP_S_Gen5 serverless 1 vCore; prod: GP_Gen5 2 vCores provisioned.')
param databaseSku object = {
  name: 'GP_S_Gen5'
  tier: 'GeneralPurpose'
  family: 'Gen5'
  capacity: 1
}

@description('Auto-pause delay in minutes for serverless SKUs; -1 disables auto-pause (required for provisioned SKUs).')
@minValue(-1)
@maxValue(10080)
param autoPauseDelayMinutes int = -1

@description('Minimum vCores for serverless SKUs. Ignored by provisioned SKUs.')
param minCapacity string = '0.5'

@description('Zone-redundant database (prod). Not available for serverless in every region, so it is a parameter.')
param zoneRedundant bool = false

@description('Backup storage redundancy. Zone in dev keeps data in-region; Geo in prod gives cross-region restore.')
@allowed([
  'Local'
  'Zone'
  'Geo'
  'GeoZone'
])
param backupStorageRedundancy string = 'Zone'

@description('Subnet resource ID for the private endpoint (snet-pe).')
param peSubnetId string

@description('Resource ID of the privatelink.database.windows.net zone.')
param privateDnsZoneId string

@description('Log Analytics workspace resource ID for diagnostics and auditing.')
param logAnalyticsWorkspaceId string

var serverName = '${baseName}-sql'
var databaseName = 'crm-reporting'

// Serverless-only properties are rejected on provisioned SKUs, so they are emitted conditionally.
var isServerless = contains(databaseSku.name, '_S_')

resource sqlServer 'Microsoft.Sql/servers@2025-01-01' = {
  name: serverName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    version: '12.0'
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
    restrictOutboundNetworkAccess: 'Disabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      principalType: 'Group'
      login: entraAdminLogin
      sid: entraAdminObjectId
      tenantId: entraAdminTenantId
      azureADOnlyAuthentication: true
    }
  }
}

resource database 'Microsoft.Sql/servers/databases@2025-01-01' = {
  parent: sqlServer
  name: databaseName
  location: location
  tags: tags
  sku: databaseSku
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maxSizeBytes: 34359738368 // 32 GB
    zoneRedundant: zoneRedundant
    autoPauseDelay: isServerless ? autoPauseDelayMinutes : null
    minCapacity: isServerless ? json(minCapacity) : null
    readScale: 'Disabled'
    requestedBackupStorageRedundancy: backupStorageRedundancy
    licenseType: 'LicenseIncluded'
    maintenanceConfigurationId: subscriptionResourceId('Microsoft.Maintenance/publicMaintenanceConfigurations', maintenanceWindowName)
    // Ledger/TDE defaults are already on; stating TDE explicitly is not needed in this API version.
  }
}

// The "master" database is where server-level audit events surface; declaring it lets us attach
// a diagnostic setting. Deploying it is a no-op on the actual database.
resource masterDatabase 'Microsoft.Sql/servers/databases@2025-01-01' = {
  parent: sqlServer
  name: 'master'
  location: location
  properties: {}
}

resource serverAuditing 'Microsoft.Sql/servers/auditingSettings@2025-01-01' = {
  parent: sqlServer
  name: 'default'
  properties: {
    state: 'Enabled'
    // Route audit to Log Analytics (via the master diagnostic setting below) instead of a storage
    // account: one fewer resource with keys and it lands next to the application logs.
    isAzureMonitorTargetEnabled: true
    retentionDays: 0
    auditActionsAndGroups: [
      'SUCCESSFUL_DATABASE_AUTHENTICATION_GROUP'
      'FAILED_DATABASE_AUTHENTICATION_GROUP'
      'BATCH_COMPLETED_GROUP'
    ]
  }
}

resource securityAlertPolicy 'Microsoft.Sql/servers/securityAlertPolicies@2025-01-01' = {
  parent: sqlServer
  name: 'Default'
  properties: {
    state: 'Enabled'
    emailAccountAdmins: true
  }
}

// Express vulnerability assessment needs no storage account, unlike the classic configuration.
resource vulnerabilityAssessment 'Microsoft.Sql/servers/sqlVulnerabilityAssessments@2025-01-01' = {
  parent: sqlServer
  name: 'default'
  properties: {
    state: 'Enabled'
  }
  dependsOn: [
    securityAlertPolicy
  ]
}

// 2021-05-01-preview is the only diagnostic-settings API with categoryGroup support; the GA 2016-09-01 lacks it.
#disable-next-line use-recent-api-versions
resource masterDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'audit-to-law'
  scope: masterDatabase
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { category: 'SQLSecurityAuditEvents', enabled: true }
    ]
  }
  dependsOn: [
    serverAuditing
  ]
}

// 2021-05-01-preview is the only diagnostic-settings API with categoryGroup support; the GA 2016-09-01 lacks it.
#disable-next-line use-recent-api-versions
resource databaseDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-law'
  scope: database
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { categoryGroup: 'allLogs', enabled: true }
    ]
    metrics: [
      { category: 'Basic', enabled: true }
      { category: 'InstanceAndAppAdvanced', enabled: true }
      { category: 'WorkloadManagement', enabled: true }
    ]
  }
}

module privateEndpoint 'private-endpoint.bicep' = {
  name: 'pe-${serverName}'
  params: {
    name: '${baseName}-pe-sql'
    location: location
    tags: tags
    subnetId: peSubnetId
    privateLinkServiceId: sqlServer.id
    groupId: 'sqlServer'
    privateDnsZoneId: privateDnsZoneId
  }
}

@description('Resource ID of the logical server.')
output serverId string = sqlServer.id

@description('Name of the logical server.')
output serverName string = sqlServer.name

@description('Fully qualified domain name of the logical server.')
output serverFqdn string = sqlServer.properties.fullyQualifiedDomainName

@description('Resource ID of the crm-reporting database.')
output databaseId string = database.id

@description('Name of the crm-reporting database.')
output databaseName string = database.name
