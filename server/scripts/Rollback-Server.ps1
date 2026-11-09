[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$PreviousApp, [string]$ProjectName = 'planner-server', [string]$ConfigPath = '')
# Run from installed 0.1.1, before replacing its directory. Retains current data: SQL schema is unchanged.
. "$PSScriptRoot/Common.ps1"
Initialize-Context -ProjectName $ProjectName -ConfigPath $ConfigPath
Assert-Docker
$previous = [System.IO.Path]::GetFullPath($PreviousApp)
$releases = [System.IO.Path]::GetFullPath((Join-Path $script:InstallRoot 'releases'))
if (-not $previous.StartsWith($releases + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Choose the retained app under this installation releases directory.' }
Assert-Delivery -Root $previous -Required
if ((Get-PackageVersion) -ne '0.1.1' -or (Get-PackageVersion -Root $previous) -ne '0.1.0') { throw 'Only the documented 0.1.1 to 0.1.0 application rollback is supported.' }
$oldOverride = $env:PLANNER_SERVER_VERSION
$lock = Enter-OperationLock
$failedApp = Join-Path $releases ('0.1.1-before-rollback-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))
$replaced = $false
try {
    & docker image inspect 'planner-server:0.1.0' --format '{{.Id}}' 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Retained image planner-server:0.1.0 is missing.' }
    & (Join-Path $PSScriptRoot 'Backup-Server.ps1') -ProjectName $ProjectName -ConfigPath $script:ConfigPath -FullCheck -OperationLockHandle $lock
    Copy-Item -LiteralPath $script:AppRoot -Destination $failedApp -Recurse
    Invoke-Compose -Arguments @('stop', 'api', 'worker')
    $replaced = $true
    Get-ChildItem -LiteralPath $script:AppRoot -Force | Remove-Item -Recurse -Force
    Get-ChildItem -LiteralPath $previous -Force | Copy-Item -Destination $script:AppRoot -Recurse -Force
    $env:PLANNER_SERVER_VERSION = '0.1.0'
    Invoke-Compose -Arguments @('up', '-d', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '180', 'api', 'worker')
    $ready = Wait-LocalReady -ExpectedVersion '0.1.0'
    Write-OperationResult 'rollback' @{ success = $true; version = $ready.version; retainedApp = $failedApp }
    Write-Host 'Application returned to 0.1.0. Current database and blobs were retained; no database backup was restored.'
} catch {
    if ($replaced) {
        try {
            & docker stop ($ProjectName + '-api-1') ($ProjectName + '-worker-1') 2>$null | Out-Null
            Get-ChildItem -LiteralPath $script:AppRoot -Force | Remove-Item -Recurse -Force
            Get-ChildItem -LiteralPath $failedApp -Force | Copy-Item -Destination $script:AppRoot -Recurse -Force
            $env:PLANNER_SERVER_VERSION = '0.1.1'
            Invoke-Compose -Arguments @('up', '-d', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '180', 'api', 'worker')
        } catch { Write-Warning 'Could not restart retained 0.1.1. Consult the update guide.' }
    }
    throw
} finally { $env:PLANNER_SERVER_VERSION = $oldOverride; $lock.Dispose() }
