// Host storage account for an App Service-based runtime (Function App or Logic App Standard).
// One account per app: the Functions host uses blob leases, queues and tables for coordination, and
// sharing an account between two hosts is a documented way to get cross-talk and lock contention.

@description('Base name, e.g. "mer-int-dev". Hyphens are stripped because storage names allow only lowercase alphanumerics.')
param baseName string

@description('Short role suffix identifying the consumer, e.g. "la" or "fa".')
@maxLength(4)
param roleSuffix string

@description('Azure region.')
param location string

@description('Resource tags.')
param tags object

@description('Replication SKU. Zone-redundant is the floor; geo-redundant in prod so run state survives a regional outage.')
@allowed([
  'Standard_ZRS'
  'Standard_GZRS'
  'Standard_RAGZRS'
])
param skuName string = 'Standard_ZRS'

@description('''Whether Shared Key (account key / SAS) access is allowed.
false for the Function App: Elastic Premium supports identity-based AzureWebJobsStorage and the app runs from a package blob, so no Azure Files share (which still needs a key) is involved.
true for Logic App Standard: the Workflow Service Plan mounts its content share over Azure Files, which does not support identity auth; keys cannot be disabled on that plan today.''')
param allowSharedKeyAccess bool = false

@description('Blob containers to create (e.g. poison-messages, deployments).')
param containerNames array = []

@description('Name of an Azure Files share to create for App Service content. Empty to skip.')
param fileShareName string = ''

@description('Object IDs of managed identities that must have data-plane access before the host starts (Logic App user-assigned identity). Function App system identity is granted in rbac.bicep after creation.')
param hostIdentityPrincipalIds array = []

@description('Subnet resource ID for the private endpoints (snet-pe).')
param peSubnetId string

@description('Private DNS zone IDs keyed by sub-resource: blob, file, queue, table.')
param privateDnsZoneIds object

@description('Log Analytics workspace resource ID for diagnostics.')
param logAnalyticsWorkspaceId string

// 3-24 lowercase alphanumerics: "merintprod" (10) + "fa" (2) + 10 unique = 22.
var storageAccountName = take('${replace(baseName, '-', '')}${roleSuffix}${uniqueString(resourceGroup().id)}', 24)

// The Functions/Logic Apps host needs all four: blobs for leases and secrets, queues for scheduling,
// tables for stateful workflow state, and account-level read for the host's capability discovery.
var hostRoleDefinitionIds = {
  storageAccountContributor: '17d1049b-9a84-46fb-8f53-869881c3d3ab'
  storageBlobDataOwner: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  storageQueueDataContributor: '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
  storageTableDataContributor: '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
}

var privateEndpointGroups = [
  'blob'
  'file'
  'queue'
  'table'
]

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: skuName
  }
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: allowSharedKeyAccess
    allowCrossTenantReplication: false
    defaultToOAuthAuthentication: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
    encryption: {
      keySource: 'Microsoft.Storage'
      requireInfrastructureEncryption: true
      services: {
        blob: { enabled: true, keyType: 'Account' }
        file: { enabled: true, keyType: 'Account' }
        queue: { enabled: true, keyType: 'Account' }
        table: { enabled: true, keyType: 'Account' }
      }
    }
  }
}

resource blobServices 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    // Soft delete covers the "someone purged poison-messages before we replayed them" scenario.
    deleteRetentionPolicy: { enabled: true, days: 14 }
    containerDeleteRetentionPolicy: { enabled: true, days: 14 }
  }
}

resource containers 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' = [
  for containerName in containerNames: {
    parent: blobServices
    name: containerName
    properties: {
      publicAccess: 'None'
    }
  }
]

resource fileServices 'Microsoft.Storage/storageAccounts/fileServices@2025-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    shareDeleteRetentionPolicy: { enabled: true, days: 14 }
  }
}

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2025-01-01' = if (!empty(fileShareName)) {
  parent: fileServices
  name: fileShareName
  properties: {
    accessTier: 'TransactionOptimized'
  }
}

resource hostRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for pair in flatten(map(hostIdentityPrincipalIds, principalId => map(items(hostRoleDefinitionIds), role => { principalId: principalId, roleId: role.value }))): {
    name: guid(storageAccount.id, pair.principalId, pair.roleId)
    scope: storageAccount
    properties: {
      principalId: pair.principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', pair.roleId)
    }
  }
]

module privateEndpoints 'private-endpoint.bicep' = [
  for groupId in privateEndpointGroups: {
    name: 'pe-${storageAccountName}-${groupId}'
    params: {
      name: '${baseName}-pe-st${roleSuffix}-${groupId}'
      location: location
      tags: tags
      subnetId: peSubnetId
      privateLinkServiceId: storageAccount.id
      groupId: groupId
      privateDnsZoneId: privateDnsZoneIds[groupId]
    }
  }
]

// Account-level: metrics only (the account has no log categories).
// 2021-05-01-preview is the only diagnostic-settings API with categoryGroup support; the GA 2016-09-01 lacks it.
#disable-next-line use-recent-api-versions
resource accountDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-law'
  scope: storageAccount
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    metrics: [
      { category: 'Transaction', enabled: true }
    ]
  }
}

// Blob-level: StorageBlobLogs feeds the poison-message alert in alerts.bicep.
// 2021-05-01-preview is the only diagnostic-settings API with categoryGroup support; the GA 2016-09-01 lacks it.
#disable-next-line use-recent-api-versions
resource blobDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-law'
  scope: blobServices
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { categoryGroup: 'allLogs', enabled: true }
    ]
    metrics: [
      { category: 'Transaction', enabled: true }
    ]
  }
}

// 2021-05-01-preview is the only diagnostic-settings API with categoryGroup support; the GA 2016-09-01 lacks it.
#disable-next-line use-recent-api-versions
resource queueDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-law'
  scope: queueServices
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { categoryGroup: 'allLogs', enabled: true }
    ]
  }
}

resource queueServices 'Microsoft.Storage/storageAccounts/queueServices@2025-01-01' existing = {
  parent: storageAccount
  name: 'default'
}

@description('Resource ID of the storage account.')
output id string = storageAccount.id

@description('Name of the storage account.')
output name string = storageAccount.name

@description('Primary blob endpoint, e.g. https://name.blob.core.windows.net/.')
output blobEndpoint string = storageAccount.properties.primaryEndpoints.blob

@description('Primary queue endpoint.')
output queueEndpoint string = storageAccount.properties.primaryEndpoints.queue

@description('Primary table endpoint.')
output tableEndpoint string = storageAccount.properties.primaryEndpoints.table
