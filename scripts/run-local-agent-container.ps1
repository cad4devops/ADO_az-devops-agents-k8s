[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ContainerRegistryName = $env:ACR_NAME,
    [Parameter(Mandatory = $false)]
    [ValidateSet('linux', 'windows')]
    [string]$Platform = 'linux',
    [Parameter(Mandatory = $false)]
    [string]$Tag = 'latest',
    [Parameter(Mandatory = $false)]
    [string]$RepositoryName,
    [Parameter(Mandatory = $false)]
    [string]$ContainerName,
    [Parameter(Mandatory = $false)]
    [switch]$Attach,
    [Parameter(Mandatory = $false)]
    [switch]$Kubernetes,
    [Parameter(Mandatory = $false)]
    [string]$Namespace = 'default',
    [Parameter(Mandatory = $false)]
    [hashtable]$AdditionalNodeSelector,
    [Parameter(Mandatory = $false)]
    [hashtable[]]$AdditionalTolerations,
    [Parameter(Mandatory = $false)]
    [string]$RuntimeClassName,
    [Parameter(Mandatory = $false)]
    [string]$ImagePullSecretName,
    [Parameter(Mandatory = $false)]
    [switch]$AzLogin,
    [Parameter(Mandatory = $false)]
    [string]$AcrUsername,
    [Parameter(Mandatory = $false)]
    [System.Security.SecureString]$AcrPassword,
    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$AcrCredential,
    [Parameter(Mandatory = $false)]
    [int]$KeepAliveSeconds = 7200,
    [Parameter(Mandatory = $false)]
    [int]$WaitReadyTimeoutSeconds = 0,
    [Parameter(Mandatory = $false)]
    [int]$HelloWaitSeconds = 180,
    [Parameter(Mandatory = $false)]
    [switch]$RunPipelineTests,
    [Parameter(Mandatory = $false, HelpMessage = 'Mount host docker socket (Linux only) at /var/run/docker.sock for in-container docker client access.')]
    [switch]$MountDockerSocket,
    [Parameter(Mandatory = $false, HelpMessage = 'After container start, attempt docker run hello-world inside it to validate non-root docker access (implies -MountDockerSocket if not in Kubernetes).')]
    [switch]$TestDockerHelloWorld,
    [Parameter(Mandatory = $false, HelpMessage = 'Full image reference (registry/repository:tag). Overrides ContainerRegistryName/RepositoryName/Tag when specified.')] 
    [string]$Image,
    [Parameter(Mandatory = $false, HelpMessage = 'Enable Docker-in-Docker (adds ENABLE_DIND=true env and privileged mode). Local only (non-Kubernetes).')] 
    [switch]$EnableDinD,
    [Parameter(Mandatory = $false, HelpMessage = 'Skip Azure DevOps agent configuration (SKIP_AGENT_CONFIG=true) for pure DinD/image validation.')] 
    [switch]$SkipAgentConfig
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Green([string]$msg) {
    try {
        if ($IsWindows) { Write-Host -ForegroundColor Green $msg }
        $podSpec.spec.imagePullSecrets = @(@{ name = $ImagePullSecretName; namespace = $Namespace })
    }
    catch { Write-Host $msg }
}

function ConvertTo-EncodedCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Script
    )

    return [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Script))
}

