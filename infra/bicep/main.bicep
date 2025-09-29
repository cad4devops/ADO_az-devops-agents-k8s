// Parameters
param location string = resourceGroup().location
param instanceNumber string

@minLength(5)
param containerRegistryName string = toLower('cragents${instanceNumber}${uniqueString(resourceGroup().id)}')

@allowed([ 'Standard_D2s_v3', 'Standard_D4s_v3', 'Standard_DS2_v2' ])
param linuxVmSize string = 'Standard_D2s_v3'

@allowed([ 'Standard_D2s_v3', 'Standard_D4s_v3', 'Standard_DS2_v2' ])
param windowsVmSize string = 'Standard_D2s_v3'

param linuxNodeCount int = 1
param windowsNodeCount int = 1

param enableLinux bool = true
param enableWindows bool = false

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
resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
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
  enableLinux ? [
    {
      name: 'agentpool'
      count: linuxNodeCount
      vmSize: linuxVmSize
      osType: 'Linux'
      mode: 'System'
      type: 'VirtualMachineScaleSets'
    }
  ] : [],
  enableWindows ? [
    {
      name: 'winpool'
      count: windowsNodeCount
      vmSize: windowsVmSize
      osType: 'Windows'
      mode: 'User'
      type: 'VirtualMachineScaleSets'
      osDiskSizeGB: 128
    }
  ] : []
)

// Create an AKS managed cluster
resource aks 'Microsoft.ContainerService/managedClusters@2023-08-01' = if (!skipAks) {
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
    windowsProfile: enableWindows ? {
      adminUsername: windowsAdminUsername
      adminPassword: windowsAdminPassword
    } : null

    networkProfile: {
      networkPlugin: 'azure'
    }
  }
  dependsOn: [ containerRegistry ]
}

// Grant the AKS system-assigned identity AcrPull role on the newly created ACR so nodes can pull images.


output containerRegistryName string = containerRegistry.name
output containerRegistryLoginServer string = containerRegistry.properties.loginServer
output aksName string = aks.name
output aksResourceId string = aks.id
