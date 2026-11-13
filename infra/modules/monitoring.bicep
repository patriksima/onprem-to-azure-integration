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

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: '${baseName}-law'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: logRetentionInDays
    workspaceCapping: {
      dailyQuotaGb: dailyQuotaGb
    }
    features: {
      // Workspace-level RBAC: a reader on the Function App resource sees only that app's logs.
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    // Ingestion stays on public endpoints: the apps egress through the hub firewall and
    // Azure Monitor Private Link Scope is a landing-zone concern, not a workload one.
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${baseName}-appi'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    IngestionMode: 'LogAnalytics'
    // Local (instrumentation-key) auth is off; every producer authenticates with its managed
    // identity and the Monitoring Metrics Publisher role (see rbac.bicep and the APIM logger).
    DisableLocalAuth: true
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: '${baseName}-ag'
  location: 'global'
  tags: tags
  properties: {
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
output logAnalyticsWorkspaceId string = logAnalytics.id

@description('Name of the Log Analytics workspace.')
output logAnalyticsWorkspaceName string = logAnalytics.name

@description('Resource ID of the Application Insights component.')
output appInsightsId string = appInsights.id

@description('Name of the Application Insights component.')
output appInsightsName string = appInsights.name

@description('Application Insights connection string. Not a secret (ingestion requires Entra auth), but treat as configuration.')
output appInsightsConnectionString string = appInsights.properties.ConnectionString

@description('Resource ID of the action group.')
output actionGroupId string = actionGroup.id
