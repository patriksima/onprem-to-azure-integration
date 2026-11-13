// Meridian integration workload: on-prem Kafka/BizTalk-era integration replaced by Event Hubs,
// Logic Apps Standard, Azure Functions, Azure SQL and API Management, inside a landing-zone spoke.
// Resource-group scope; the hub (gateway, firewall) is referenced, never created.
//
// Deployment order is driven by data dependencies only; no artificial dependsOn:
//   network -> monitoring -> identity -> keyvault -> storage -> eventhubs/sql -> apps -> apim -> rbac -> alerts

targetScope = 'resourceGroup'

metadata name = 'Meridian integration spoke'
metadata description = 'Private, identity-only integration workload (APIM, Logic Apps Standard, Functions, Event Hubs, SQL).'

// ---------------------------------------------------------------------------------------------
// Naming, placement, tagging
// ---------------------------------------------------------------------------------------------

@description('Deployment environment. Drives SKU and retention defaults through the parameter files.')
@allowed([
  'dev'
  'prod'
])
param environmentName string

@description('Azure region for all regional resources.')
@metadata({ strongType: 'location' })
param location string = 'swedencentral'

@description('Organisation prefix for resource names.')
@minLength(2)
@maxLength(4)
param namePrefix string = 'mer'

@description('Workload token for resource names.')
@minLength(2)
@maxLength(6)
param workload string = 'int'

@description('Cost centre tag value.')
param costCenter string

@description('Owner tag value (team alias, not a person).')
param owner string

// ---------------------------------------------------------------------------------------------
// Networking (landing-zone references)
// ---------------------------------------------------------------------------------------------

@description('Address space of the spoke VNet.')
param vnetAddressSpace string = '10.20.0.0/22'

@description('Resource ID of the hub VNet (connectivity subscription). Empty disables peering.')
param hubVnetId string = ''

@description('Private IP of the hub Azure Firewall. Empty disables forced tunnelling.')
param firewallPrivateIp string = ''

// ---------------------------------------------------------------------------------------------
// Observability
// ---------------------------------------------------------------------------------------------

@description('Log Analytics retention in days.')
@minValue(30)
@maxValue(730)
param logRetentionInDays int = 30

@description('Daily Log Analytics ingestion cap in GB (-1 = none).')
@minValue(-1)
@maxValue(1000)
param logDailyQuotaGb int = -1

@description('E-mail receivers for the workload action group.')
@minLength(1)
param alertEmailReceivers array

@description('Deploy the public availability test against the APIM gateway (only when it is reachable from Azure test locations).')
param enableAvailabilityTest bool = false

// ---------------------------------------------------------------------------------------------
// Compute sizing
// ---------------------------------------------------------------------------------------------

@description('Instance count for the Logic App and Function App plans. 3 in prod for zone redundancy.')
@minValue(1)
@maxValue(20)
param appPlanCapacity int = 1

@description('Zone-redundant App Service plans (requires appPlanCapacity >= 3).')
param appPlanZoneRedundant bool = false

@description('Storage replication for the app host accounts.')
@allowed([
  'Standard_ZRS'
  'Standard_GZRS'
  'Standard_RAGZRS'
])
param storageSkuName string = 'Standard_ZRS'

// ---------------------------------------------------------------------------------------------
// Event Hubs
// ---------------------------------------------------------------------------------------------

@description('Base throughput units for the Event Hubs namespace.')
@minValue(1)
@maxValue(40)
param eventHubsCapacity int = 1

@description('Auto-inflate ceiling for the Event Hubs namespace.')
@minValue(1)
@maxValue(40)
param eventHubsMaximumThroughputUnits int = 4

@description('Zone-redundant Event Hubs namespace.')
param eventHubsZoneRedundant bool = true

@description('Object ID of the on-prem producer identity (Event Hubs Data Sender). Empty to skip.')
param onPremProducerObjectId string = ''

// ---------------------------------------------------------------------------------------------
// SQL
// ---------------------------------------------------------------------------------------------

@description('Display name of the Entra group that administers the SQL server.')
param sqlEntraAdminLogin string

@description('Object ID of the Entra administrator group.')
param sqlEntraAdminObjectId string

@description('Database SKU object (name, tier, family, capacity).')
param sqlDatabaseSku object = {
  name: 'GP_S_Gen5'
  tier: 'GeneralPurpose'
  family: 'Gen5'
  capacity: 1
}

@description('Serverless auto-pause delay in minutes (-1 = disabled / provisioned SKU).')
@minValue(-1)
@maxValue(10080)
param sqlAutoPauseDelayMinutes int = 60

@description('Zone-redundant database.')
param sqlZoneRedundant bool = false

@description('Backup storage redundancy for the database.')
@allowed([
  'Local'
  'Zone'
  'Geo'
  'GeoZone'
])
param sqlBackupStorageRedundancy string = 'Zone'

// ---------------------------------------------------------------------------------------------
// API Management
// ---------------------------------------------------------------------------------------------

@description('APIM SKU object: { name, capacity }.')
param apimSku object = {
  name: 'Developer'
  capacity: 1
}

