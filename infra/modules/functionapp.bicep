// Function App (.NET 10 isolated, Linux, Elastic Premium) that consumes the Event Hubs streams and
// projects them into the crm-reporting database. Elastic Premium rather than Flex Consumption because
// the workload needs regional VNet integration *and* a Windows-free runtime with predictable warm
// instances; the trade-off is the storage-key workaround explained below.
// Hand-written on purpose (ADR-009): the site configuration below *is* the design — a keyless,
// run-from-package host — so the site is a raw resource. The plan and the private endpoint come from AVM;
// see logicapp.bicep for why AVM's web/site is not used.

@description('Base name, e.g. "mer-int-dev".')
param baseName string

@description('Azure region.')
param location string

@description('Resource tags.')
param tags object

@description('Always-ready instance count. Three in prod so zone redundancy has one instance per zone.')
@minValue(1)
@maxValue(20)
param planCapacity int = 1

@description('Zone-redundant plan (requires planCapacity >= 3).')
param zoneRedundant bool = false

@description('Maximum burst instance count for the Elastic Premium plan.')
@minValue(1)
@maxValue(100)
param maximumElasticWorkerCount int = 10

@description('Subnet resource ID for regional VNet integration (snet-fa, delegated to Microsoft.Web/serverFarms).')
param integrationSubnetId string

@description('Subnet resource ID for the inbound private endpoint (snet-pe).')
param peSubnetId string

@description('Resource ID of the privatelink.azurewebsites.net zone.')
param privateDnsZoneId string

@description('Name of the host storage account (identity-based AzureWebJobsStorage).')
param storageAccountName string

@description('Blob service endpoint of the host storage account, used to build the run-from-package URL.')
param storageBlobEndpoint string

@description('Blob container that holds the deployment package.')
param deploymentContainerName string = 'deployments'

@description('Application Insights connection string.')
param appInsightsConnectionString string

@description('Fully qualified Event Hubs namespace for the Event Hubs trigger (identity-based connection).')
param eventHubsFullyQualifiedNamespace string

@description('Fully qualified domain name of the SQL logical server.')
param sqlServerFqdn string

@description('Name of the reporting database.')
param sqlDatabaseName string

@description('Log Analytics workspace resource ID for diagnostics.')
param logAnalyticsWorkspaceId string

var planName = '${baseName}-asp-fa'
var appName = '${baseName}-fa'

module plan 'br/public:avm/res/web/serverfarm:0.7.0' = {
  name: 'asp-fa'
  params: {
    name: planName
    location: location
    tags: tags
    kind: 'elastic'
    skuName: 'EP1'
    skuCapacity: planCapacity
    reserved: true
    maximumElasticWorkerCount: maximumElasticWorkerCount
    zoneRedundant: zoneRedundant
  }
}

resource functionApp 'Microsoft.Web/sites@2025-03-01' = {
  name: appName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.outputs.resourceId
    httpsOnly: true
    publicNetworkAccess: 'Disabled'
    virtualNetworkSubnetId: integrationSubnetId
    // Route all egress through the VNet so the hub firewall sees it and private DNS resolves.
    outboundVnetRouting: {
      allTraffic: true
    }
    clientAffinityEnabled: false
    siteConfig: {
      linuxFxVersion: 'DOTNET-ISOLATED|10.0'
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      http20Enabled: true
      remoteDebuggingEnabled: false
      healthCheckPath: '/api/health'
      minimumElasticInstanceCount: planCapacity
      functionsRuntimeScaleMonitoringEnabled: true
      appSettings: [
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'dotnet-isolated' }
        // Identity-based host storage: the host authenticates with its system-assigned identity, so
        // there is no AzureWebJobsStorage connection string. Roles are granted in rbac.bicep.
        { name: 'AzureWebJobsStorage__accountName', value: storageAccountName }
        // No WEBSITE_CONTENTAZUREFILECONNECTIONSTRING / WEBSITE_CONTENTSHARE on purpose: Azure Files
        // needs an account key. The app runs from a package blob that the identity can read instead,
        // which is the documented way to run Elastic Premium without a share and without keys.
        { name: 'WEBSITE_RUN_FROM_PACKAGE', value: '${storageBlobEndpoint}${deploymentContainerName}/functionapp.zip' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
        { name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING', value: 'Authorization=AAD' }
        // Event Hubs trigger: "EventHubsConnection" is the connection name in function.json/attributes;
        // the __fullyQualifiedNamespace suffix switches the extension to identity-based auth.
        { name: 'EventHubsConnection__fullyQualifiedNamespace', value: eventHubsFullyQualifiedNamespace }
        // Entra-only SQL: no user, no password; the token comes from the managed identity.
        { name: 'SqlConnectionString', value: 'Server=tcp:${sqlServerFqdn},1433;Database=${sqlDatabaseName};Authentication=Active Directory Managed Identity;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;' }
        { name: 'WEBSITE_ENABLE_SYNC_UPDATE_SITE', value: 'true' }
      ]
    }
  }
}

// Same shape as conventions.bicep#privateEndpointFor, spelled out because the standalone module takes the
// connection explicitly instead of deriving it from a parent resource.
module privateEndpoint 'br/public:avm/res/network/private-endpoint:0.12.1' = {
  name: 'pe-fa'
  params: {
    name: '${baseName}-pe-fa'
    location: location
    tags: tags
    subnetResourceId: peSubnetId
    customNetworkInterfaceName: '${baseName}-pe-fa-nic'
    privateLinkServiceConnections: [
      {
        name: '${baseName}-pe-fa'
        properties: {
          privateLinkServiceId: functionApp.id
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
  scope: functionApp
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { category: 'FunctionAppLogs', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

@description('Resource ID of the Function App.')
output id string = functionApp.id

@description('Name of the Function App.')
output name string = functionApp.name

@description('Object ID of the system-assigned identity.')
output principalId string = functionApp.identity.principalId

@description('Default hostname. Resolves to the private endpoint from inside the VNet.')
output defaultHostName string = functionApp.properties.defaultHostName