function Invoke-PipelineTests {
    param(
        [Parameter(Mandatory = $true)]
        [ScriptBlock]$Executor,
        [Parameter(Mandatory = $true)]
        [string]$Platform,
        [Parameter(Mandatory = $true)]
        [int]$HelloWaitSeconds
    )

    Write-Host "Running pipeline-equivalent validation for platform '$Platform'..."

    switch ($Platform) {
        'linux' {
            $verifyScript = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Write-Host ("PowerShell version: {0}" -f $PSVersionTable.PSVersion.ToString())
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'az CLI executable not found in PATH.'
}
$azInfoRaw = az version --output json --only-show-errors
if (-not $azInfoRaw) {
    throw 'az version returned no output.'
}
$azInfo = $azInfoRaw | ConvertFrom-Json
$coreVersion = $null
if ($azInfo.PSObject.Properties.Name -contains 'core') {
    $coreVersion = $azInfo.core
}
elseif ($azInfo.PSObject.Properties.Name -contains 'azure-cli-core') {
    $coreVersion = $azInfo.'azure-cli-core'
}
if (-not $coreVersion) {
    throw ("az CLI version payload missing 'core' or 'azure-cli-core' property. Raw payload: {0}" -f $azInfoRaw)
}
Write-Host ("az CLI core version: {0}" -f $coreVersion)
if ($azInfo.PSObject.Properties.Name -contains 'azure-cli-ml') {
    Write-Host ("azure-cli-ml extension version: {0}" -f $azInfo.'azure-cli-ml')
}
'@
            $encodedVerify = ConvertTo-EncodedCommand -Script $verifyScript
            & $Executor -Command @('pwsh', '-NoLogo', '-NoProfile', '-EncodedCommand', $encodedVerify) -Description 'Verify PowerShell & az CLI'

            $helloScript = "echo 'Hello, Welcome to DevOps ABCs World!'; echo 'Sleeping for $HelloWaitSeconds seconds...'; sleep $HelloWaitSeconds"
            & $Executor -Command @('/bin/bash', '-c', $helloScript) -Description "Hello World sleep ($HelloWaitSeconds s)"

            & $Executor -Command @('docker', '-v') -Description 'docker version check'
        }
        'windows' {
            $verifyScript = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Write-Host ("PowerShell version: {0}" -f $PSVersionTable.PSVersion.ToString())
            $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
            if ($pwsh) {
                try {
                    $pwshVersion = & $pwsh.Source -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
                    Write-Host ("pwsh version: {0}" -f $pwshVersion)
                }
                catch {
                    Write-Warning ("pwsh detected at {0} but version check failed: {1}" -f $pwsh.Source, $_)
                }
            }
            else {
                Write-Warning 'pwsh.exe not found in PATH. Skipping pwsh version check.'
            }
$azCli = Get-Command az -ErrorAction SilentlyContinue
if (-not $azCli) {
    Write-Warning 'az CLI executable not found in PATH. Skipping az version check.'
    return
}
$azInfoRaw = & $azCli.Source version --output json --only-show-errors
if (-not $azInfoRaw) {
    throw 'az version returned no output.'
}
$azInfo = $azInfoRaw | ConvertFrom-Json
$coreVersion = $null
if ($azInfo.PSObject.Properties.Name -contains 'core') {
    $coreVersion = $azInfo.core
}
elseif ($azInfo.PSObject.Properties.Name -contains 'azure-cli-core') {
    $coreVersion = $azInfo.'azure-cli-core'
}
if (-not $coreVersion) {
    throw ("az CLI version payload missing 'core' or 'azure-cli-core' property. Raw payload: {0}" -f $azInfoRaw)
}
Write-Host ("az CLI core version: {0}" -f $coreVersion)
if ($azInfo.PSObject.Properties.Name -contains 'azure-cli-ml') {
    Write-Host ("azure-cli-ml extension version: {0}" -f $azInfo.'azure-cli-ml')
}
'@
            $encodedVerify = ConvertTo-EncodedCommand -Script $verifyScript
            & $Executor -Command @('powershell.exe', '-NoLogo', '-NoProfile', '-EncodedCommand', $encodedVerify) -Description 'Verify PowerShell & az CLI'

            $cmdScript = 'echo Hello World && echo OS Version: && ver && echo System Information: && systeminfo && echo Hostname: && hostname'
            & $Executor -Command @('cmd.exe', '/c', $cmdScript) -Description 'Hello World diagnostics'

            $sleepScript = "Start-Sleep -Seconds $HelloWaitSeconds"
            $encodedSleep = ConvertTo-EncodedCommand -Script $sleepScript
            & $Executor -Command @('powershell.exe', '-NoLogo', '-NoProfile', '-EncodedCommand', $encodedSleep) -Description "Wait $HelloWaitSeconds seconds (hello-world)"
        }
        Default { throw "Unsupported platform '$Platform' for pipeline validation." }
    }

    Write-Green "Pipeline-equivalent validation completed for '$Platform'."
}

