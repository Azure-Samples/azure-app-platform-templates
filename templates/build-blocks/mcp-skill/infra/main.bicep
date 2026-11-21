targetScope = 'subscription'

@minLength(1)
@maxLength(32)
@description('Environment name used to name and tag Azure resources.')
param environmentName string

@minLength(1)
@description('Primary Azure region for all resources.')
param location string

var normalizedEnv = replace(replace(toLower(environmentName), '_', '-'), ' ', '-')
var resourceToken = take('${take(normalizedEnv, 14)}-${take(uniqueString(subscription().id, environmentName, location), 8)}', 24)
var baseTags = {
  'azd-env-name': environmentName
}

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: baseTags
}

module skillResources './resources.bicep' = {
  name: 'mcp-skill-resources'
  scope: rg
  params: {
    environmentName: environmentName
    location: location
    resourceToken: resourceToken
    serviceTagValue: '__SKILL_NAME__'
  }
}

output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_FUNCTION_APP_NAME string = skillResources.outputs.functionAppName
output SERVICE_MCP_SKILL_URI string = skillResources.outputs.serviceUri
output MCP_ENDPOINT_URL string = skillResources.outputs.mcpEndpointUrl
