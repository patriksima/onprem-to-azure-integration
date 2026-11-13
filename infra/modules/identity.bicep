// User-assigned identity for the Logic App host.
// The Logic App's own system-assigned identity cannot exist before the app does, but the host needs
// storage data-plane roles at first start. A user-assigned identity breaks that chicken-and-egg:
// it is created first, granted roles, and then attached to the app.

@description('Name of the user-assigned managed identity.')
param name string

@description('Azure region.')
param location string

@description('Resource tags.')
param tags object

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: name
  location: location
  tags: tags
}

@description('Resource ID of the identity.')
output id string = identity.id

@description('Object (principal) ID of the identity, used in role assignments.')
output principalId string = identity.properties.principalId

@description('Client ID of the identity, used in app settings that select which identity to use.')
output clientId string = identity.properties.clientId