@description('APIM availability zones (Premium only).')
param apimZones array = []

@description('APIM publisher e-mail.')
param apimPublisherEmail string

@description('APIM publisher name.')
param apimPublisherName string = 'Meridian Integration Platform'

@description('App Insights sampling percentage for APIM telemetry.')
@minValue(0)
@maxValue(100)
param apimSamplingPercentage int = 100

// ---------------------------------------------------------------------------------------------
// Derived values
// ---------------------------------------------------------------------------------------------

var baseName = '${namePrefix}-${workload}-${environmentName}'

var tags = {
  workload: workload
  environment: environmentName
  costCenter: costCenter
  owner: owner
  managedBy: 'bicep'
}

// Secret names are contracts between infra and the release pipelines; keep them in one place.
var secretNames = {
  logicAppContentShare: 'logicapp-content-share-connection'
  partnerOrdersCallbackSig: 'partner-orders-callback-sig'
}

var logicAppContentShareName = 'logicapp-content'

// ---------------------------------------------------------------------------------------------
// Modules
// ---------------------------------------------------------------------------------------------

module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    baseName: baseName
    location: location
    tags: tags
    addressSpace: vnetAddressSpace
    hubVnetId: hubVnetId
    firewallPrivateIp: firewallPrivateIp
  }
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    baseName: baseName
    location: location
    tags: tags
    logRetentionInDays: logRetentionInDays
    dailyQuotaGb: logDailyQuotaGb
    alertEmailReceivers: alertEmailReceivers
    actionGroupShortName: toUpper('${namePrefix}int-${environmentName}')
  }
}

module logicAppHostIdentity 'modules/identity.bicep' = {
  name: 'identity-la-host'
  params: {
    name: '${baseName}-id-la-host'
    location: location
    tags: tags
  }
}

module keyVault 'modules/keyvault.bicep' = {
  name: 'keyvault'
  params: {
    baseName: baseName
    location: location
    tags: tags
    peSubnetId: network.outputs.peSubnetId
    privateDnsZoneId: network.outputs.privateDnsZoneIds.keyvault
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    seedSecretNames: [
      secretNames.partnerOrdersCallbackSig
    ]
    vaultReaderPrincipalIds: [
      logicAppHostIdentity.outputs.principalId
    ]
  }
}

module logicAppStorage 'modules/storage.bicep' = {
  name: 'storage-la'
  params: {
    baseName: baseName
    roleSuffix: 'la'
    location: location
    tags: tags
    skuName: storageSkuName
    // Workflow Service Plan mounts Azure Files with a key; see storage.bicep for the reasoning.
    allowSharedKeyAccess: true
    fileShareName: logicAppContentShareName
    hostIdentityPrincipalIds: [
      logicAppHostIdentity.outputs.principalId
    ]
    peSubnetId: network.outputs.peSubnetId
    privateDnsZoneIds: network.outputs.privateDnsZoneIds
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
  }
}

module functionAppStorage 'modules/storage.bicep' = {
  name: 'storage-fa'
  params: {
    baseName: baseName
    roleSuffix: 'fa'
    location: location
    tags: tags
    skuName: storageSkuName
    allowSharedKeyAccess: false
    containerNames: [
      'poison-messages'
      'deployments'
    ]
    peSubnetId: network.outputs.peSubnetId
    privateDnsZoneIds: network.outputs.privateDnsZoneIds
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
  }
}

module logicAppContentShareSecret 'modules/storage-key-secret.bicep' = {
  name: 'secret-la-content-share'
  params: {
    storageAccountName: logicAppStorage.outputs.name
    keyVaultName: keyVault.outputs.name
    secretName: secretNames.logicAppContentShare
  }
}

module eventHubs 'modules/eventhubs.bicep' = {
  name: 'eventhubs'
  params: {
    baseName: baseName
    location: location
    tags: tags
    capacity: eventHubsCapacity
    maximumThroughputUnits: eventHubsMaximumThroughputUnits
    zoneRedundant: eventHubsZoneRedundant
    onPremProducerObjectId: onPremProducerObjectId
    peSubnetId: network.outputs.peSubnetId
    privateDnsZoneId: network.outputs.privateDnsZoneIds.servicebus
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
  }
}

module sql 'modules/sql.bicep' = {
  name: 'sql'
  params: {
    baseName: baseName
    location: location
    tags: tags
    entraAdminLogin: sqlEntraAdminLogin
    entraAdminObjectId: sqlEntraAdminObjectId
    databaseSku: sqlDatabaseSku
    autoPauseDelayMinutes: sqlAutoPauseDelayMinutes
    zoneRedundant: sqlZoneRedundant
    backupStorageRedundancy: sqlBackupStorageRedundancy
    peSubnetId: network.outputs.peSubnetId
    privateDnsZoneId: network.outputs.privateDnsZoneIds.sql
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
  }
}

