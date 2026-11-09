[CmdletBinding()]
param([string]$ProjectName = 'planner-server', [string]$ConfigPath = '', [int]$WaitSeconds = 180)
. "$PSScriptRoot/Common.ps1"
Initialize-Context -ProjectName $ProjectName -ConfigPath $ConfigPath
$lock = Enter-OperationLock
try {
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        & docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { break }
        if ((Get-Date) -ge $deadline) { throw 'Docker Engine did not become ready. Start Docker Desktop.' }
        Start-Sleep -Seconds 3
    } while ($true)
    Invoke-Compose -Arguments @('config', '--quiet')
    $version = Get-PackageVersion
    $image = 'planner-server:' + $version
    & docker image inspect $image --format '{{.Id}}' 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Server image is missing. Run Build-Server.ps1 once before Start-Server.ps1.' }
    Invoke-Compose -Arguments @('up', '-d', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '180', 'api', 'worker')
    $ready = Wait-LocalReady -ExpectedVersion $version
    Write-OperationResult 'start' @{ success = $true; version = $ready.version }
    Write-Host ('Server ready: ' + $ready.version + '. No images were built or downloaded during startup.')
} finally { $lock.Dispose() }
