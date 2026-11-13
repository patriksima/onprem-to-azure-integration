// Logic App Standard that hosts the partner-facing orchestration workflows (receives the APIM-fronted
// partner order, enriches it from Event Hubs state, calls the Function App). Single-tenant so it can
// sit in the VNet and talk to private endpoints only.
// Hand-written on purpose (ADR-009): the site configuration below *is* the design — identity-based host
// storage plus a Key Vault reference for the one share that still needs a key — so the site is a raw
// resource. The plan and the private endpoint come from AVM. AVM's web/site was considered and not used:
// it would save about ten lines of plumbing, but it compiles to ~680 KB per instance (slots, extensions
// and config children) and puts the site one nested deployment deeper in what-if output, which is
// exactly where a reviewer wants to see the app settings side by side with the raw resource.

@description('Base name, e.g. "mer-int-dev".')
param baseName string

@description('Azure region.')
param location string

@description('Resource tags.')
param tags object

@description('Plan instance count. Three in prod so zone redundancy has one instance per zone.')
@minValue(1)
@maxValue(20)
param planCapacity int = 1

@description('Zone-redundant plan (requires planCapacity >= 3).')
param zoneRedundant bool = false

@description('Subnet resource ID for regional VNet integration (snet-la, delegated to Microsoft.Web/serverFarms).')
param integrationSubnetId string

@description('Subnet resource ID for the inbound private endpoint (snet-pe).')
param peSubnetId string

@description('Resource ID of the privatelink.azurewebsites.net zone.')
param privateDnsZoneId string

@description('Blob service endpoint of the host storage account.')
param storageBlobEndpoint string

@description('Queue service endpoint of the host storage account.')
param storageQueueEndpoint string

@description('Table service endpoint of the host storage account.')
param storageTableEndpoint string

@description('Resource ID of the user-assigned identity that the host uses for storage and Key Vault references.')
param hostIdentityId string

@description('Name of the Azure Files share that holds the deployed workflow content.')
param contentShareName string

@description('Key Vault secret URI (versionless) holding the content-share connection string.')
param contentShareConnectionSecretUri string

@description('Application Insights connection string.')
param appInsightsConnectionString string

@description('Fully qualified Event Hubs namespace, consumed by the built-in Event Hubs connector through connections.json.')
param eventHubsFullyQualifiedNamespace string

@description('Log Analytics workspace resource ID for diagnostics.')
param logAnalyticsWorkspaceId string

var planName = '${baseName}-asp-la'
var appName = '${baseName}-la'

module plan 'br/public:avm/res/web/serverfarm:0.7.0' = {
  name: 'asp-la'
  params: {
    name: planName
    location: location
    tags: tags
    kind: 'elastic'
    skuName: 'WS1'
    skuCapacity: planCapacity
    // Logic Apps Standard runs on Windows plans only.
    reserved: false
    maximumElasticWorkerCount: 20
    zoneRedundant: zoneRedundant
  }
}

