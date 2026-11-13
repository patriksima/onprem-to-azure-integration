// Reusable private endpoint + DNS zone group.
// Every PaaS resource in this workload is reached only through a private endpoint, so the
// wiring (endpoint, NIC name, DNS registration) is centralised here instead of being repeated
// per service module.

@description('Name of the private endpoint resource.')
param name string

@description('Azure region. Must match the VNet region.')
param location string

@description('Resource tags applied to the private endpoint.')
param tags object

@description('Resource ID of the subnet that hosts the private endpoint NIC (snet-pe).')
param subnetId string

@description('Resource ID of the target PaaS resource.')
param privateLinkServiceId string

@description('Private Link sub-resource (group) to connect, for example "vault", "namespace", "blob", "sites".')
param groupId string

@description('Resource ID of the private DNS zone that the endpoint IP is registered in.')
param privateDnsZoneId string

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2025-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    // A deterministic NIC name keeps the resource group readable and makes drift detection easier.
    customNetworkInterfaceName: '${name}-nic'
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: name
        properties: {
          privateLinkServiceId: privateLinkServiceId
          groupIds: [
            groupId
          ]
        }
      }
    ]
  }
}

// The zone group registers the A record automatically; without it the workload would need
// hand-maintained DNS, which is the most common cause of "works in dev, 403 in prod" with Private Link.
resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2025-05-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: groupId
        properties: {
          privateDnsZoneId: privateDnsZoneId
        }
      }
    ]
  }
}

@description('Resource ID of the private endpoint.')
output id string = privateEndpoint.id
