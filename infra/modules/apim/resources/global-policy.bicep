@description('Name of the API Management service the service-scope policy is applied to.')
param apimServiceName string

@description('IP addresses or CIDR ranges allowed to call the gateway. Empty (default) applies no ip-filter, leaving the gateway reachable by any caller holding a valid subscription key.')
param allowedIpAddresses string[] = []

var globalPolicyFormat = 'rawxml'

var addressElements = [for address in allowedIpAddresses: '<address>${address}</address>']
var ipFilter = empty(allowedIpAddresses) ? '' : '<ip-filter action="allow">${join(addressElements, '')}</ip-filter>'
var resolvedPolicy = replace(loadTextContent('../policies/global-policy.xml'), '__IP_FILTER__', ipFilter)

resource apimService 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimServiceName
}

resource globalPolicy 'Microsoft.ApiManagement/service/policies@2024-05-01' = {
  name: 'policy'
  parent: apimService
  properties: {
    value: resolvedPolicy
    format: globalPolicyFormat
  }
}

output restricted bool = !empty(allowedIpAddresses)
