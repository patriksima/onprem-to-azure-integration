// Log-search alerts (KQL over Log Analytics) and the optional synthetic availability test.
// Metric alerts are in alerts.bicep; the split keeps each file reviewable and lets the KQL evolve
// independently of the metric thresholds. The rule, web test and alert resources come from AVM; the
// queries and thresholds are ours.

@description('Base name, e.g. "mer-int-dev".')
param baseName string

@description('Azure region for the scheduled-query rules and the availability test.')
param location string

@description('Resource tags.')
param tags object

@description('Action group that receives every alert.')
param actionGroupId string

@description('Log Analytics workspace resource ID (scope of the log-search alerts).')
param logAnalyticsWorkspaceId string

@description('Application Insights resource ID.')
param appInsightsId string

@description('Event Hubs namespace resource ID.')
param eventHubNamespaceId string

@description('Number of consumer groups expected to read every event (used to normalise outgoing vs incoming messages). "mirror" is excluded because it only runs during cut-over validation.')
@minValue(1)
@maxValue(20)
param expectedActiveConsumerGroups int = 3

@description('Storage account that holds the poison-messages container.')
param poisonStorageAccountName string

@description('Create a standard availability test against the APIM health endpoint. Only meaningful when the gateway is reachable from Azure test locations (i.e. fronted by a public WAF); internal-only gateways should leave this false.')
param enableAvailabilityTest bool = false

@description('Gateway URL of the APIM instance (for the availability test).')
param apimGatewayUrl string = ''

// ---------------------------------------------------------------------------------------------
// Log-search alerts
// ---------------------------------------------------------------------------------------------

var eventHubNamespaceName = last(split(eventHubNamespaceId, '/'))

// Consumer lag proxy: every event should be read once per active consumer group, so over a healthy
// 15-minute window OutgoingMessages ~= IncomingMessages * expectedActiveConsumerGroups. Falling
// below half of that means at least one consumer group has stopped draining. Needs AllMetrics in the
// namespace diagnostic setting (eventhubs.bicep) so AzureMetrics is populated.
var consumerLagQuery = join([
  'AzureMetrics'
  '| where ResourceProvider == "MICROSOFT.EVENTHUB" and Resource =~ "${eventHubNamespaceName}"'
  '| where MetricName in ("IncomingMessages", "OutgoingMessages")'
  '| summarize value = sum(Total) by MetricName'
  '| evaluate pivot(MetricName, sum(value))'
  '| extend IncomingMessages = toreal(column_ifexists("IncomingMessages", 0.0)), OutgoingMessages = toreal(column_ifexists("OutgoingMessages", 0.0))'
  '| extend ExpectedOutgoing = IncomingMessages * ${expectedActiveConsumerGroups}'
  '| where IncomingMessages > 100 and OutgoingMessages < ExpectedOutgoing * 0.5'
  '| project IncomingMessages, OutgoingMessages, ExpectedOutgoing, LagRatio = 1 - OutgoingMessages / ExpectedOutgoing'
], '\n')

// Every PutBlob into poison-messages is a message the consumers gave up on after retries.
var poisonMessagesQuery = join([
  'StorageBlobLogs'
  '| where AccountName =~ "${poisonStorageAccountName}"'
  '| where OperationName == "PutBlob" and ObjectKey has "/poison-messages/"'
  '| project TimeGenerated, ObjectKey, CallerIpAddress, AuthenticationType, StatusText'
], '\n')

var logAlerts = [
  {
    name: 'evh-consumer-lag'
    description: 'Event Hubs consumers are falling behind: outgoing message volume is under half of what the active consumer groups should have read in the last 15 minutes. Check the Function App and Logic App for a stalled trigger.'
    severity: 2
    windowSize: 'PT15M'
    frequency: 'PT5M'
    query: consumerLagQuery
  }
  {
    name: 'poison-messages-written'
    description: 'A message was written to the poison-messages container in the last 5 minutes. It will not be retried automatically; triage and replay per the runbook.'
    severity: 2
    windowSize: 'PT5M'
    frequency: 'PT5M'
    query: poisonMessagesQuery
  }
]

module logAlertRules 'br/public:avm/res/insights/scheduled-query-rule:0.6.1' = [
  for alert in logAlerts: {
    name: 'alert-${alert.name}'
    params: {
      name: '${baseName}-alert-${alert.name}'
      location: location
      tags: tags
      kind: 'LogAlert'
      alertDisplayName: '${baseName}-alert-${alert.name}'
      alertDescription: alert.description
      severity: alert.severity
      enabled: true
      autoMitigate: true
      scopes: [ logAnalyticsWorkspaceId ]
      evaluationFrequency: alert.frequency
      windowSize: alert.windowSize
      criterias: {
        allOf: [
          {
            query: alert.query
            timeAggregation: 'Count'
            operator: 'GreaterThan'
            threshold: 0
            failingPeriods: {
              numberOfEvaluationPeriods: 1
              minFailingPeriodsToAlert: 1
            }
          }
        ]
      }
      actions: {
        actionGroupResourceIds: [ actionGroupId ]
      }
    }
  }
]

// ---------------------------------------------------------------------------------------------
// Availability test (optional)
// ---------------------------------------------------------------------------------------------

// The AVM module adds the hidden-link tag that associates the test with the App Insights resource.
module availabilityTest 'br/public:avm/res/insights/webtest:0.3.2' = if (enableAvailabilityTest) {
  name: 'webtest-apim-health'
  params: {
    name: '${baseName}-webtest-apim-health'
    location: location
    tags: tags
    appInsightResourceId: appInsightsId
    syntheticMonitorId: '${baseName}-webtest-apim-health'
    webTestName: 'APIM health endpoint'
    description: 'GET the built-in APIM status endpoint through the gateway.'
    kind: 'standard'
    enabled: true
    frequency: 300
    timeout: 30
    retryEnabled: true
    locations: [
      { Id: 'emea-nl-ams-azr' }
      { Id: 'emea-gb-db3-azr' }
      { Id: 'emea-fr-pra-edge' }
    ]
    request: {
      RequestUrl: '${apimGatewayUrl}/status-0123456789abcdef'
      HttpVerb: 'GET'
      ParseDependentRequests: false
    }
    validationRules: {
      ExpectedHttpStatusCode: 200
      SSLCheck: true
      SSLCertRemainingLifetimeCheck: 14
    }
  }
}

module availabilityAlert 'br/public:avm/res/insights/metric-alert:0.4.1' = if (enableAvailabilityTest) {
  name: 'alert-apim-availability'
  params: {
    name: '${baseName}-alert-apim-availability'
    location: 'global'
    tags: tags
    alertDescription: 'APIM health endpoint failed from two or more test locations. Partners cannot reach the gateway.'
    severity: 1
    enabled: true
    autoMitigate: true
    scopes: [ availabilityTest!.outputs.resourceId, appInsightsId ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.WebtestLocationAvailabilityCriteria'
      webTestResourceId: availabilityTest!.outputs.resourceId
      componentResourceId: appInsightsId
      failedLocationCount: 2
    }
    actions: [ actionGroupId ]
  }
}

@description('Number of log-search alert rules deployed.')
output logAlertCount int = length(logAlerts)
