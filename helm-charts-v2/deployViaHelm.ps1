# create namespaces if not exists


param (
    [Parameter()]
    [string]
    $instanceNumber = "001",
    [Parameter()]
    [string]
    $linuxNamespace = "az-devops-linux-$instanceNumber",
    [Parameter()]
    [string]
    $windowsNamespace = "az-devops-windows-$instanceNumber",
    [Parameter()]
    [string]
    $linuxPoolName = "KubernetesPoolLinux",
    [Parameter()]
    [string]        
    $windowsPoolName = "KubernetesPoolWindows",
    [Parameter()]
    [string]
    $organizationUrl = "https://dev.azure.com/cad4devops",
    [Parameter(Mandatory = $true)]
    [string]
    $dockerConfigJsonValueBase64,
    [Parameter(Mandatory = $false)]
    [string]
    $helmReleaseName = "az-selfhosted-agents-$instanceNumber"
)

# get pat from environment variable
$pat = $env:AZURE_DEVOPS_EXT_PAT
if (-not $pat) {
    Write-Error "Please set the AZURE_DEVOPS_EXT_PAT environment variable."
    exit 1
}

# ech parameters
Write-Output "Organization URL: $organizationUrl"
Write-Output "Instance Number: $instanceNumber"
# Set the Azure DevOps organization URL and personal access token (PAT)
Write-Output "Using PAT: $($pat.Substring(0, 3))... (truncated for security)"
# docker config json value
$dockerConfigJsonValue = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($dockerConfigJsonValueBase64))
Write-Output "Helm Release Name: $helmReleaseName"

Write-Output "Linux Namespace: $linuxNamespace"
Write-Output "Windows Namespace: $windowsNamespace"
Write-Output "Linux Pool Name: $linuxPoolName"
Write-Output "Windows Pool Name: $windowsPoolName"
Write-Output "Docker Config JSON Value: $($dockerConfigJsonValue.Substring(0, 50))... (truncated for security)"

# convert the pool name to base64
$linuxPoolNameBase64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($linuxPoolName))
$windowsPoolNameBase64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($windowsPoolName))
$organizationUrlBase64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($organizationUrl))
$patBase64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pat))

Write-Output "Linux Pool Name Base64: $linuxPoolNameBase64"
Write-Output "Windows Pool Name Base64: $windowsPoolNameBase64"
Write-Output "Organization URL Base64: $organizationUrlBase64"
# truncated for security
Write-Output "PAT Base64: $($patBase64.Substring(0, 3))... (truncated for security)"

Write-Output "Getting pool ids from linux and windows agent pools"
$linuxPoolId = az pipelines pool list --query "[?name=='$linuxPoolName'].id" -o tsv
$windowsPoolId = az pipelines pool list --query "[?name=='$windowsPoolName'].id" -o tsv
Write-Output "Linux Pool ID: $linuxPoolId"
Write-Output "Windows Pool ID: $windowsPoolId"

# check if helm chart is already installed
$helmInstalled = helm list -n $linuxNamespace | Select-String -Pattern "$helmReleaseName"
if ($helmInstalled) {
    Write-Output "Helm chart $helmReleaseName is already installed. Skipping..."
    #helm uninstall $helmReleaseName --namespace $linuxNamespace
}
else {
    Write-Output "Helm chart $helmReleaseName is not installed. Installing..."

    Write-Output "Creating namespaces if not exists"
    kubectl create namespace $linuxNamespace --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace $windowsNamespace --dry-run=client -o yaml | kubectl apply -f -

    helm install $helmReleaseName ./az-selfhosted-agents `
        --set windows.enabled=true `
        --set windowsNamespace=$windowsNamespace `
        --set secretwindows.data.AZP_TOKEN_VALUE=$patBase64 `
        --set secretwindows.data.AZP_POOL_VALUE=$windowsPoolNameBase64 `
        --set secretwindows.data.AZP_URL_VALUE=$organizationUrlBase64 `
        --set poolID.windows=$windowsPoolId `
        --set linux.enabled=true `
        --set linuxNamespace=$linuxNamespace `
        --set secretlinux.data.AZP_TOKEN_VALUE=$patBase64 `
        --set secretlinux.data.AZP_POOL_VALUE=$linuxPoolNameBase64 `
        --set secretlinux.data.AZP_URL_VALUE=$organizationUrlBase64 `
        --set regsecret.data.DOCKER_CONFIG_JSON_VALUE=$dockerConfigJsonValueBase64 `
        --set poolID.linux=$linuxPoolId `
        --create-namespace `
        --namespace $linuxNamespace
}
