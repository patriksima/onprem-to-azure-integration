// Private DNS zones for every Private Link service the workload consumes, linked to the spoke VNet.
// Created here so the spoke is self-contained; in a mature landing zone they are centralised in the
// connectivity subscription and the spoke only links to them (swap this module for a link-only one).

@description('Resource tags.')
param tags object

@description('Resource ID of the VNet to link the zones to.')
param vnetId string

@description('Name of the VNet (used for the link name).')
param vnetName string

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

resource privateDnsZones 'Microsoft.Network/privateDnsZones@2024-06-01' = [
  for zoneName in items(privateDnsZoneNames): {
    name: zoneName.value
    location: 'global'
    tags: tags
  }
]

resource privateDnsZoneLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (zoneName, i) in items(privateDnsZoneNames): {
    parent: privateDnsZones[i]
    name: '${vnetName}-link'
    location: 'global'
    tags: tags
    properties: {
      virtualNetwork: { id: vnetId }
      registrationEnabled: false
    }
  }
]

@description('Map of private DNS zone resource IDs keyed by service (servicebus, sql, keyvault, blob, file, queue, table, sites).')
output privateDnsZoneIds object = toObject(items(privateDnsZoneNames), zone => zone.key, zone => resourceId('Microsoft.Network/privateDnsZones', zone.value))
