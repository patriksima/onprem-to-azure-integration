// Alert rules for the integration workload. Metric alerts live here; log-search alerts and the
// availability test are in alerts-log.bicep. Each rule answers one operational question; severities
// follow the on-call runbook: 1 = partners are impacted now, 2 = data is not flowing, 3 = capacity
// or hygiene, act within business hours.

@description('Base name, e.g. "mer-int-dev".')
param baseName string

@description('Azure region for the log-search alerts and availability test (metric alerts are global).')
param location string

@description('Resource tags.')
param tags object

@description('Action group that receives every alert.')
param actionGroupId string

@description('Log Analytics workspace resource ID (passed through to alerts-log.bicep).')
param logAnalyticsWorkspaceId string

@description('Application Insights resource ID.')
param appInsightsId string

@description('Function App resource ID.')
param functionAppId string

@description('Function App name (cloud/roleName dimension in App Insights).')
param functionAppName string

@description('Logic App resource ID.')
param logicAppId string

@description('Event Hubs namespace resource ID.')
param eventHubNamespaceId string

@description('SQL database resource ID.')
param sqlDatabaseId string

@description('API Management resource ID.')
param apimId string

@description('Key Vault resource ID.')
param keyVaultId string

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
// Metric alerts
// ---------------------------------------------------------------------------------------------

var metricAlerts = [
  {
    name: 'fa-failed-requests'
    description: 'Function App reported failed requests (App Insights requests/failed). Consumers are throwing; check the latest exceptions for the function name.'
    severity: 2
    scope: appInsightsId
    windowSize: 'PT5M'
    frequency: 'PT1M'
    metricNamespace: 'microsoft.insights/components'
    metricName: 'requests/failed'
    aggregation: 'Count'
    operator: 'GreaterThan'
    threshold: 0
    dimensions: [
      { name: 'cloud/roleName', operator: 'Include', values: [ functionAppName ] }
    ]
  }
  {
    name: 'fa-http-5xx'
    description: 'Function App returned HTTP 5xx. Host-level failures (startup, storage, identity) show up here before they show up in App Insights.'
    severity: 2
    scope: functionAppId
    windowSize: 'PT5M'
    frequency: 'PT1M'
    metricNamespace: 'Microsoft.Web/sites'
    metricName: 'Http5xx'
    aggregation: 'Total'
    operator: 'GreaterThan'
    threshold: 0
    dimensions: []
  }
  {
    name: 'la-workflow-run-failures'
    description: 'Logic App workflow runs are failing (WorkflowRunsFailureRate > 0). Open the run history for the failing workflow; the correlation id is in the trigger headers.'
    severity: 2
    scope: logicAppId
    windowSize: 'PT5M'
    frequency: 'PT1M'
    metricNamespace: 'Microsoft.Web/sites'
    metricName: 'WorkflowRunsFailureRate'
    aggregation: 'Total'
    operator: 'GreaterThan'
    threshold: 0
    dimensions: []
  }
  {
    name: 'evh-throttled-requests'
    description: 'Event Hubs is throttling. Either auto-inflate hit maximumThroughputUnits or a producer is bursting; raise TUs or fix the producer batch size.'
    severity: 3
    scope: eventHubNamespaceId
    windowSize: 'PT5M'
    frequency: 'PT1M'
    metricNamespace: 'Microsoft.EventHub/namespaces'
    metricName: 'ThrottledRequests'
    aggregation: 'Total'
    operator: 'GreaterThan'
    threshold: 0
    dimensions: []
  }
  {
    name: 'evh-server-errors'
    description: 'Event Hubs returned server errors. Platform-side; check Service Health and Resource Health before touching the apps.'
    severity: 2
    scope: eventHubNamespaceId
    windowSize: 'PT5M'
    frequency: 'PT1M'
    metricNamespace: 'Microsoft.EventHub/namespaces'
    metricName: 'ServerErrors'
    aggregation: 'Total'
    operator: 'GreaterThan'
    threshold: 0
    dimensions: []
  }
  {
    name: 'sql-cpu-high'
    description: 'crm-reporting CPU above 80% for 15 minutes. Reporting queries are starving the projection writer; check query store before scaling.'
    severity: 2
    scope: sqlDatabaseId
    windowSize: 'PT15M'
    frequency: 'PT5M'
    metricNamespace: 'Microsoft.Sql/servers/databases'
    metricName: 'cpu_percent'
    aggregation: 'Average'
    operator: 'GreaterThan'
    threshold: 80
    dimensions: []
  }
  {
    name: 'apim-gateway-5xx'
    description: 'APIM gateway returned 5xx to partners. Backend (Logic App) down or policy error; partners are seeing failures right now.'
    severity: 1
    scope: apimId
    windowSize: 'PT5M'
    frequency: 'PT1M'
    metricNamespace: 'Microsoft.ApiManagement/service'
    metricName: 'Requests'
    aggregation: 'Total'
    operator: 'GreaterThan'
    threshold: 0
    dimensions: [
      { name: 'GatewayResponseCodeCategory', operator: 'Include', values: [ '5xx' ] }
    ]
  }
  {
    name: 'apim-capacity-high'
    description: 'APIM capacity above 75% for 15 minutes. Add a unit before latency degrades; classic tiers do not autoscale on their own.'
    severity: 3
    scope: apimId
    windowSize: 'PT15M'
    frequency: 'PT5M'
    metricNamespace: 'Microsoft.ApiManagement/service'
    metricName: 'Capacity'
    aggregation: 'Average'
    operator: 'GreaterThan'
    threshold: 75
    dimensions: []
  }
  {
    name: 'kv-availability-degraded'
    description: 'Key Vault availability below 100%. Named values, Key Vault references and secret reads may fail intermittently.'
    severity: 3
    scope: keyVaultId
    windowSize: 'PT15M'
    frequency: 'PT5M'
    metricNamespace: 'Microsoft.KeyVault/vaults'
    metricName: 'Availability'
    aggregation: 'Average'
    operator: 'LessThan'
    threshold: 100
    dimensions: []
  }
]