resource logicApp 'Microsoft.Web/sites@2025-03-01' = {
  name: appName
  location: location
  tags: tags
  kind: 'functionapp,workflowapp'
  identity: {
    // System-assigned: used by workflows for Event Hubs, Key Vault, App Insights.
    // User-assigned: used by the host itself for storage and Key Vault references, because it must
    // hold roles before the app exists.
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${hostIdentityId}': {}
    }
  }
  properties: {
    serverFarmId: plan.outputs.resourceId
    httpsOnly: true
    publicNetworkAccess: 'Disabled'
    virtualNetworkSubnetId: integrationSubnetId
    // allTraffic: egress goes through the VNet (hub firewall, private DNS).
    // contentShareTraffic: the Azure Files share is behind a private endpoint, so the mount itself
    // must travel over the VNet as well (the WEBSITE_CONTENTOVERVNET app setting is the legacy knob).
    outboundVnetRouting: {
      allTraffic: true
      contentShareTraffic: true
    }
    keyVaultReferenceIdentity: hostIdentityId
    clientAffinityEnabled: false
    siteConfig: {
      netFrameworkVersion: 'v8.0'
      use32BitWorkerProcess: false
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      http20Enabled: true
      remoteDebuggingEnabled: false
      // Runtime scale monitoring is what lets the scale controller see Event Hubs behind a private
      // endpoint (it runs inside the VNet-integrated host instead of from the shared controller).
      functionsRuntimeScaleMonitoringEnabled: true
      appSettings: [
        { name: 'APP_KIND', value: 'workflowApp' }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'dotnet' }
        { name: 'AzureFunctionsJobHost__extensionBundle__id', value: 'Microsoft.Azure.Functions.ExtensionBundle.Workflows' }
        { name: 'AzureFunctionsJobHost__extensionBundle__version', value: '[1.*, 2.0.0)' }
        // Identity-based host storage, service-URI form as documented for Logic Apps Standard.
        { name: 'AzureWebJobsStorage__blobServiceUri', value: storageBlobEndpoint }
        { name: 'AzureWebJobsStorage__queueServiceUri', value: storageQueueEndpoint }
        { name: 'AzureWebJobsStorage__tableServiceUri', value: storageTableEndpoint }
        { name: 'AzureWebJobsStorage__credential', value: 'managedIdentity' }
        { name: 'AzureWebJobsStorage__managedIdentityResourceId', value: hostIdentityId }
        // Azure Files content share: the only place a key survives, and it stays in Key Vault.
        { name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING', value: '@Microsoft.KeyVault(SecretUri=${contentShareConnectionSecretUri})' }
        { name: 'WEBSITE_CONTENTSHARE', value: contentShareName }
        { name: 'WEBSITE_CONTENTOVERVNET', value: '1' }
        // Required whenever the content-share connection string is a Key Vault reference.
        { name: 'WEBSITE_SKIP_CONTENTSHARE_VALIDATION', value: '1' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
        { name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING', value: 'Authorization=AAD' }
        // Referenced from connections.json as @appsetting('EVENTHUBS_FULLYQUALIFIEDNAMESPACE').
        { name: 'EVENTHUBS_FULLYQUALIFIEDNAMESPACE', value: eventHubsFullyQualifiedNamespace }
      ]
    }
  }
}

// Same shape as conventions.bicep#privateEndpointFor, spelled out because the standalone module takes the
// connection explicitly instead of deriving it from a parent resource.
module privateEndpoint 'br/public:avm/res/network/private-endpoint:0.12.1' = {
  name: 'pe-la'
  params: {
    name: '${baseName}-pe-la'
    location: location
    tags: tags
    subnetResourceId: peSubnetId
    customNetworkInterfaceName: '${baseName}-pe-la-nic'
    privateLinkServiceConnections: [
      {
        name: '${baseName}-pe-la'
        properties: {
          privateLinkServiceId: logicApp.id
          groupIds: [ 'sites' ]
        }
      }
    ]
    privateDnsZoneGroup: {
      name: 'default'
      privateDnsZoneGroupConfigs: [
        {
          name: 'sites'
          privateDnsZoneResourceId: privateDnsZoneId
        }
      ]
    }
  }
}

// 2021-05-01-preview is the only diagnostic-settings API with categoryGroup support; the GA 2016-09-01 lacks it.
#disable-next-line use-recent-api-versions
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-law'
  scope: logicApp
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      // WorkflowRuntime is the per-run/per-action log stream; FunctionAppLogs is the host itself.
      { category: 'WorkflowRuntime', enabled: true }
      { category: 'FunctionAppLogs', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

@description('Resource ID of the Logic App.')
output id string = logicApp.id

@description('Name of the Logic App.')
output name string = logicApp.name

@description('Object ID of the system-assigned identity.')
output principalId string = logicApp.identity.principalId

@description('Default hostname, e.g. mer-int-dev-la.azurewebsites.net. Resolves to the private endpoint from inside the VNet.')
output defaultHostName string = logicApp.properties.defaultHostName