module logicApp 'modules/logicapp.bicep' = {
  name: 'logicapp'
  params: {
    baseName: baseName
    location: location
    tags: tags
    planCapacity: appPlanCapacity
    zoneRedundant: appPlanZoneRedundant
    integrationSubnetId: network.outputs.logicAppSubnetId
    peSubnetId: network.outputs.peSubnetId
    privateDnsZoneId: network.outputs.privateDnsZoneIds.sites
    storageBlobEndpoint: logicAppStorage.outputs.blobEndpoint
    storageQueueEndpoint: logicAppStorage.outputs.queueEndpoint
    storageTableEndpoint: logicAppStorage.outputs.tableEndpoint
    hostIdentityId: logicAppHostIdentity.outputs.id
    contentShareName: logicAppContentShareName
    contentShareConnectionSecretUri: logicAppContentShareSecret.outputs.secretUri
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    eventHubsFullyQualifiedNamespace: eventHubs.outputs.fullyQualifiedNamespace
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
  }
}

module functionApp 'modules/functionapp.bicep' = {
  name: 'functionapp'
  params: {
    baseName: baseName
    location: location
    tags: tags
    planCapacity: appPlanCapacity
    zoneRedundant: appPlanZoneRedundant
    integrationSubnetId: network.outputs.functionAppSubnetId
    peSubnetId: network.outputs.peSubnetId
    privateDnsZoneId: network.outputs.privateDnsZoneIds.sites
    storageAccountName: functionAppStorage.outputs.name
    storageBlobEndpoint: functionAppStorage.outputs.blobEndpoint
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    eventHubsFullyQualifiedNamespace: eventHubs.outputs.fullyQualifiedNamespace
    sqlServerFqdn: sql.outputs.serverFqdn
    sqlDatabaseName: sql.outputs.databaseName
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
  }
}

module apim 'modules/apim.bicep' = {
  name: 'apim'
  params: {
    baseName: baseName
    location: location
    tags: tags
    sku: apimSku
    zones: apimZones
    publisherEmail: apimPublisherEmail
    publisherName: apimPublisherName
    apimSubnetId: network.outputs.apimSubnetId
    appInsightsId: monitoring.outputs.appInsightsId
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    keyVaultName: keyVault.outputs.name
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
  }
}

module apimApi 'modules/apim-api.bicep' = {
  name: 'apim-api-partner-orders'
  params: {
    apimName: apim.outputs.name
    appInsightsLoggerId: apim.outputs.appInsightsLoggerId
    samplingPercentage: apimSamplingPercentage
    backendHostName: logicApp.outputs.defaultHostName
    keyVaultUri: keyVault.outputs.vaultUri
    callbackSignatureSecretName: secretNames.partnerOrdersCallbackSig
  }
}

module rbac 'modules/rbac.bicep' = {
  name: 'rbac'
  params: {
    keyVaultName: keyVault.outputs.name
    eventHubNamespaceName: eventHubs.outputs.name
    functionAppStorageAccountName: functionAppStorage.outputs.name
    appInsightsName: monitoring.outputs.appInsightsName
    functionAppPrincipalId: functionApp.outputs.principalId
    logicAppPrincipalId: logicApp.outputs.principalId
  }
}

module alerts 'modules/alerts.bicep' = {
  name: 'alerts'
  params: {
    baseName: baseName
    location: location
    tags: tags
    actionGroupId: monitoring.outputs.actionGroupId
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    appInsightsId: monitoring.outputs.appInsightsId
    functionAppId: functionApp.outputs.id
    functionAppName: functionApp.outputs.name
    logicAppId: logicApp.outputs.id
    eventHubNamespaceId: eventHubs.outputs.id
    sqlDatabaseId: sql.outputs.databaseId
    apimId: apim.outputs.id
    keyVaultId: keyVault.outputs.id
    poisonStorageAccountName: functionAppStorage.outputs.name
    enableAvailabilityTest: enableAvailabilityTest
    apimGatewayUrl: apim.outputs.gatewayUrl
  }
}

// ---------------------------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------------------------

@description('Spoke VNet resource ID.')
output vnetId string = network.outputs.vnetId

@description('Log Analytics workspace resource ID.')
output logAnalyticsWorkspaceId string = monitoring.outputs.logAnalyticsWorkspaceId

@description('Application Insights resource ID.')
output appInsightsId string = monitoring.outputs.appInsightsId

@description('Key Vault name.')
output keyVaultName string = keyVault.outputs.name

@description('Event Hubs fully qualified namespace (Kafka bootstrap server is this host on port 9093).')
output eventHubsFullyQualifiedNamespace string = eventHubs.outputs.fullyQualifiedNamespace

@description('SQL logical server FQDN.')
output sqlServerFqdn string = sql.outputs.serverFqdn

@description('Logic App name.')
output logicAppName string = logicApp.outputs.name

@description('Function App name.')
output functionAppName string = functionApp.outputs.name

@description('Function App host storage account name (holds poison-messages and deployments).')
output functionAppStorageAccountName string = functionAppStorage.outputs.name

@description('API Management name.')
output apimName string = apim.outputs.name

@description('API Management internal gateway URL.')
output apimGatewayUrl string = apim.outputs.gatewayUrl
