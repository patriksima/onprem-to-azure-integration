// Event Hubs namespace that replaces the on-prem Kafka cluster. Kafka protocol stays enabled so the
// existing producers (and MirrorMaker 2 during the cut-over) keep working without code changes;
// only the bootstrap server and SASL mechanism change. The namespace comes from AVM; the hub and
// consumer-group layout and the no-SAS posture are ours.

import { privateEndpointFor, diagnosticsToLaw, roleAssignmentFor } from 'conventions.bicep'

@description('Base name, e.g. "mer-int-dev".')
@minLength(6)
param baseName string

@description('Azure region.')
param location string

@description('Resource tags.')
param tags object

@description('Throughput units for the Standard namespace. Auto-inflate scales up to maximumThroughputUnits. The AVM module caps both at 20.')
@minValue(1)
@maxValue(20)
param capacity int = 1

@description('Upper bound for auto-inflate. The AVM module caps this at 20 (Standard allows 40 through the portal); raise it there first if the workload ever needs more.')
@minValue(1)
@maxValue(20)
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

module namespace 'br/public:avm/res/event-hub/namespace:0.15.2' = {
  name: 'evh'
  params: {
    name: namespaceName
    location: location
    tags: tags
    skuName: 'Standard'
    skuCapacity: capacity
    zoneRedundant: zoneRedundant
    kafkaEnabled: true
    isAutoInflateEnabled: true
    maximumThroughputUnits: maximumThroughputUnits
    minimumTlsVersion: '1.2'
    managedIdentities: {
      systemAssigned: true
    }
    // No SAS keys anywhere: Function App, Logic App and the on-prem producer all use Entra tokens
    // (Kafka clients via OAUTHBEARER). The empty rule lists stop AVM from declaring the default
    // RootManageSharedAccessKey rules on the namespace and on every hub.
    disableLocalAuth: true
    authorizationRules: []
    publicNetworkAccess: 'Disabled'
    // With public access disabled the network rule set only needs to confirm the default action; the
    // private endpoint is the sole entry point.
    networkRuleSets: {
      publicNetworkAccess: 'Disabled'
      defaultAction: 'Deny'
      trustedServiceAccessEnabled: true
    }
    eventhubs: [
      for hubName in eventHubNames: {
        name: hubName
        partitionCount: partitionCount
        messageRetentionInDays: messageRetentionInDays
        status: 'Active'
        authorizationRules: []
        // map() rather than a for-expression: Bicep does not allow a for inside a for-body property.
        consumergroups: map(consumerGroupNames, consumerGroupName => { name: consumerGroupName })
      }
    ]
    roleAssignments: empty(onPremProducerObjectId)
      ? []
      : [
          roleAssignmentFor(onPremProducerObjectId, eventHubsDataSenderRoleId)
        ]
    privateEndpoints: [
      privateEndpointFor('${baseName}-pe-evh', peSubnetId, 'namespace', privateDnsZoneId, location, tags)
    ]
    diagnosticSettings: [
      diagnosticsToLaw(logAnalyticsWorkspaceId, [], [])
    ]
  }
}

// AVM does not output the service bus endpoint; read it back from the deployed namespace so the FQDN
// stays correct in sovereign clouds instead of being assembled from a hard-coded suffix. Outputs are
// evaluated after every resource in this file has deployed, so the reference resolves.
resource deployedNamespace 'Microsoft.EventHub/namespaces@2026-01-01' existing = {
  name: namespaceName
}

@description('Resource ID of the Event Hubs namespace.')
output id string = namespace.outputs.resourceId

@description('Name of the Event Hubs namespace.')
output name string = namespace.outputs.name

@description('Fully qualified namespace, e.g. mer-int-dev-evh.servicebus.windows.net, for identity-based client configuration.')
output fullyQualifiedNamespace string = replace(replace(deployedNamespace.properties.serviceBusEndpoint, 'https://', ''), ':443/', '')

@description('Names of the event hubs created.')
output eventHubNames array = eventHubNames
