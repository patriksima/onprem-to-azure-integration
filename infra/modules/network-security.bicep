// NSGs and route tables for the spoke. Separated from the VNet so the rule sets can be reviewed
// (and changed) without touching address space or peering. The resources come from AVM; this file
// only owns the rule sets and routes, which are the workload's decisions.

@description('Base name used for all network resources, e.g. "mer-int-dev".')
param baseName string

@description('Azure region.')
param location string

@description('Resource tags.')
param tags object

@description('Private IP of the hub Azure Firewall. Leave empty to skip the default route (traffic then uses platform default outbound).')
param firewallPrivateIp string = ''

var routeViaFirewall = !empty(firewallPrivateIp)

// Blocking RDP/SSH between subnets costs nothing and removes the most common lateral-movement path.
var denyLateralTraversalRule = {
  name: 'Deny-Outbound-RDP-SSH-Lateral'
  properties: {
    description: 'Prevent lateral movement over management ports between subnets.'
    priority: 4000
    direction: 'Outbound'
    access: 'Deny'
    protocol: 'Tcp'
    sourceAddressPrefix: 'VirtualNetwork'
    sourcePortRange: '*'
    destinationAddressPrefix: 'VirtualNetwork'
    destinationPortRanges: [
      '22'
      '3389'
    ]
  }
}

// APIM classic tiers in internal VNet mode fail provisioning (and later upgrades) if the control plane
// cannot reach the instance. These are the documented minimum rules for the stv2 platform.
var apimRules = [
  {
    name: 'Allow-Inbound-ApiManagement-Management'
    properties: {
      description: 'APIM control plane -> management endpoint.'
      priority: 100
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'ApiManagement'
      sourcePortRange: '*'
      destinationAddressPrefix: 'VirtualNetwork'
      destinationPortRange: '3443'
    }
  }
  {
    name: 'Allow-Inbound-AzureLoadBalancer-Health'
    properties: {
      description: 'Azure infrastructure load balancer health probes.'
      priority: 110
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'AzureLoadBalancer'
      sourcePortRange: '*'
      destinationAddressPrefix: 'VirtualNetwork'
      destinationPortRange: '6390'
    }
  }
  {
    name: 'Allow-Inbound-VirtualNetwork-Https'
    properties: {
      description: 'Client traffic to the gateway from the VNet (incl. on-prem via the hub).'
      priority: 120
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: 'VirtualNetwork'
      destinationPortRange: '443'
    }
  }
  {
    name: 'Allow-Outbound-Storage'
    properties: {
      description: 'Core service dependency (configuration, policies, diagnostics).'
      priority: 100
      direction: 'Outbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: 'Storage'
      destinationPortRange: '443'
    }
  }
  {
    name: 'Allow-Outbound-Sql'
    properties: {
      description: 'Core service dependency (internal configuration database).'
      priority: 110
      direction: 'Outbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: 'Sql'
      destinationPortRange: '1433'
    }
  }
  {
    name: 'Allow-Outbound-KeyVault'
    properties: {
      description: 'Key Vault-backed named values and certificates.'
      priority: 120
      direction: 'Outbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: 'AzureKeyVault'
      destinationPortRange: '443'
    }
  }
  {
    name: 'Allow-Outbound-AzureMonitor'
    properties: {
      description: 'Diagnostics, resource health and Application Insights.'
      priority: 130
      direction: 'Outbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: 'AzureMonitor'
      destinationPortRanges: [
        '1886'
        '443'
      ]
    }
  }
  {
    name: 'Allow-Outbound-EntraId'
    properties: {
      description: 'Managed identity token acquisition for Key Vault and App Insights.'
      priority: 140
      direction: 'Outbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: 'AzureActiveDirectory'
      destinationPortRange: '443'
    }
  }
  denyLateralTraversalRule
]

module nsgPe 'br/public:avm/res/network/network-security-group:0.5.4' = {
  name: 'nsg-pe'
  params: {
    name: '${baseName}-nsg-pe'
    location: location
    tags: tags
    securityRules: [
      denyLateralTraversalRule
    ]
  }
}

module nsgApim 'br/public:avm/res/network/network-security-group:0.5.4' = {
  name: 'nsg-apim'
  params: {
    name: '${baseName}-nsg-apim'
    location: location
    tags: tags
    securityRules: apimRules
  }
}

module nsgLogicApp 'br/public:avm/res/network/network-security-group:0.5.4' = {
  name: 'nsg-la'
  params: {
    name: '${baseName}-nsg-la'
    location: location
    tags: tags
    securityRules: [
      denyLateralTraversalRule
    ]
  }
}

module nsgFunctionApp 'br/public:avm/res/network/network-security-group:0.5.4' = {
  name: 'nsg-fa'
  params: {
    name: '${baseName}-nsg-fa'
    location: location
    tags: tags
    securityRules: [
      denyLateralTraversalRule
    ]
  }
}

// Two route tables: compute subnets force-tunnel everything to the firewall; the APIM subnet does the
// same but must keep the control-plane path (ApiManagement tag) on the Internet next hop, otherwise
// the firewall breaks management traffic and the instance ends up unhealthy.
var defaultRouteToFirewall = {
  name: 'default-to-firewall'
  properties: {
    addressPrefix: '0.0.0.0/0'
    nextHopType: 'VirtualAppliance'
    nextHopIpAddress: firewallPrivateIp
  }
}

module rtApps 'br/public:avm/res/network/route-table:0.5.0' = if (routeViaFirewall) {
  name: 'rt-apps'
  params: {
    name: '${baseName}-rt-apps'
    location: location
    tags: tags
    disableBgpRoutePropagation: false
    routes: [
      defaultRouteToFirewall
    ]
  }
}

module rtApim 'br/public:avm/res/network/route-table:0.5.0' = if (routeViaFirewall) {
  name: 'rt-apim'
  params: {
    name: '${baseName}-rt-apim'
    location: location
    tags: tags
    disableBgpRoutePropagation: false
    routes: [
      defaultRouteToFirewall
      {
        name: 'apim-control-plane-direct'
        properties: {
          addressPrefix: 'ApiManagement'
          nextHopType: 'Internet'
        }
      }
    ]
  }
}

@description('NSG resource ID for snet-pe.')
output peNsgId string = nsgPe.outputs.resourceId

@description('NSG resource ID for snet-apim.')
output apimNsgId string = nsgApim.outputs.resourceId

@description('NSG resource ID for snet-la.')
output logicAppNsgId string = nsgLogicApp.outputs.resourceId

@description('NSG resource ID for snet-fa.')
output functionAppNsgId string = nsgFunctionApp.outputs.resourceId

@description('Route table resource ID for the compute subnets, or empty when no firewall is configured.')
output appsRouteTableId string = routeViaFirewall ? rtApps!.outputs.resourceId : ''

@description('Route table resource ID for the APIM subnet, or empty when no firewall is configured.')
output apimRouteTableId string = routeViaFirewall ? rtApim!.outputs.resourceId : ''
