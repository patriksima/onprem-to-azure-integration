// Workload conventions expressed as functions, so every AVM module call shapes its private endpoint,
// diagnostic setting and role assignment the same way without repeating the object literal.
// No resources live here; the file is imported with `import { ... } from 'conventions.bicep'`.

@export()
@description('Private endpoint in the AVM `privateEndpoints` shape: deterministic endpoint, connection and NIC names, one DNS zone group ("default") that registers the A record in the given zone. Hand-maintained DNS is the most common cause of "works in dev, 403 in prod" with Private Link, so the zone group is never optional.')
func privateEndpointFor(name string, subnetResourceId string, groupId string, privateDnsZoneResourceId string, location string, tags object) object => {
  name: name
  location: location
  tags: tags
  service: groupId
  subnetResourceId: subnetResourceId
  privateLinkServiceConnectionName: name
  customNetworkInterfaceName: '${name}-nic'
  privateDnsZoneGroup: {
    name: 'default'
    privateDnsZoneGroupConfigs: [
      {
        name: groupId
        privateDnsZoneResourceId: privateDnsZoneResourceId
      }
    ]
  }
}

@export()
@description('Diagnostic setting "to-law" in the AVM `diagnosticSettings` shape. Empty category arrays mean "everything the resource offers" (AVM default: allLogs + AllMetrics); pass explicit arrays where a resource has no log categories or where only some metrics are meaningful.')
func diagnosticsToLaw(workspaceResourceId string, logCategoriesAndGroups array, metricCategories array) object => {
  name: 'to-law'
  workspaceResourceId: workspaceResourceId
  ...(empty(logCategoriesAndGroups) ? {} : { logCategoriesAndGroups: logCategoriesAndGroups })
  ...(empty(metricCategories) ? {} : { metricCategories: metricCategories })
}

@export()
@description('Role assignment for a managed identity in the AVM `roleAssignments` shape. principalType is always set so the assignment does not fail on a freshly created identity that has not replicated yet.')
func roleAssignmentFor(principalId string, roleDefinitionId string) object => {
  principalId: principalId
  roleDefinitionIdOrName: roleDefinitionId
  principalType: 'ServicePrincipal'
}