if ($Kubernetes) {
    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        throw 'kubectl command not found on PATH. Install kubectl and ensure it targets the desired cluster.'
    }
}
else {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw 'docker command not found on PATH. Install Docker Desktop / CLI before running this script.'
    }
}

if (-not $ContainerRegistryName) {
    $ContainerRegistryName = 'devopsabcsrunners'
}
if ($ContainerRegistryName -and ($ContainerRegistryName -notmatch '\.')) {
    Write-Host "Container registry '$ContainerRegistryName' appears unqualified; normalizing to Azure Container Registry FQDN."
    $ContainerRegistryName = "$ContainerRegistryName.azurecr.io"
}

if (-not $AcrUsername -and $env:ACR_USERNAME) {
    $AcrUsername = $env:ACR_USERNAME
}

if (-not $AcrCredential -and -not $AcrPassword -and $env:ACR_PASSWORD) {
    $AcrPassword = ConvertTo-SecureString -String $env:ACR_PASSWORD -AsPlainText -Force
}

if ($KeepAliveSeconds -le 0) {
    Write-Host 'KeepAliveSeconds must be greater than zero. Defaulting to 3600 seconds.'
    $KeepAliveSeconds = 3600
}

if ($WaitReadyTimeoutSeconds -le 0) {
    if ($Platform -eq 'windows') {
        $WaitReadyTimeoutSeconds = 900
    }
    else {
        $WaitReadyTimeoutSeconds = 300
    }
}

if ($HelloWaitSeconds -lt 0) {
    throw 'HelloWaitSeconds must be zero or greater.'
}

$acrNameShort = $null
if ($ContainerRegistryName -match '^(?<name>[^\.]+)\.azurecr\.io$') {
    $acrNameShort = $Matches['name']
}

if (-not $Kubernetes) {
    if ($AzLogin) {
        if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
            throw 'Requested -AzLogin but az CLI was not found on PATH.'
        }
        if (-not $acrNameShort) {
            throw 'Unable to derive the ACR name for az acr login. Provide a *.azurecr.io registry when using -AzLogin.'
        }
        Write-Host "Running az acr login for $acrNameShort..."
        & az acr login --name $acrNameShort --only-show-errors --output none
        if ($LASTEXITCODE -ne 0) {
            throw "az acr login failed with exit code $LASTEXITCODE"
        }
    }
    elseif ($AcrCredential -or $AcrPassword -or $AcrUsername) {
        $plainPassword = $null
        $passwordHandle = [IntPtr]::Zero
        try {
            if ($AcrCredential) {
                $AcrUsername = $AcrCredential.UserName
                $plainPassword = $AcrCredential.GetNetworkCredential().Password
            }
            elseif ($AcrUsername -and $AcrPassword) {
                $passwordHandle = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($AcrPassword)
                $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordHandle)
            }
            else {
                throw 'When providing manual credentials, specify both -AcrUsername and -AcrPassword or pass -AcrCredential.'
            }

            Write-Host "Authenticating to $ContainerRegistryName with provided username..."
            $loginArgs = @('login', $ContainerRegistryName, '--username', $AcrUsername, '--password-stdin')
            $dockerLoginOutput = $plainPassword | & docker @loginArgs 2>&1
            if ($dockerLoginOutput) { Write-Host $dockerLoginOutput.TrimEnd() }
            if ($LASTEXITCODE -ne 0) {
                throw "docker login failed with exit code $LASTEXITCODE"
            }
        }
        finally {
            if ($passwordHandle -ne [IntPtr]::Zero) {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordHandle)
            }
            $plainPassword = $null
            $AcrCredential = $null
            $AcrPassword = $null
        }
    }
}
elseif ($AzLogin -or $AcrCredential -or $AcrPassword -or $AcrUsername) {
    Write-Host 'Ignoring local docker authentication parameters because -Kubernetes was specified.'
}

