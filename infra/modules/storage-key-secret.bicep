// Writes a storage connection string into Key Vault.
// Needed only for the Logic App Standard content share: Azure Files has no identity-based auth, so
// WEBSITE_CONTENTAZUREFILECONNECTIONSTRING must be a real connection string. Putting it in Key Vault
// and referencing it from the app keeps the key out of app settings, parameters and deployment history.

@description('Name of the storage account whose key is stored.')
param storageAccountName string

@description('Name of the Key Vault that receives the secret.')
param keyVaultName string

@description('Name of the secret.')
param secretName string

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: storageAccountName
}

resource keyVault 'Microsoft.KeyVault/vaults@2025-05-01' existing = {
  name: keyVaultName
}

resource secret 'Microsoft.KeyVault/vaults/secrets@2025-05-01' = {
  parent: keyVault
  name: secretName
  properties: {
    contentType: 'storage-connection-string'
    value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
  }
}

@description('Secret URI without version, for Key Vault references that should follow rotation.')
output secretUri string = secret.properties.secretUri
