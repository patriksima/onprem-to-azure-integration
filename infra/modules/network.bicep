// Spoke VNet for the integration workload.
// The hub (VPN gateway to on-prem, Azure Firewall, shared DNS) is owned by the landing zone and is
// only referenced here. This module owns the VNet, subnets, peering and the Private Link DNS zones;
// NSGs/UDRs live in network-security.bicep. The resources come from AVM; the subnet carve-up, the
// subnet policies and the zone list are the workload's decisions.

@description('Base name used for all network resources, e.g. "mer-int-dev".')
param baseName string

@description('Azure region for the VNet and all child resources.')
param location string

@description('Resource tags.')
param tags object

@description('Address space of the spoke VNet. /22 gives room for a /24 private-endpoint subnet and three /26 compute subnets.')
param addressSpace string = '10.20.0.0/22'

@description('Resource ID of the hub VNet. Leave empty to skip peering (isolated dev sandbox).')
param hubVnetId string = ''

@description('Private IP of the hub Azure Firewall. Leave empty to skip the default route (traffic then uses platform default outbound).')
param firewallPrivateIp string = ''

var vnetName = '${baseName}-vnet'

// Deterministic carve-up of the address space so a different /22 per environment needs no other change.
var peSubnetPrefix = cidrSubnet(addressSpace, 24, 0)
var apimSubnetPrefix = cidrSubnet(addressSpace, 26, 4)
var logicAppSubnetPrefix = cidrSubnet(addressSpace, 26, 5)
var functionAppSubnetPrefix = cidrSubnet(addressSpace, 26, 6)

var subnetNames = {
  pe: 'snet-pe'
  apim: 'snet-apim'
  logicApp: 'snet-la'
  functionApp: 'snet-fa'
}

var peerToHub = !empty(hubVnetId)
var routeViaFirewall = !empty(firewallPrivateIp)

// Private DNS zones for every Private Link service the workload consumes. Created here so the spoke is
// self-contained; in a mature landing zone they are centralised in the connectivity subscription and
// the spoke only links to them (swap the zone modules for link-only ones).
var privateDnsZoneNames = {
  servicebus: 'privatelink.servicebus.windows.net'
  sql: 'privatelink${environment().suffixes.sqlServerHostname}'
  keyvault: 'privatelink.vaultcore.azure.net'
  blob: 'privatelink.blob.${environment().suffixes.storage}'
  file: 'privatelink.file.${environment().suffixes.storage}'
  queue: 'privatelink.queue.${environment().suffixes.storage}'
  table: 'privatelink.table.${environment().suffixes.storage}'
  sites: 'privatelink.azurewebsites.net'
}

module networkSecurity 'network-security.bicep' = {
  name: 'network-security'
  params: {
    baseName: baseName
    location: location
    tags: tags
    firewallPrivateIp: firewallPrivateIp
  }
}

module vnet 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: 'vnet'
  params: {
    name: vnetName
    location: location
    tags: tags
    addressPrefixes: [
      addressSpace
    ]
    subnets: [
      {
        name: subnetNames.pe
        addressPrefix: peSubnetPrefix
        networkSecurityGroupResourceId: networkSecurity.outputs.peNsgId
        // Disabled: private endpoint NICs bypass NSG/UDR evaluation, which keeps Private Link traffic
        // predictable and avoids the platform rejecting endpoints on subnets with policies enabled.
        privateEndpointNetworkPolicies: 'Disabled'
        privateLinkServiceNetworkPolicies: 'Enabled'
        defaultOutboundAccess: false
      }
      {
        name: subnetNames.apim
        addressPrefix: apimSubnetPrefix
        networkSecurityGroupResourceId: networkSecurity.outputs.apimNsgId
        routeTableResourceId: routeViaFirewall ? networkSecurity.outputs.apimRouteTableId : null
        defaultOutboundAccess: false
      }
      {
        name: subnetNames.logicApp
        addressPrefix: logicAppSubnetPrefix
        networkSecurityGroupResourceId: networkSecurity.outputs.logicAppNsgId
        routeTableResourceId: routeViaFirewall ? networkSecurity.outputs.appsRouteTableId : null
        defaultOutboundAccess: false
        delegation: 'Microsoft.Web/serverFarms'
      }
      {
        name: subnetNames.functionApp
        addressPrefix: functionAppSubnetPrefix
        networkSecurityGroupResourceId: networkSecurity.outputs.functionAppNsgId
        routeTableResourceId: routeViaFirewall ? networkSecurity.outputs.appsRouteTableId : null
        defaultOutboundAccess: false
        delegation: 'Microsoft.Web/serverFarms'
      }
    ]
    // Spoke -> hub only. The hub -> spoke half (allowGatewayTransit) is deployed by the landing-zone
    // pipeline in the connectivity subscription; useRemoteGateways fails until that half exists.
    peerings: peerToHub
      ? [
          {
            name: 'to-hub'
            remoteVirtualNetworkResourceId: hubVnetId
            allowVirtualNetworkAccess: true
            allowForwardedTraffic: true
            allowGatewayTransit: false
            useRemoteGateways: true
            remotePeeringEnabled: false
          }
        ]
      : []
  }
}

module privateDnsZones 'br/public:avm/res/network/private-dns-zone:0.8.1' = [
  for zone in items(privateDnsZoneNames): {
    name: 'pdns-${zone.key}'
    params: {
      name: zone.value
      location: 'global'
      tags: tags
      virtualNetworkLinks: [
        {
          name: '${vnetName}-link'
          virtualNetworkResourceId: vnet.outputs.resourceId
          registrationEnabled: false
        }
      ]
    }
  }
]

@description('Resource ID of the spoke VNet.')
output vnetId string = vnet.outputs.resourceId

@description('Name of the spoke VNet.')
output vnetName string = vnet.outputs.name

@description('Resource ID of the private-endpoint subnet.')
output peSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.outputs.name, subnetNames.pe)

@description('Resource ID of the API Management subnet.')
output apimSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.outputs.name, subnetNames.apim)

@description('Resource ID of the Logic App VNet-integration subnet.')
output logicAppSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.outputs.name, subnetNames.logicApp)

@description('Resource ID of the Function App VNet-integration subnet.')
output functionAppSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.outputs.name, subnetNames.functionApp)

// An array rather than a map because a module collection cannot be indexed inside toObject(); the
// caller folds it into a map. Referencing the module outputs (instead of computing resourceId()) keeps
// the deployment dependency on the zones.
@description('Private DNS zones as { service, resourceId } pairs; service is one of servicebus, sql, keyvault, blob, file, queue, table, sites.')
output privateDnsZones array = [
  for (zone, i) in items(privateDnsZoneNames): {
    service: zone.key
    resourceId: privateDnsZones[i].outputs.resourceId
  }
]
