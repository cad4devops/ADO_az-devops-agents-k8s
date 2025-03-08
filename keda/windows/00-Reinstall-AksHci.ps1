# alternative
# https://learn.microsoft.com/en-us/azure/aks/aksarc/kubernetes-walkthrough-powershell

$instanceName = "010" # change this to a unique value for your environment
$windowsVersion = "2025" #2022
$networkName = "aks-default-network-$instanceName"
$workingDir = "f:\\AksHCI$instanceName"
$cloudConfigLocation = "f:\\AksHCI$instanceName\\Config"
$imageDir = "f:\\AksHCI$instanceName\\ImageStore"
$subscriptionId = "c2d56f43-9820-4865-b8c4-7a369ed95e61"
$location = "eastus"
$resourceGroupName = "rg-aks-hybrid-arc-mgmt-cluster-dev-$instanceName"
$tenantId = "a34c69c7-8959-474a-9690-e98bfb0b55c6"


# working example for creating a new management cluster for AKS hybrid version​​​​ 1.0.25.10226
Uninstall-AksHci

Write-Output "AksHci Uninstall complete. Please delete previous folder $workingDir ."
# press any key to continue
# pause and wait for user input
Read-Host -Prompt "Press Enter to continue"

Get-Command -Module AksHci

Get-AzContext

Get-AzResourceProvider -ProviderNamespace Microsoft.Kubernetes
Get-AzResourceProvider -ProviderNamespace Microsoft.KubernetesConfiguration
Get-AzResourceProvider -ProviderNamespace Microsoft.ExtendedLocation

Initialize-AksHciNode

Write-Output "AksHci Node Initialized. Press any key to continue."
# press any key to continue
# pause and wait for user input
Read-Host -Prompt "Press Enter to continue"

$vnet = New-AksHciNetworkSetting -name $networkName `
    -vswitchName "external vlan 168" `
    -vipPoolStart "192.168.168.50" `
    -vipPoolEnd "192.168.168.59"	
	
Set-AksHciConfig -workingDir $workingDir `
    -cloudConfigLocation $cloudConfigLocation `
    -imageDir $imageDir `
    -vnet $vnet `
    -verbose

Write-Output "AksHci Config set. Press any key to continue."
# press any key to continue
# pause and wait for user input
Read-Host -Prompt "Press Enter to continue"

az account show
az account set --subscription $subscriptionId
az group create -n $resourceGroupName `
    -l $location	

Write-Output "AksHci Resource Group created. Delete previous resource group such as $resourceGroupName . Press any key to continue."
# press any key to continue
# pause and wait for user input
Read-Host -Prompt "Press Enter to continue"

Set-AksHciRegistration -subscriptionId $subscriptionId `
    -resourceGroupName $resourceGroupName `
    -TenantId $tenantId `
    -UseDeviceAuthentication

Write-Output "AksHci Registration set. Verify Azure Portal for $resourceGroupName . Press any key to continue."
# press any key to continue
# pause and wait for user input
Read-Host -Prompt "Press Enter to continue"

$VerbosePreference = "Continue" #before proceeding.

Install-AksHci

Write-Output "AksHci Installed. Ensure management cluster is created in Hyper-V. Press any key to continue."
# press any key to continue
# pause and wait for user input
Read-Host -Prompt "Press Enter to continue"

# now you can create a new workload cluster
$clusterName = "workload-cluster-$instanceName"

$clusterNodeCountLinux = 3
$nodePoolNameLinux = "workload-cluster-$instanceName-linux-pool-001"
$nodeVmSizeLinux = "Standard_D2s_v3" #Standard_K8S3_v1
$kubernetesVersion = "v1.29.4"

$clusterNodeCountWindows = 3
$nodePoolNameWindows = "workload-cluster-$instanceName-windows${windowsVersion}-pool-001"
$nodeVmSizeWindows = "Standard_D2s_v3" #Standard_K8S3_v1
$windowsOsSku = "Windows${windowsVersion}" #2022


# New-AksHciCluster -name mycluster -nodePoolName nodepool1 -nodeCount 1 -nodeVmSize Standard_K8S3_v1 -osType Windows -osSku Windows2022
New-AksHciCluster -name $clusterName `
    -nodePoolName $nodePoolNameLinux `
    -nodeCount $clusterNodeCountLinux `
    -nodeVmSize $nodeVmSizeLinux `
    -osType Linux `
    -kubernetesVersion $kubernetesVersion

Write-Output "AksHci Cluster created. Verify Hyper-V for $clusterName . Press any key to continue."
# press any key to continue
# pause and wait for user input
Read-Host -Prompt "Press Enter to continue"

# New-AksHciNodePool -clusterName <cluster-name> -nodePoolNAme taintnp -count 1 -osType Windows -osSku Windows2022 -taints sku=Windows:NoSchedule
New-AksHciNodePool -clusterName $clusterName `
    -name $nodePoolNameWindows `
    -count $clusterNodeCountWindows `
    -vmSize $nodeVmSizeWindows `
    -osType Windows `
    -osSku $windowsOsSku `
    -taints sku=windows:NoSchedule

Write-Output "AksHci Node Pool created. Verify Hyper-V for $nodePoolNameWindows . All Done. Press any key to continue."
# press any key to continue
# pause and wait for user input
Read-Host -Prompt "Press Enter to continue"

# end of working example