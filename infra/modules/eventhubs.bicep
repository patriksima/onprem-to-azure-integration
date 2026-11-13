// Event Hubs namespace that replaces the on-prem Kafka cluster. Kafka protocol stays enabled so the
// existing producers (and MirrorMaker 2 during the cut-over) keep working without code changes;
// only the bootstrap server and SASL mechanism change.

@description('Base name, e.g. "mer-int-dev".')
@minLength(6)
param baseName string

@description('Azure region.')
param location string

@description('Resource tags.')
param tags object

@description('Throughput units for the Standard namespace. Auto-inflate scales up to maximumThroughputUnits.')
@minValue(1)
@maxValue(40)
param capacity int = 1

@description('Upper bound for auto-inflate.')
@minValue(1)
@maxValue(40)
param maximumThroughputUnits int = 4

@description('Zone redundancy. Standard namespaces in AZ-enabled regions are zone-redundant; set true where supported.')
param zoneRedundant bool = true

@description('Message retention in days for every hub (1-7 on Standard).')
@minValue(1)
@maxValue(7)
param messageRetentionInDays int = 7

@description('Partition count per hub. Four matches the on-prem topic layout and the number of Function App instances we scale to.')
@minValue(1)
@maxValue(32)
param partitionCount int = 4

@description('Object ID of the on-prem producer identity (workload identity / service principal) that publishes to the hubs. Empty to skip.')
param onPremProducerObjectId string = ''

@description('Subnet resource ID for the private endpoint (snet-pe).')
param peSubnetId string

@description('Resource ID of the privatelink.servicebus.windows.net zone.')
param privateDnsZoneId string

@description('Log Analytics workspace resource ID for diagnostics.')
param logAnalyticsWorkspaceId string

var namespaceName = '${baseName}-evh'

// Hub names mirror the on-prem Kafka topics 1:1 so MirrorMaker needs no renaming rules.
var eventHubNames = [
  'crm.customer-updated'
  'crm.order-created'
]

// One consumer group per downstream consumer; "mirror" is only used by MirrorMaker 2 while the
// on-prem and Azure sides are validated against each other.
var consumerGroupNames = [
  'reporting'
  'notifications'
  'partner-sync'
  'mirror'
]

var eventHubsDataSenderRoleId = '2b629674-e913-4c01-ae53-ef4638d8f975'

resource namespace 'Microsoft.EventHub/namespaces@2026-01-01' = {
  name: namespaceName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Standard'
    capacity: capacity
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    kafkaEnabled: true
    isAutoInflateEnabled: true
    maximumThroughputUnits: maximumThroughputUnits
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
    // No SAS keys anywhere: Function App, Logic App and the on-prem producer all use Entra tokens
    // (Kafka clients via OAUTHBEARER).
    disableLocalAuth: true
    zoneRedundant: zoneRedundant
  }
}

// With public access disabled the network rule set only needs to confirm the default action; the
// private endpoint is the sole entry point.
resource networkRules 'Microsoft.EventHub/namespaces/networkRuleSets@2026-01-01' = {
  parent: namespace
  name: 'default'
  properties: {
    publicNetworkAccess: 'Disabled'
    defaultAction: 'Deny'
    trustedServiceAccessEnabled: true
  }
}

resource eventHubs 'Microsoft.EventHub/namespaces/eventhubs@2026-01-01' = [
  for hubName in eventHubNames: {
    parent: namespace
    name: hubName
    properties: {
      partitionCount: partitionCount
      messageRetentionInDays: messageRetentionInDays
      status: 'Active'
    }
  }
]

// Cross product hubs x consumer groups, flattened so each is a stable, individually addressable resource.
var hubConsumerGroupPairs = flatten(map(range(0, length(eventHubNames)), hubIndex => map(consumerGroupNames, cg => { hubIndex: hubIndex, consumerGroup: cg })))

resource consumerGroups 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2026-01-01' = [
  for pair in hubConsumerGroupPairs: {
    parent: eventHubs[pair.hubIndex]
    name: pair.consumerGroup
  }
]

resource producerSenderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(onPremProducerObjectId)) {
  name: guid(namespace.id, onPremProducerObjectId, eventHubsDataSenderRoleId)
  scope: namespace
  properties: {
    principalId: onPremProducerObjectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', eventHubsDataSenderRoleId)
  }
}

module privateEndpoint 'private-endpoint.bicep' = {
  name: 'pe-${namespaceName}'
  params: {
    name: '${baseName}-pe-evh'
    location: location
    tags: tags
    subnetId: peSubnetId
    privateLinkServiceId: namespace.id
    groupId: 'namespace'
    privateDnsZoneId: privateDnsZoneId
  }
}

// 2021-05-01-preview is the only diagnostic-settings API with categoryGroup support; the GA 2016-09-01 lacks it.
#disable-next-line use-recent-api-versions
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-law'
  scope: namespace
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

@description('Resource ID of the Event Hubs namespace.')
output id string = namespace.id

@description('Name of the Event Hubs namespace.')
output name string = namespace.name

@description('Fully qualified namespace, e.g. mer-int-dev-evh.servicebus.windows.net, for identity-based client configuration.')
output fullyQualifiedNamespace string = replace(replace(namespace.properties.serviceBusEndpoint, 'https://', ''), ':443/', '')

@description('Names of the event hubs created.')
output eventHubNames array = eventHubNames