$dockerEntrypointArgs = @()
$dockerCommandArgs = @()
$podCommand = @()
$podArgs = @()
$nodeOsLabel = $Platform
$defaultShell = $null
$podTolerations = @()
$runtimeClassName = $null

switch ($Platform) {
    'linux' {
        if (-not $RepositoryName) { $RepositoryName = 'linux-sh-agent-docker' }
        $defaultShell = '/bin/bash'

        if ($EnableDinD) {
            Write-Host 'EnableDinD requested; using image''s default entrypoint so dockerd bootstrap can run.'
            $dockerEntrypointArgs = @()
            $dockerCommandArgs = @()
            $podCommand = $null
            $podArgs = $null
        }
        else {
            $dockerEntrypointArgs = @('--entrypoint', '/bin/sh')
            $dockerCommandArgs = @('-c', ('trap ''exit 0'' TERM; sleep {0}' -f $KeepAliveSeconds))
            $podCommand = @('/bin/sh')
            $podArgs = @('-c', ('trap ''exit 0'' TERM; sleep {0}' -f $KeepAliveSeconds))
        }

        if ($TestDockerHelloWorld -and -not $MountDockerSocket -and -not $Kubernetes -and -not $EnableDinD) { $MountDockerSocket = $true }
        $nodeOsLabel = 'linux'
    }
    'windows' {
        if (-not $RepositoryName) { $RepositoryName = 'windows-sh-agent-2022' }
        $defaultShell = 'pwsh.exe'
        $dockerEntrypointArgs = @('--entrypoint', 'pwsh.exe')
        $commandText = '[DateTime]$end = (Get-Date).AddSeconds({0}); while ((Get-Date) -lt $end) {{ Start-Sleep -Seconds 30 }}' -f $KeepAliveSeconds
        $dockerCommandArgs = @('-NoLogo', '-NoProfile', '-Command', $commandText)
        $podCommand = @('pwsh.exe')
        $podArgs = @('-NoLogo', '-NoProfile', '-Command', $commandText)
        $nodeOsLabel = 'windows'
        $podTolerations += @{
            key      = 'os'
            operator = 'Equal'
            value    = 'windows'
            effect   = 'NoSchedule'
        }
        $podTolerations += @{
            key      = 'sku'
            operator = 'Equal'
            value    = 'Windows'
            effect   = 'NoSchedule'
        }
        if ($RuntimeClassName) {
            $runtimeClassName = $RuntimeClassName
        }
        elseif ($Kubernetes) {
            $defaultRuntimeClass = 'runhcs-wcow-process'
            $runtimeProbeArgs = @('get', 'runtimeclass', $defaultRuntimeClass, '-o', 'name')
            $runtimeProbeOutput = & kubectl @runtimeProbeArgs 2>$null
            if ($LASTEXITCODE -eq 0 -and $runtimeProbeOutput) {
                $runtimeClassName = $defaultRuntimeClass
            }
            else {
                Write-Host "RuntimeClass '$defaultRuntimeClass' not found; continuing without runtime class. Use -RuntimeClassName to specify one if required."
                $runtimeClassName = $null
            }
        }
    }
    default { throw "Unsupported platform '$Platform'" }
}

if ($Image) {
    Write-Host "Using explicit -Image '$Image' (overrides registry/repository/tag parameters)."
    $image = $Image
}
else {
    $image = '{0}/{1}:{2}' -f $ContainerRegistryName, $RepositoryName, $Tag
}
if (-not $ContainerName) {
    $rand = [Guid]::NewGuid().ToString('N').Substring(0, 6)
    $ContainerName = "agent-inspect-$($Platform.Substring(0,1))$rand"
}

Write-Host "Using image: $image"
Write-Host "Container name: $ContainerName"

