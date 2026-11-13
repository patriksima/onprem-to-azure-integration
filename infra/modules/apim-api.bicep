// The partner-orders API on an existing API Management instance: version set, API, one operation,
// the policy from infra/apim/policies/partner-orders.xml, the named values the policy needs, and the
// App Insights diagnostic. Kept separate from apim.bicep so adding an API never touches the platform.

@description('Name of the existing API Management instance.')
param apimName string

@description('Resource ID of the App Insights logger created in apim.bicep.')
param appInsightsLoggerId string

@description('Telemetry sampling percentage. 100 in dev for full visibility; lower in prod to control cost.')
@minValue(0)
@maxValue(100)
param samplingPercentage int = 100

@description('Hostname of the Logic App backend (default hostname; resolves via privatelink.azurewebsites.net).')
param backendHostName string

@description('Vault URI of the Key Vault holding the callback signature, e.g. https://name.vault.azure.net/.')
param keyVaultUri string

@description('Name of the Key Vault secret holding the Logic App Request-trigger SAS signature.')
param callbackSignatureSecretName string

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource backendHostNamedValue 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'partner-orders-backend-host'
  properties: {
    displayName: 'partner-orders-backend-host'
    value: backendHostName
    secret: false
    tags: [ 'partner-orders' ]
  }
}

// Key Vault-backed named value: APIM pulls the secret with its managed identity and refreshes it on
// rotation, so the signature never appears in Bicep, parameters or deployment history.
resource callbackSignatureNamedValue 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'partner-orders-callback-sig'
  properties: {
    displayName: 'partner-orders-callback-sig'
    secret: true
    keyVault: {
      secretIdentifier: '${keyVaultUri}secrets/${callbackSignatureSecretName}'
    }
    tags: [ 'partner-orders' ]
  }
}

resource versionSet 'Microsoft.ApiManagement/service/apiVersionSets@2024-05-01' = {
  parent: apim
  name: 'partner-orders'
  properties: {
    displayName: 'Partner Orders'
    versioningScheme: 'Segment'
    description: 'Inbound purchase orders from distribution partners.'
  }
}

resource api 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'partner-orders-v1'
  properties: {
    displayName: 'Partner Orders'
    description: 'Accepts purchase orders from distribution partners and hands them to the order orchestration workflow.'
    path: 'partners/orders'
    apiVersion: 'v1'
    apiVersionSetId: versionSet.id
    protocols: [ 'https' ]
    subscriptionRequired: true
    subscriptionKeyParameterNames: {
      header: 'Ocp-Apim-Subscription-Key'
      query: 'subscription-key'
    }
    // Placeholder; the policy overrides it with set-backend-service.
    serviceUrl: 'https://${backendHostName}'
    apiType: 'http'
    type: 'http'
  }
}

resource submitOrderOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'submit-order'
  properties: {
    displayName: 'Submit order'
    description: 'Submit a purchase order. Returns 202 with the correlation id; processing is asynchronous.'
    method: 'POST'
    urlTemplate: '/'
    request: {
      description: 'Purchase order payload (schema published in the partner integration guide).'
      representations: [
        { contentType: 'application/json' }
      ]
    }
    responses: [
      { statusCode: 202, description: 'Accepted for processing.' }
      { statusCode: 400, description: 'Payload failed validation.' }
      { statusCode: 429, description: 'Partner rate limit exceeded.' }
    ]
  }
}

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../apim/policies/partner-orders.xml')
  }
  dependsOn: [
    backendHostNamedValue
    callbackSignatureNamedValue
  ]
}

resource apiDiagnostic 'Microsoft.ApiManagement/service/apis/diagnostics@2024-05-01' = {
  parent: api
  name: 'applicationinsights'
  properties: {
    loggerId: appInsightsLoggerId
    alwaysLog: 'allErrors'
    httpCorrelationProtocol: 'W3C'
    verbosity: 'information'
    logClientIp: true
    sampling: {
      samplingType: 'fixed'
      percentage: samplingPercentage
    }
    frontend: {
      request: { headers: [ 'x-correlation-id' ], body: { bytes: 0 } }
      response: { headers: [ 'x-correlation-id' ], body: { bytes: 0 } }
    }
    backend: {
      request: { headers: [ 'x-correlation-id' ], body: { bytes: 0 } }
      response: { headers: [ 'x-correlation-id' ], body: { bytes: 0 } }
    }
  }
}

@description('Resource ID of the partner-orders API.')
output apiId string = api.id
