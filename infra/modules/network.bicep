// Spoke VNet for the integration workload.
// The hub (VPN gateway to on-prem, Azure Firewall, shared DNS) is owned by the landing zone and is
// only referenced here. This module owns the VNet, subnets and peering; NSGs/UDRs live in
// network-security.bicep and the Private Link DNS zones in private-dns.bicep.

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

// Deterministic carve-up of the address space so a different /22 per environment needs no other change.
var peSubnetPrefix = cidrSubnet(addressSpace, 24, 0)
var apimSubnetPrefix = cidrSubnet(addressSpace, 26, 4)
var logicAppSubnetPrefix = cidrSubnet(addressSpace, 26, 5)
var functionAppSubnetPrefix = cidrSubnet(addressSpace, 26, 6)

var peerToHub = !empty(hubVnetId)
var routeViaFirewall = !empty(firewallPrivateIp)

module networkSecurity 'network-security.bicep' = {
  name: 'network-security'
  params: {
    baseName: baseName
    location: location
    tags: tags
    firewallPrivateIp: firewallPrivateIp
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2025-05-01' = {
  name: '${baseName}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressSpace
      ]
    }
    subnets: [
      {
        name: 'snet-pe'
        properties: {
          addressPrefix: peSubnetPrefix
          networkSecurityGroup: { id: networkSecurity.outputs.peNsgId }
          // Disabled: private endpoint NICs bypass NSG/UDR evaluation, which keeps Private Link traffic
          // predictable and avoids the platform rejecting endpoints on subnets with policies enabled.
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
          defaultOutboundAccess: false
        }
      }
      {
        name: 'snet-apim'
        properties: {
          addressPrefix: apimSubnetPrefix
          networkSecurityGroup: { id: networkSecurity.outputs.apimNsgId }
          routeTable: routeViaFirewall ? { id: networkSecurity.outputs.apimRouteTableId } : null
          defaultOutboundAccess: false
        }
      }
      {
        name: 'snet-la'
        properties: {
          addressPrefix: logicAppSubnetPrefix
          networkSecurityGroup: { id: networkSecurity.outputs.logicAppNsgId }
          routeTable: routeViaFirewall ? { id: networkSecurity.outputs.appsRouteTableId } : null
          defaultOutboundAccess: false
          delegations: [
            {
              name: 'Microsoft.Web.serverFarms'
              properties: { serviceName: 'Microsoft.Web/serverFarms' }
            }
          ]
        }
      }
      {
        name: 'snet-fa'
        properties: {
          addressPrefix: functionAppSubnetPrefix
          networkSecurityGroup: { id: networkSecurity.outputs.functionAppNsgId }
          routeTable: routeViaFirewall ? { id: networkSecurity.outputs.appsRouteTableId } : null
          defaultOutboundAccess: false
          delegations: [
            {
              name: 'Microsoft.Web.serverFarms'
              properties: { serviceName: 'Microsoft.Web/serverFarms' }
            }
          ]
        }
      }
    ]
  }
}

// Spoke -> hub only. The hub -> spoke half (allowGatewayTransit) is deployed by the landing-zone
// pipeline in the connectivity subscription; useRemoteGateways fails until that half exists.
resource peeringToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2025-05-01' = if (peerToHub) {
  parent: vnet
  name: 'to-hub'
  properties: {
    remoteVirtualNetwork: { id: hubVnetId }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: true
  }
}

module privateDns 'private-dns.bicep' = {
  name: 'private-dns'
  params: {
    tags: tags
    vnetId: vnet.id
    vnetName: vnet.name
  }
}

@description('Resource ID of the spoke VNet.')
output vnetId string = vnet.id

@description('Name of the spoke VNet.')
output vnetName string = vnet.name

@description('Resource ID of the private-endpoint subnet.')
output peSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, 'snet-pe')

@description('Resource ID of the API Management subnet.')
output apimSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, 'snet-apim')

@description('Resource ID of the Logic App VNet-integration subnet.')
output logicAppSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, 'snet-la')

@description('Resource ID of the Function App VNet-integration subnet.')
output functionAppSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, 'snet-fa')

@description('Map of private DNS zone resource IDs keyed by service (servicebus, sql, keyvault, blob, file, queue, table, sites).')
output privateDnsZoneIds object = privateDns.outputs.privateDnsZoneIds