# Kubernetes execution path
if ($Kubernetes) {
    $podName = $ContainerName
    $namespaceArgs = @()
    $namespaceText = ''
    if ($Namespace) {
        $namespaceArgs = @('-n', $Namespace)
        $namespaceText = " in namespace '$Namespace'"
    }

    Write-Host "Deleting any existing pod named '$podName'$namespaceText..."
    $deleteArgs = @('delete', 'pod', $podName, '--ignore-not-found=true') + $namespaceArgs
    & kubectl @deleteArgs | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl delete failed with exit code $LASTEXITCODE"
    }

    if ($ImagePullSecretName) {
        $secretArgs = @('get', 'secret', $ImagePullSecretName, '-o', 'json') + $namespaceArgs
        $secretResult = & kubectl @secretArgs 2>&1
        if ($LASTEXITCODE -ne 0 -or -not $secretResult) {
            throw "Image pull secret '$ImagePullSecretName' not found in namespace '$Namespace'."
        }
        try {
            $secretObject = $secretResult | ConvertFrom-Json
            if ($secretObject.type -ne 'kubernetes.io/dockerconfigjson') {
                Write-Host "Warning: Secret '$ImagePullSecretName' has type '$($secretObject.type)' (expected 'kubernetes.io/dockerconfigjson')."
            }
        }
        catch {
            Write-Host "Warning: Unable to parse secret '$ImagePullSecretName'; proceeding anyway."
        }
    }

    $containerSpec = @{
        name            = 'inspect'
        image           = $image
        imagePullPolicy = 'Always'
    }
    if ($podCommand -and $podCommand.Count -gt 0) { $containerSpec.command = $podCommand }
    if ($podArgs -and $podArgs.Count -gt 0) { $containerSpec.args = $podArgs }

    $podSpec = @{
        apiVersion = 'v1'
        kind       = 'Pod'
        metadata   = @{ name = $podName }
        spec       = @{
            restartPolicy                 = 'Never'
            terminationGracePeriodSeconds = 5
            containers                    = @($containerSpec)
        }
    }

    $nodeSelectorMap = @{}
    if ($nodeOsLabel) {
        $nodeSelectorMap['kubernetes.io/os'] = $nodeOsLabel
    }
    if ($AdditionalNodeSelector) {
        foreach ($key in $AdditionalNodeSelector.Keys) {
            $nodeSelectorMap[$key] = $AdditionalNodeSelector[$key]
        }
    }
    if ($nodeSelectorMap.Count -gt 0) {
        $podSpec.spec.nodeSelector = $nodeSelectorMap
    }

    if ($AdditionalTolerations) {
        $podTolerations += $AdditionalTolerations
    }
    if ($podTolerations.Count -gt 0) {
        $podSpec.spec.tolerations = $podTolerations
    }

    if ($runtimeClassName) {
        $podSpec.spec.runtimeClassName = $runtimeClassName
    }

    if ($ImagePullSecretName) {
        $podSpec.spec.imagePullSecrets = @(@{ name = $ImagePullSecretName })
    }

    $manifestPath = [System.IO.Path]::GetTempFileName()
    try {
        $podSpec | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestPath -Encoding UTF8

        Write-Host 'Creating pod and forcing image re-pull (imagePullPolicy: Always)...'
        $applyArgs = @('apply', '-f', $manifestPath) + $namespaceArgs
        & kubectl @applyArgs | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) {
            throw "kubectl apply failed with exit code $LASTEXITCODE"
        }

        $waitArgs = @('wait', '--for=condition=Ready', "pod/$podName", ('--timeout={0}s' -f $WaitReadyTimeoutSeconds)) + $namespaceArgs
        & kubectl @waitArgs | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) {
            Write-Host ("kubectl wait timed out after {0} seconds. Override with -WaitReadyTimeoutSeconds if needed." -f $WaitReadyTimeoutSeconds)
            throw "kubectl wait failed with exit code $LASTEXITCODE"
        }

        if ($RunPipelineTests) {
            $executor = {
                param(
                    [Parameter(Mandatory = $true)][string[]]$Command,
                    [Parameter(Mandatory = $true)][string]$Description
                )

                $execArgs = @('exec', '-i', $podName)
                if ($Namespace) { $execArgs += @('-n', $Namespace) }
                $execArgs += @('--') + $Command
                Write-Host ("Executing in pod ({0}): {1}" -f $Description, ($Command -join ' '))
                & kubectl @execArgs
                if ($LASTEXITCODE -ne 0) {
                    throw "kubectl exec for '$Description' failed with exit code $LASTEXITCODE"
                }
            }

            Invoke-PipelineTests -Executor $executor -Platform $Platform -HelloWaitSeconds $HelloWaitSeconds
        }
    }
    finally {
        Remove-Item -Path $manifestPath -ErrorAction SilentlyContinue
    }

    Write-Green "Pod '$podName'$namespaceText is running with imagePullPolicy=Always."
    Write-Host ('Pod command keeps container ready for roughly {0} seconds; override with -KeepAliveSeconds.' -f $KeepAliveSeconds)
    $execInstruction = "kubectl exec"
    if ($Namespace) { $execInstruction += " -n $Namespace" }
    $execInstruction += " -it $podName -- $defaultShell"
    Write-Host 'Use the following command to open an interactive shell:'
    Write-Host "  $execInstruction"

    if ($Attach) {
        Write-Host 'Attaching to the pod...'
        $execArgs = @('exec')
        if ($Namespace) { $execArgs += @('-n', $Namespace) }
        $execArgs += @('-it', $podName, '--', $defaultShell)
        & kubectl @execArgs
    }
    else {
        Write-Host 'Set -Attach to open an interactive shell immediately.'
    }

    $cleanupInstruction = "kubectl delete pod $podName"
    if ($Namespace) { $cleanupInstruction += " -n $Namespace" }
    Write-Host 'When finished, remove the pod:'
    Write-Host "  $cleanupInstruction"

    return
}

