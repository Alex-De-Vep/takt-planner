[CmdletBinding()]
param([string]$ProjectName = 'planner-server', [string]$ConfigPath = '', [switch]$Results)
. "$PSScriptRoot/Common.ps1"
Initialize-Context -ProjectName $ProjectName -ConfigPath $ConfigPath
Assert-Docker
if ($Results) {
    $state = (Invoke-Compose -Arguments @('exec', '-T', 'api', 'node', 'dist/main.js', 'diagnose') -Capture) | ConvertFrom-Json
    $state.proxy | ConvertTo-Json -Depth 6
    return
}
$probe = (Invoke-Compose -Arguments @('exec', '-T', 'api', 'node', 'dist/main.js', 'proxy-probe-start') -Capture) | ConvertFrom-Json
$origin = Read-EnvValue 'PUBLIC_BASE_URL'
$url = $origin.TrimEnd('/') + '/health/live?plannerProxyProbe=' + $probe.token
Write-Host 'Open this temporary URL from two external networks (for example mobile data and another connection):'
Write-Host $url
Write-Host ('Probe expires at UTC ' + $probe.expiresAt)
Invoke-WebRequest -Uri $url -Headers @{ 'X-Forwarded-For' = '203.0.113.123' } -UseBasicParsing -TimeoutSec 20 | Out-Null
Write-Host 'A local request with a spoofed header was also sent through Funnel. Inspect results with Test-Proxy.ps1 -Results.'
Write-Host 'Set TRUSTED_PROXY_CIDRS to the exact socketAddress seen by the container, then restart and repeat. Never use wildcard trust.'
