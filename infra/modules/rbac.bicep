// Role assignments for the application identities that only exist after the apps are deployed.
// Everything here is least-privilege data-plane access; no identity gets a control-plane role.
//
// Not in this file on purpose:
//   - Logic App host (user-assigned) identity -> storage + Key Vault: granted before the app exists
//     (storage.bicep / keyvault.bicep) because the host needs them to start.
//   - APIM -> Key Vault / App Insights: granted in apim.bicep next to the resources that consume them.
//   - Logic App -> Function App: HTTPS call over the private endpoint with function keys or Easy Auth;
//     no Azure RBAC role is involved.

@description('Name of the Key Vault.')
param keyVaultName string

@description('Name of the Event Hubs namespace.')
param eventHubNamespaceName string

@description('Name of the Function App host storage account.')
param functionAppStorageAccountName string

@description('Name of the Application Insights component.')
param appInsightsName string

@description('Object ID of the Function App system-assigned identity.')
param functionAppPrincipalId string

@description('Object ID of the Logic App system-assigned identity.')
param logicAppPrincipalId string

var roles = {
  keyVaultSecretsUser: '4633458b-17de-408a-b874-0445c86b69e6'
  eventHubsDataReceiver: 'a638d3c7-ab3a-418d-83e6-5f17a39d4fde'
  eventHubsDataSender: '2b629674-e913-4c01-ae53-ef4638d8f975'
  monitoringMetricsPublisher: '3913510d-42f4-4e42-8a64-420c390055eb'
  storageAccountContributor: '17d1049b-9a84-46fb-8f53-869881c3d3ab'
  storageBlobDataOwner: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  storageQueueDataContributor: '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
  storageTableDataContributor: '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
}

var appPrincipalIds = [
  functionAppPrincipalId
  logicAppPrincipalId
]

// Both apps: read secrets, consume events, push telemetry with Entra auth.
var sharedRoleIds = [
  roles.keyVaultSecretsUser
  roles.eventHubsDataReceiver
  roles.monitoringMetricsPublisher
]

// Function App host storage (identity-based AzureWebJobsStorage + run-from-package blob).
var functionAppStorageRoleIds = [
  roles.storageAccountContributor
  roles.storageBlobDataOwner
  roles.storageQueueDataContributor
  roles.storageTableDataContributor
]

resource keyVault 'Microsoft.KeyVault/vaults@2025-05-01' existing = {
  name: keyVaultName
}

resource eventHubNamespace 'Microsoft.EventHub/namespaces@2026-01-01' existing = {
  name: eventHubNamespaceName
}

resource functionAppStorage 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: functionAppStorageAccountName
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

resource keyVaultRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in appPrincipalIds: {
    name: guid(keyVault.id, principalId, roles.keyVaultSecretsUser)
    scope: keyVault
    properties: {
      principalId: principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.keyVaultSecretsUser)
    }
  }
]

resource eventHubsReceiverRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in appPrincipalIds: {
    name: guid(eventHubNamespace.id, principalId, roles.eventHubsDataReceiver)
    scope: eventHubNamespace
    properties: {
      principalId: principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.eventHubsDataReceiver)
    }
  }
]

// The Logic App also publishes enriched events back (partner-sync fan-out), so it needs Sender too.
resource logicAppSenderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(eventHubNamespace.id, logicAppPrincipalId, roles.eventHubsDataSender)
  scope: eventHubNamespace
  properties: {
    principalId: logicAppPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.eventHubsDataSender)
  }
}

resource metricsPublisherRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in appPrincipalIds: {
    name: guid(appInsights.id, principalId, roles.monitoringMetricsPublisher)
    scope: appInsights
    properties: {
      principalId: principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.monitoringMetricsPublisher)
    }
  }
]

resource functionAppStorageRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for roleId in functionAppStorageRoleIds: {
    name: guid(functionAppStorage.id, functionAppPrincipalId, roleId)
    scope: functionAppStorage
    properties: {
      principalId: functionAppPrincipalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleId)
    }
  }
]

@description('Number of role assignments created, for deployment output readability.')
output roleAssignmentCount int = length(appPrincipalIds) * length(sharedRoleIds) + length(functionAppStorageRoleIds) + 1
