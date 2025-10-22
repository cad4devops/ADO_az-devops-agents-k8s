param(
    [Parameter(Mandatory = $true)][string]$NodeName,
    [string]$Namespace = 'kube-system',
    [string]$PodName,
    [string]$Command
)

if (-not $PodName) {
    $safeNode = $NodeName.ToLowerInvariant() -replace '[^a-z0-9-]', '-'
    $safeNode = $safeNode.Trim('-')
    if (-not $safeNode) { $safeNode = "node-$([Math]::Abs($NodeName.GetHashCode()))" }
    if ($safeNode.Length -gt 40) { $safeNode = $safeNode.Substring(0, 40) }
    $PodName = "win-host-shell-$safeNode"
}

if (-not $Command) {
    $Command = @'
Write-Host "docker.exe listing:"
dir "C:\Program Files\Docker\Docker\resources\bin\docker.exe"
Write-Host "`nDocker service status:"
Get-Service docker
Write-Host "`nPATH:"
$env:PATH
Write-Host "`nwhoami:"
whoami
'@
}

$yaml = @"
apiVersion: v1
kind: Pod
metadata:
  name: $PodName
  namespace: $Namespace
spec:
  nodeName: $NodeName
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
  securityContext:
    windowsOptions:
      hostProcess: true
      runAsUserName: 'NT AUTHORITY\SYSTEM'
  containers:
  - name: shell
    image: mcr.microsoft.com/powershell:lts-7.4-windowsservercore-ltsc2022
    command:
    - C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
    - -NoLogo
    - -NoProfile
    - -Command
    - Start-Sleep -Seconds 3600
  restartPolicy: Never
"@

# Create the host-process pod and wait for it to be ready before attaching
try {
    $yaml | kubectl apply -f - | Out-Null

    $deadline = (Get-Date).AddSeconds(120)
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        $phase = (kubectl get pod -n $Namespace $PodName -o jsonpath='{.status.phase}' 2>$null).Trim()
        if ($phase -eq 'Running') { $ready = $true; break }
        if ($phase -eq 'Failed') { throw "Pod $PodName failed to start." }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) {
        throw "Timed out waiting for pod $PodName to become Running."
    }

    # Open a PowerShell session in the pod (runs as SYSTEM on the node)
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Command))
    kubectl exec -n $Namespace $PodName -- powershell -NoLogo -NoProfile -EncodedCommand $encoded
}
finally {
    kubectl delete pod -n $Namespace $PodName --ignore-not-found | Out-Null
}