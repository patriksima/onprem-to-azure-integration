// Shared observability plane: one Log Analytics workspace, one workspace-based Application Insights
// resource used by every app in the workload (so distributed traces across APIM -> Logic App ->
// Function App land in one place), and the action group that every alert routes to.

@description('Base name used for all monitoring resources, e.g. "mer-int-dev".')
param baseName string

@description('Azure region.')
param location string

@description('Resource tags.')
param tags object

@description('Log retention in days. 30 for dev, 90 for prod (regulatory minimum for the fictional distributor\'s partner contracts).')
@minValue(30)
@maxValue(730)
param logRetentionInDays int = 30

@description('Daily ingestion cap in GB. -1 disables the cap; keep a cap in dev so a logging bug cannot run up the bill.')
@minValue(-1)
@maxValue(1000)
param dailyQuotaGb int = -1

@description('E-mail addresses that receive alert notifications.')
param alertEmailReceivers array

@description('Short name shown in SMS/e-mail subjects (1-12 characters).')
@minLength(1)
@maxLength(12)
param actionGroupShortName string

module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.16.1' = {
  name: 'law'
  params: {
    name: '${baseName}-law'
    location: location
    tags: tags
    skuName: 'PerGB2018'
    dataRetention: logRetentionInDays
    dailyQuotaGb: string(dailyQuotaGb)
    features: {
      // Workspace-level RBAC: a reader on the Function App resource sees only that app's logs.
      enableLogAccessUsingOnlyResourcePermissions: true
      // No shared-key ingestion (Data Collector API / legacy agents); every producer here goes through
      // diagnostic settings or App Insights, both of which authenticate with Entra.
      disableLocalAuth: true
    }
    // Ingestion stays on public endpoints: the apps egress through the hub firewall and
    // Azure Monitor Private Link Scope is a landing-zone concern, not a workload one.
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    // No customer-managed storage for saved queries; keep the platform default rather than AVM's.
    forceCmkForQuery: false
  }
}

module appInsights 'br/public:avm/res/insights/component:0.8.0' = {
  name: 'appi'
  params: {
    name: '${baseName}-appi'
    location: location
    tags: tags
    kind: 'web'
    applicationType: 'web'
    workspaceResourceId: logAnalytics.outputs.resourceId
    ingestionMode: 'LogAnalytics'
    // Local (instrumentation-key) auth is off; every producer authenticates with its managed
    // identity and the Monitoring Metrics Publisher role (see rbac.bicep and the APIM logger).
    disableLocalAuth: true
    // Keep client IPs masked (platform default); AVM would unmask them.
    disableIpMasking: false
    // Retention is governed by the workspace; 90 is the component default and kept explicit.
    retentionInDays: 90
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

module actionGroup 'br/public:avm/res/insights/action-group:0.8.0' = {
  name: 'ag'
  params: {
    name: '${baseName}-ag'
    location: 'global'
    tags: tags
    groupShortName: actionGroupShortName
    enabled: true
    emailReceivers: [
      for (email, i) in alertEmailReceivers: {
        name: 'email-${i}'
        emailAddress: email
        useCommonAlertSchema: true
      }
    ]
  }
}

@description('Resource ID of the Log Analytics workspace.')
output logAnalyticsWorkspaceId string = logAnalytics.outputs.resourceId

@description('Name of the Log Analytics workspace.')
output logAnalyticsWorkspaceName string = logAnalytics.outputs.name

@description('Resource ID of the Application Insights component.')
output appInsightsId string = appInsights.outputs.resourceId

@description('Name of the Application Insights component.')
output appInsightsName string = appInsights.outputs.name

@description('Application Insights connection string. Not a secret (ingestion requires Entra auth), but treat as configuration.')
output appInsightsConnectionString string = appInsights.outputs.connectionString

@description('Resource ID of the action group.')
output actionGroupId string = actionGroup.outputs.resourceId
