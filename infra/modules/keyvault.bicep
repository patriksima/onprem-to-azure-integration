// Key Vault for the few secrets this workload cannot avoid (Logic App callback signature, the
// Logic App content-share connection string). Access is RBAC-only and data-plane traffic enters
// through a private endpoint. The vault comes from AVM; the hardening choices below are ours.

import { privateEndpointFor, diagnosticsToLaw, roleAssignmentFor } from 'conventions.bicep'

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

module keyVault 'br/public:avm/res/key-vault/vault:0.14.2' = {
  name: 'kv'
  params: {
    name: keyVaultName
    location: location
    tags: tags
    sku: 'standard'
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
    enableVaultForDeployment: false
    enableVaultForDiskEncryption: false
    enableVaultForTemplateDeployment: false
    // Placeholders let APIM named values and App Service Key Vault references resolve at first deploy.
    // The release pipeline overwrites them; contentType marks them as not-yet-real.
    secrets: [
      for secretName in seedSecretNames: {
        name: secretName
        value: seedSecretPlaceholder
        contentType: 'placeholder'
      }
    ]
    roleAssignments: [
      for principalId in vaultReaderPrincipalIds: roleAssignmentFor(principalId, keyVaultSecretsUserRoleId)
    ]
    privateEndpoints: [
      privateEndpointFor('${baseName}-pe-kv', peSubnetId, 'vault', privateDnsZoneId, location, tags)
    ]
    diagnosticSettings: [
      diagnosticsToLaw(logAnalyticsWorkspaceId, [], [])
    ]
  }
}

@description('Resource ID of the Key Vault.')
output id string = keyVault.outputs.resourceId

@description('Name of the Key Vault.')
output name string = keyVault.outputs.name

@description('Vault URI, used for Key Vault references in app settings.')
// Derived from the name and the cloud's Key Vault DNS suffix (see sql.bicep for why).
output vaultUri string = 'https://${keyVault.outputs.name}${environment().suffixes.keyvaultDns}/'
