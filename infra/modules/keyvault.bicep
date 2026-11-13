// Key Vault for the few secrets this workload cannot avoid (Logic App callback signature, the
// Logic App content-share connection string). Access is RBAC-only and data-plane traffic enters
// through a private endpoint.

@description('Base name used for naming, e.g. "mer-int-dev". A unique suffix is appended because vault names are global.')
param baseName string

@description('Azure region.')
param location string

@description('Resource tags.')
param tags object

@description('Subnet resource ID for the private endpoint (snet-pe).')
param peSubnetId string

@description('Resource ID of the privatelink.vaultcore.azure.net zone.')
param privateDnsZoneId string

@description('Log Analytics workspace resource ID for diagnostics.')
param logAnalyticsWorkspaceId string

@description('Secret names to pre-create with a placeholder value so Key Vault references resolve on first deployment. Real values are written by the application release pipeline.')
param seedSecretNames array = []

@description('Placeholder written into each seed secret. Secure + newGuid() so no literal ever appears in template or deployment history; the release pipeline replaces it.')
@secure()
param seedSecretPlaceholder string = newGuid()

@description('Object IDs that need Key Vault Secrets User before the apps exist (the Logic App host identity resolves Key Vault references at start-up). App system identities are granted in rbac.bicep.')
param vaultReaderPrincipalIds array = []

var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

// Vault names: 3-24 chars, globally unique. "mer-int-prod-kv-" is 16 chars, leaving room for 6 unique chars.
var keyVaultName = '${baseName}-kv-${take(uniqueString(resourceGroup().id), 6)}'

resource keyVault 'Microsoft.KeyVault/vaults@2025-05-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    // RBAC instead of access policies: role assignments are auditable, scoped and live in the same
    // Bicep as everything else; access policies silently drift through the portal.
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    // Purge protection is irreversible by design: nobody, including an attacker with Owner, can
    // destroy secrets ahead of the retention window.
    enablePurgeProtection: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      // ARM template deployment of secrets is on the trusted-services list; without this bypass the
      // seed secrets below cannot be written from a pipeline that is outside the VNet.
      bypass: 'AzureServices'
    }
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: false
  }
}

// Placeholders let APIM named values and App Service Key Vault references resolve at first deploy.
// The release pipeline overwrites them; contentType marks them as not-yet-real.
resource seedSecrets 'Microsoft.KeyVault/vaults/secrets@2025-05-01' = [
  for secretName in seedSecretNames: {
    parent: keyVault
    name: secretName
    properties: {
      value: seedSecretPlaceholder
      contentType: 'placeholder'
    }
  }
]

resource secretsUserRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in vaultReaderPrincipalIds: {
    name: guid(keyVault.id, principalId, keyVaultSecretsUserRoleId)
    scope: keyVault
    properties: {
      principalId: principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    }
  }
]

module privateEndpoint 'private-endpoint.bicep' = {
  name: 'pe-${keyVaultName}'
  params: {
    name: '${baseName}-pe-kv'
    location: location
    tags: tags
    subnetId: peSubnetId
    privateLinkServiceId: keyVault.id
    groupId: 'vault'
    privateDnsZoneId: privateDnsZoneId
  }
}

// 2021-05-01-preview is the only diagnostic-settings API with categoryGroup support; the GA 2016-09-01 lacks it.
#disable-next-line use-recent-api-versions
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-law'
  scope: keyVault
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

@description('Resource ID of the Key Vault.')
output id string = keyVault.id

@description('Name of the Key Vault.')
output name string = keyVault.name

@description('Vault URI, used for Key Vault references in app settings.')
output vaultUri string = keyVault.properties.vaultUri
