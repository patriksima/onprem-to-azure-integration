// API Management instance, internal VNet mode. Partners reach it through the hub (ExpressRoute/VPN or
// a WAF in front - out of scope here); nothing is exposed to the public internet. The API itself is
// defined in apim-api.bicep so this file stays about the platform.

@description('Base name, e.g. "mer-int-dev".')
param baseName string

@description('Azure region.')
param location string

@description('Resource tags.')
param tags object

@description('SKU object: { name: "Developer" | "Premium", capacity: int }. Developer has no SLA and is for dev only.')
param sku object = {
  name: 'Developer'
  capacity: 1
}

@description('Availability zones for Premium (e.g. ["1","2","3"]). Capacity must be >= the number of zones. Empty for Developer.')
param zones array = []

@description('Publisher e-mail shown in the developer portal and used for platform notifications.')
param publisherEmail string

@description('Publisher / organisation name.')
param publisherName string

@description('Subnet resource ID for VNet injection (snet-apim).')
param apimSubnetId string

@description('Resource ID of the Application Insights component used for request telemetry.')
param appInsightsId string

@description('Application Insights connection string.')
param appInsightsConnectionString string

@description('Name of the Key Vault holding secret named values.')
param keyVaultName string

@description('Log Analytics workspace resource ID for diagnostics.')
param logAnalyticsWorkspaceId string

var apimName = '${baseName}-apim'

var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'

// Only TLS 1.2+ with forward-secret, AEAD ciphers on both the client and backend side.
var securityProtocolBase = 'Microsoft.WindowsAzure.ApiManagement.Gateway.Security'
var customProperties = {
  '${securityProtocolBase}.Protocols.Tls10': 'False'
  '${securityProtocolBase}.Protocols.Tls11': 'False'
  '${securityProtocolBase}.Protocols.Ssl30': 'False'
  '${securityProtocolBase}.Backend.Protocols.Tls10': 'False'
  '${securityProtocolBase}.Backend.Protocols.Tls11': 'False'
  '${securityProtocolBase}.Backend.Protocols.Ssl30': 'False'
  '${securityProtocolBase}.Ciphers.TripleDes168': 'False'
  '${securityProtocolBase}.Ciphers.TLS_RSA_WITH_AES_128_CBC_SHA': 'False'
  '${securityProtocolBase}.Ciphers.TLS_RSA_WITH_AES_256_CBC_SHA': 'False'
  '${securityProtocolBase}.Ciphers.TLS_RSA_WITH_AES_128_CBC_SHA256': 'False'
  '${securityProtocolBase}.Ciphers.TLS_RSA_WITH_AES_256_CBC_SHA256': 'False'
  '${securityProtocolBase}.Ciphers.TLS_RSA_WITH_AES_128_GCM_SHA256': 'False'
  '${securityProtocolBase}.Ciphers.TLS_RSA_WITH_AES_256_GCM_SHA384': 'False'
  '${securityProtocolBase}.Ciphers.TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA': 'False'
  '${securityProtocolBase}.Ciphers.TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA': 'False'
  'Microsoft.WindowsAzure.ApiManagement.Gateway.Protocols.Server.Http2': 'True'
}

resource keyVault 'Microsoft.KeyVault/vaults@2025-05-01' existing = {
  name: keyVaultName
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: last(split(appInsightsId, '/'))
}

// The stv2 platform requires a public IP even in internal mode: it is used only for management
// traffic from the APIM control plane, never for API traffic.
resource managementPublicIp 'Microsoft.Network/publicIPAddresses@2025-05-01' = {
  name: '${apimName}-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  // Zone-redundant Standard IPs cost the same as zonal ones, so the IP is always zone-redundant
  // even when the gateway itself is not (Developer tier, or Premium with one unit).
  zones: [ '1', '2', '3' ]
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    dnsSettings: {
      domainNameLabel: '${apimName}-${take(uniqueString(resourceGroup().id), 6)}'
    }
  }
}

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: apimName
  location: location
  tags: tags
  sku: {
    name: sku.name
    capacity: sku.capacity
  }
  zones: empty(zones) ? null : zones
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    // Internal mode: the gateway, management API and portal get a private VIP in snet-apim only.
    // publicNetworkAccess is intentionally not set; it applies to the private-endpoint (non-injected)
    // model and is not valid together with VNet injection.
    virtualNetworkType: 'Internal'
    virtualNetworkConfiguration: {
      subnetResourceId: apimSubnetId
    }
    publicIpAddressId: managementPublicIp.id
    customProperties: customProperties
    // Pin the management API floor so legacy clients cannot manage the instance over older contracts.
    apiVersionConstraint: {
      minApiVersion: '2021-08-01'
    }
    // Developer portal has no business in an internal, partner-contract-driven gateway.
    developerPortalStatus: 'Disabled'
    legacyPortalStatus: 'Disabled'
  }
}

// Needed before any Key Vault-backed named value is created (see apim-api.bicep).
resource keyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, apim.id, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
  }
}

// App Insights has local auth disabled, so the logger authenticates with the APIM identity.
resource metricsPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appInsights.id, apim.id, monitoringMetricsPublisherRoleId)
  scope: appInsights
  properties: {
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleId)
  }
}

resource appInsightsLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: apim
  name: 'appinsights'
  properties: {
    loggerType: 'applicationInsights'
    description: 'Request/response telemetry with W3C correlation into the shared App Insights.'
    resourceId: appInsightsId
    credentials: {
      connectionString: appInsightsConnectionString
      identityClientId: 'SystemAssigned'
    }
    isBuffered: true
  }
  dependsOn: [
    metricsPublisher
  ]
}

// 2021-05-01-preview is the only diagnostic-settings API with categoryGroup support; the GA 2016-09-01 lacks it.
#disable-next-line use-recent-api-versions
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-law'
  scope: apim
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { categoryGroup: 'allLogs', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

@description('Resource ID of the API Management instance.')
output id string = apim.id

@description('Name of the API Management instance.')
output name string = apim.name

@description('Object ID of the system-assigned identity.')
output principalId string = apim.identity.principalId

@description('Gateway URL (resolves to the internal VIP only from inside the VNet / on-prem).')
output gatewayUrl string = apim.properties.gatewayUrl

@description('Resource ID of the Application Insights logger, used by apim-api.bicep.')
output appInsightsLoggerId string = appInsightsLogger.id