# Ensure no existing container with the same name
$existing = docker ps -a --filter "name=^/${ContainerName}$" --format '{{.ID}}'
if ($existing) {
    throw "A container named '$ContainerName' already exists (ID: $existing). Remove it (docker rm -f $ContainerName) or specify -ContainerName."
}

Write-Host 'Pulling latest image information (docker pull)...'
& docker pull $image
$pullExit = $LASTEXITCODE
if ($pullExit -ne 0) {
    $loginHint = 'Ensure you are authenticated to the registry. Try "az acr login -n {0}" or supply -AcrUsername/-AcrPassword.' -f ($acrNameShort ? $acrNameShort : $ContainerRegistryName)
    throw "docker pull failed with exit code $pullExit. $loginHint"
}

$runArgs = @('run', '-d', '--name', $ContainerName)
if ($EnableDinD -and -not $Kubernetes -and $Platform -eq 'linux') {
    # DinD requires privileged and a writable /var/lib/docker. Use emptyDir via host tmpfs optional? Simpler: anonymous volume mount.
    $runArgs += @('--privileged', '-v', "${ContainerName}-dind-data:/var/lib/docker", '-e', 'ENABLE_DIND=true')
    if ($SkipAgentConfig) { $runArgs += @('-e', 'SKIP_AGENT_CONFIG=true') }
}
$runArgs += $dockerEntrypointArgs + @($image) + $dockerCommandArgs
if (-not $Kubernetes -and $Platform -eq 'linux' -and $MountDockerSocket -and -not $EnableDinD) {
    # Discover host docker.sock group id by using a tiny helper container (avoids platform/stat differences on host)
    $socketGid = $null
    $probeImages = @('alpine:3.20', 'busybox:latest')
    foreach ($pi in $probeImages) {
        & docker pull $pi 2>$null | Out-String | Out-Null
        $gidAttempt = (& docker run --rm -v /var/run/docker.sock:/var/run/docker.sock $pi sh -c "stat -c %g /var/run/docker.sock" 2>$null)
        if ($LASTEXITCODE -eq 0 -and $gidAttempt -match '^[0-9]+$') { $socketGid = $gidAttempt.Trim(); break }
    }
    if ($socketGid) {
        Write-Host "Detected host docker.sock GID: $socketGid (will add supplementary group)"
    }
    else {
        Write-Host "Warning: Could not determine docker.sock GID; proceeding without --group-add. Non-root docker may fail." -ForegroundColor Yellow
    }

    # Build run args with volume mount (and optional group-add)
    $baseArgs = @('run', '-d', '--name', $ContainerName)
    $volArgs = @('-v', '/var/run/docker.sock:/var/run/docker.sock')
    $extraGroupArgs = @()
    if ($socketGid) { $extraGroupArgs = @('--group-add', $socketGid) }
    $runArgs = $baseArgs + $volArgs + $extraGroupArgs + $dockerEntrypointArgs + @($image) + $dockerCommandArgs
}
Write-Host "Starting container:`n  docker $($runArgs -join ' ')"
& docker @runArgs
if ($LASTEXITCODE -ne 0) {
    throw "docker run exited with code $LASTEXITCODE"
}

