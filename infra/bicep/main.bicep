// Parameters
param location string = resourceGroup().location
param instanceNumber string

@minLength(5)
param containerRegistryName string = toLower('cragents${instanceNumber}${uniqueString(resourceGroup().id)}')

@allowed(['Standard_D2s_v3', 'Standard_D4s_v3', 'Standard_DS2_v2'])
param linuxVmSize string = 'Standard_D2s_v3'

@allowed(['Standard_D2s_v3', 'Standard_D4s_v3', 'Standard_DS2_v2'])
param windowsVmSize string = 'Standard_D2s_v3'

param linuxNodeCount int = 1
param windowsNodeCount int = 1

param enableLinux bool = true
param enableWindows bool = false

// When true, do not create a Container Registry in this template. Useful when using an
// existing registry provided by the caller.
param skipContainerRegistry bool = false

param kubernetesVersion string = ''

// When true, the Bicep template will not attempt to create or modify the AKS managedCluster.
// Useful when an AKS cluster already exists in the RG and agent pools must be added via per-pool operations.
param skipAks bool = false

// Windows admin credentials are required when enabling Windows node pools.
@minLength(1)
param windowsAdminUsername string = 'azureuser'

@secure()
param windowsAdminPassword string = ''

// Derived names
var aksName = toLower('aks-ado-agents-${instanceNumber}')
var dnsPrefix = toLower('${aksName}-dns')

// Create a Container Registry in the same resource group
resource containerRegistry 'Microsoft.ContainerRegistry/registries@2025-04-01' = if (!skipContainerRegistry) {
  name: containerRegistryName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: true
  }
}

// Build agent pool profiles array conditionally
var agentPoolProfiles = concat(
  enableLinux
    ? [
        {
          name: 'agentpool'
          count: linuxNodeCount
          vmSize: linuxVmSize
          osType: 'Linux'
          mode: 'System'
          type: 'VirtualMachineScaleSets'
        }
      ]
    : [],
  enableWindows
    ? [
        {
          name: 'winp'
          count: windowsNodeCount
          vmSize: windowsVmSize
          osType: 'Windows'
          mode: 'User'
          type: 'VirtualMachineScaleSets'
          osDiskSizeGB: 128
        }
      ]
    : []
)

// Create an AKS managed cluster
resource aks 'Microsoft.ContainerService/managedClusters@2025-05-01' = if (!skipAks) {
  name: aksName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: dnsPrefix
    kubernetesVersion: empty(kubernetesVersion) ? null : kubernetesVersion
    enableRBAC: true
    agentPoolProfiles: agentPoolProfiles

    // Only include windowsProfile when Windows pools are requested. Windows requires an admin user/password.
    windowsProfile: enableWindows
      ? {
          adminUsername: windowsAdminUsername
          adminPassword: windowsAdminPassword
        }
      : null

    networkProfile: {
      networkPlugin: 'azure'
    }
  }
  dependsOn: (skipContainerRegistry ? [] : [containerRegistry])
}

// Grant the AKS system-assigned identity AcrPull role on the newly created ACR so nodes can pull images.

// Always return the registry name requested by the caller. When 'skipContainerRegistry' is true
// the template will not create the registry and this output reflects the existing registry name.
output containerRegistryName string = containerRegistryName
// Construct and return a login server value; when the registry is created this will match the
// registry's actual loginServer. When skipped, callers can still rely on the conventional
// '<name>.azurecr.io' form.
output containerRegistryLoginServer string = '${containerRegistryName}.azurecr.io'
output aksName string = aks.name
output aksResourceId string = aks.id
