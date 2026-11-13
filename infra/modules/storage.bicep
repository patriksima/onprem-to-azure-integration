// Host storage account for an App Service-based runtime (Function App or Logic App Standard).
// One account per app: the Functions host uses blob leases, queues and tables for coordination, and
// sharing an account between two hosts is a documented way to get cross-talk and lock contention.
// The account comes from AVM; the key decision here is allowSharedKeyAccess (see below).

import { privateEndpointFor, diagnosticsToLaw, roleAssignmentFor } from 'conventions.bicep'

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

@description('''Key Vault that receives the account connection string, as { keyVaultResourceId, secretName }. Empty to skip.
Needed only for the Logic App Standard content share: Azure Files has no identity-based auth, so WEBSITE_CONTENTAZUREFILECONNECTIONSTRING must be a real connection string. Writing it straight into Key Vault (the AVM module reads the key with listKeys() inside the deployment) and referencing it from the app keeps the key out of app settings, parameters and deployment history.''')
param connectionStringExport object = {}

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
var hostRoleDefinitionIds = [
  '17d1049b-9a84-46fb-8f53-869881c3d3ab' // Storage Account Contributor
  'b7e6dc6d-f1e8-4753-8033-0f276bb0955b' // Storage Blob Data Owner
  '974c5e8b-45b9-4653-ba55-5f855dd0fb88' // Storage Queue Data Contributor
  '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3' // Storage Table Data Contributor
]

var privateEndpointGroups = [
  'blob'
  'file'
  'queue'
  'table'
]

var exportConnectionString = !empty(connectionStringExport)

module storageAccount 'br/public:avm/res/storage/storage-account:0.33.1' = {
  name: 'st-${roleSuffix}'
  params: {
    name: storageAccountName
    location: location
    tags: tags
    kind: 'StorageV2'
    skuName: skuName
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
    requireInfrastructureEncryption: true
    blobServices: {
      // Soft delete covers the "someone purged poison-messages before we replayed them" scenario.
      deleteRetentionPolicyEnabled: true
      deleteRetentionPolicyDays: 14
      containerDeleteRetentionPolicyEnabled: true
      containerDeleteRetentionPolicyDays: 14
      containers: [
        for containerName in containerNames: {
          name: containerName
          publicAccess: 'None'
        }
      ]
      // Blob-level: StorageBlobLogs feeds the poison-message alert in alerts-log.bicep.
      diagnosticSettings: [
        diagnosticsToLaw(logAnalyticsWorkspaceId, [{ categoryGroup: 'allLogs' }], [{ category: 'Transaction' }])
      ]
    }
    fileServices: {
      shareDeleteRetentionPolicy: {
        enabled: true
        days: 14
      }
      shares: empty(fileShareName)
        ? []
        : [
            {
              name: fileShareName
              accessTier: 'TransactionOptimized'
            }
          ]
    }
    queueServices: {
      diagnosticSettings: [
        diagnosticsToLaw(logAnalyticsWorkspaceId, [{ categoryGroup: 'allLogs' }], [])
      ]
    }
    roleAssignments: [
      for pair in flatten(map(hostIdentityPrincipalIds, principalId => map(hostRoleDefinitionIds, roleId => { principalId: principalId, roleId: roleId }))): roleAssignmentFor(pair.principalId, pair.roleId)
    ]
    privateEndpoints: [
      for groupId in privateEndpointGroups: privateEndpointFor('${baseName}-pe-st${roleSuffix}-${groupId}', peSubnetId, groupId, privateDnsZoneIds[groupId], location, tags)
    ]
    // Account-level: metrics only (the account has no log categories).
    diagnosticSettings: [
      diagnosticsToLaw(logAnalyticsWorkspaceId, [], [{ category: 'Transaction' }])
    ]
    secretsExportConfiguration: exportConnectionString
      ? {
          keyVaultResourceId: connectionStringExport.keyVaultResourceId
          connectionString1Name: connectionStringExport.secretName
        }
      : null
  }
}

@description('Resource ID of the storage account.')
output id string = storageAccount.outputs.resourceId

@description('Name of the storage account.')
output name string = storageAccount.outputs.name

@description('Primary blob endpoint, e.g. https://name.blob.core.windows.net/.')
output blobEndpoint string = storageAccount.outputs.serviceEndpoints.blob

@description('Primary queue endpoint.')
output queueEndpoint string = storageAccount.outputs.serviceEndpoints.queue

@description('Primary table endpoint.')
output tableEndpoint string = storageAccount.outputs.serviceEndpoints.table

@description('Versionless URI of the connection-string secret (for Key Vault references that follow rotation), or empty when no secret was requested.')
output connectionStringSecretUri string = exportConnectionString ? storageAccount.outputs.exportedSecrets[connectionStringExport.secretName].secretUri : ''