Write-Green "Container '$ContainerName' is running."

if ($RunPipelineTests) {
    $executor = {
        param(
            [Parameter(Mandatory = $true)][string[]]$Command,
            [Parameter(Mandatory = $true)][string]$Description
        )

        $execArgs = @('exec', '-i', $ContainerName) + $Command
        Write-Host ("Executing in container ({0}): {1}" -f $Description, ($Command -join ' '))
        & docker @execArgs
        if ($LASTEXITCODE -ne 0) {
            throw "docker exec for '$Description' failed with exit code $LASTEXITCODE"
        }
    }

    Invoke-PipelineTests -Executor $executor -Platform $Platform -HelloWaitSeconds $HelloWaitSeconds
}

# Optional automated hello-world docker test (local linux path only)
if (-not $Kubernetes -and $Platform -eq 'linux' -and $TestDockerHelloWorld) {
    if ($EnableDinD) {
        Write-Host 'Waiting for internal Docker daemon (DinD) to be ready...'
        $max = 30; $count = 0; $ready = $false
        while ($count -lt $max) {
            & docker exec -i $ContainerName docker info >$null 2>&1
            if ($LASTEXITCODE -eq 0) { $ready = $true; break }
            Start-Sleep -Seconds 1
            $count++
        }
        if (-not $ready) { Write-Host 'Warning: internal dockerd did not become ready within 30s.' -ForegroundColor Yellow }
    }
    Write-Host 'Running in-container docker hello-world validation...'
    $execCmd = @('exec', '-i', $ContainerName, 'docker', 'run', '--rm', 'hello-world')
    & docker @execCmd
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) {
        Write-Green 'SUCCESS: docker run hello-world completed inside container.'
    }
    else {
        Write-Host "FAILED: docker run hello-world exited with code $exitCode" -ForegroundColor Red
        Write-Host 'Attempting to capture docker info (may fail if client cannot reach daemon)...'
        & docker exec -i $ContainerName docker info 2>&1 | Select-Object -First 80 | ForEach-Object { Write-Host $_ }
    }
}

Write-Host ('Container will remain running for approximately {0} seconds; override with -KeepAliveSeconds.' -f $KeepAliveSeconds)
Write-Host 'Use the following command to inspect the container:'
if ($Platform -eq 'windows') {
    Write-Host "  docker exec -it $ContainerName $defaultShell"
}
else {
    Write-Host "  docker exec -it $ContainerName $defaultShell"
}

if ($Attach) {
    Write-Host 'Attaching to the container...'
    & docker exec -it $ContainerName $defaultShell
}
else {
    Write-Host 'Set -Attach to drop into the container automatically.'
}

Write-Host 'When finished, stop and remove the container:'
Write-Host "  docker rm -f $ContainerName"