resource metricAlertRules 'Microsoft.Insights/metricAlerts@2026-01-01' = [
  for alert in metricAlerts: {
    name: '${baseName}-alert-${alert.name}'
    location: 'global'
    tags: tags
    properties: {
      description: alert.description
      severity: alert.severity
      enabled: true
      autoMitigate: true
      scopes: [ alert.scope ]
      evaluationFrequency: alert.frequency
      windowSize: alert.windowSize
      criteria: {
        'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
        allOf: [
          {
            criterionType: 'StaticThresholdCriterion'
            name: alert.name
            metricNamespace: alert.metricNamespace
            metricName: alert.metricName
            timeAggregation: alert.aggregation
            operator: alert.operator
            threshold: alert.threshold
            dimensions: alert.dimensions
          }
        ]
      }
      actions: [
        { actionGroupId: actionGroupId }
      ]
    }
  }
]

// ---------------------------------------------------------------------------------------------
// Platform health
// ---------------------------------------------------------------------------------------------

// Service Health incidents for the subscription: the first thing on-call checks when evh-server-errors fires.
resource serviceHealthAlert 'Microsoft.Insights/activityLogAlerts@2026-01-01' = {
  name: '${baseName}-alert-service-health'
  location: 'global'
  tags: tags
  properties: {
    description: 'Azure Service Health incidents and planned maintenance affecting this subscription.'
    enabled: true
    scopes: [ subscription().id ]
    condition: {
      allOf: [
        { field: 'category', equals: 'ServiceHealth' }
      ]
    }
    actions: {
      actionGroups: [
        { actionGroupId: actionGroupId }
      ]
    }
  }
}

// ---------------------------------------------------------------------------------------------
// Log-search alerts and availability test
// ---------------------------------------------------------------------------------------------

module logAlerts 'alerts-log.bicep' = {
  name: 'alerts-log'
  params: {
    baseName: baseName
    location: location
    tags: tags
    actionGroupId: actionGroupId
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    appInsightsId: appInsightsId
    eventHubNamespaceId: eventHubNamespaceId
    expectedActiveConsumerGroups: expectedActiveConsumerGroups
    poisonStorageAccountName: poisonStorageAccountName
    enableAvailabilityTest: enableAvailabilityTest
    apimGatewayUrl: apimGatewayUrl
  }
}

@description('Number of metric alert rules deployed.')
output metricAlertCount int = length(metricAlerts)

@description('Number of log-search alert rules deployed.')
output logAlertCount int = logAlerts.outputs.logAlertCount
