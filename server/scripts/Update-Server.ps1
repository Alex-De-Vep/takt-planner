[CmdletBinding()]
param([Alias('InstallRoot')][string]$TargetRoot = 'C:\PlannerServer', [string]$ProjectName = 'planner-server', [string]$ConfigPath = '')
# Run THIS script from the extracted NEW delivery, not from the old installation.
. "$PSScriptRoot/Common.ps1"
$sourceApp = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
Assert-Delivery -Root $sourceApp -Required
$targetVersion = Get-PackageVersion -Root $sourceApp
if ($targetVersion -ne '0.1.1') { throw 'This updater is for delivery 0.1.1.' }
$script:InstallRoot = [System.IO.Path]::GetFullPath($TargetRoot)
$script:AppRoot = Join-Path $script:InstallRoot 'app'
$script:ComposePath = Join-Path $script:AppRoot 'compose.yaml'
if ($sourceApp.TrimEnd('\') -eq $script:AppRoot.TrimEnd('\') -or $sourceApp.StartsWith($script:AppRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or $script:AppRoot.StartsWith($sourceApp + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Extract the new delivery to a separate directory before updating.' }
Initialize-Context -ProjectName $ProjectName -ConfigPath $ConfigPath
Assert-Docker
$oldVersion = Get-PackageVersion
$oldOverride = $env:PLANNER_SERVER_VERSION
$lock = Enter-OperationLock
$release = $null
$replaced = $false
try {
    if ($oldVersion -ne '0.1.0') { throw 'Expected installed version 0.1.0. Re-running or downgrading is refused.' }
    if (-not (Read-EnvValue 'BACKUP_REPOSITORY_PATH')) { throw 'Configure and verify the backup repository before updating.' }
    if ($oldOverride) { throw 'Remove PLANNER_SERVER_VERSION from this PowerShell environment before updating.' }
    if (Select-String -LiteralPath $script:ConfigPath -Pattern '^PLANNER_SERVER_VERSION=' -Quiet) { throw 'Remove the optional PLANNER_SERVER_VERSION entry from server.env; Compose selects the delivery version.' }
    # Build while 0.1.0 is still running; no replacement of running containers yet.
    & docker build -t ('planner-server:' + $targetVersion) $sourceApp
    if ($LASTEXITCODE -ne 0) { throw 'New image build failed; installed application was not replaced.' }
    $beforeText = Invoke-Compose -Arguments @('run', '--rm', '--no-deps', 'backup', 'snapshots', '--json') -Capture
    $before = @($beforeText | ConvertFrom-Json | ForEach-Object { $_.id })
    & (Join-Path $script:AppRoot 'scripts/Backup-Server.ps1') -ProjectName $ProjectName -ConfigPath $script:ConfigPath
    Invoke-Compose -Arguments @('run', '--rm', '--no-deps', 'backup', 'check', '--read-data')
    $after = @((Invoke-Compose -Arguments @('run', '--rm', '--no-deps', 'backup', 'snapshots', '--json', '--tag', 'planner-server') -Capture) | ConvertFrom-Json)
    $created = @($after | Where-Object { $before -notcontains $_.id })
    if ($created.Count -ne 1) { throw 'Expected one newly verified pre-update backup.' }
    $snapshot = $created[0].id
    $releases = Join-Path $script:InstallRoot 'releases'
    New-Item -ItemType Directory -Force -Path $releases | Out-Null
    $release = Join-Path $releases ($oldVersion + '-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))
    Copy-Item -LiteralPath $script:AppRoot -Destination $release -Recurse
    # Retain the old image and application. Migration 0.1.1 is additive settings only; no SQL schema changes.
    Invoke-Compose -Arguments @('stop', 'api', 'worker')
    $replaced = $true
    Get-ChildItem -LiteralPath $script:AppRoot -Force | Remove-Item -Recurse -Force
    Get-ChildItem -LiteralPath $sourceApp -Force | Copy-Item -Destination $script:AppRoot -Recurse -Force
    Assert-Delivery -Required
    Invoke-Compose -Arguments @('up', '-d', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '180', 'api', 'worker')
    $ready = Wait-LocalReady -ExpectedVersion $targetVersion
    Write-OperationResult 'update' @{ success = $true; previousVersion = $oldVersion; version = $targetVersion; backupSnapshot = $snapshot; previousApp = $release }
    Write-Host ('Updated to ' + $ready.version + '. Keep the previous app, image and backup until Windows acceptance passes.')
} catch {
    if ($replaced -and $release) {
        try {
            # Stop using whichever Compose file survived the failed copy, then restore the retained app.
            & docker stop ($ProjectName + '-api-1') ($ProjectName + '-worker-1') 2>$null | Out-Null
            Get-ChildItem -LiteralPath $script:AppRoot -Force | Remove-Item -Recurse -Force
            Get-ChildItem -LiteralPath $release -Force | Copy-Item -Destination $script:AppRoot -Recurse -Force
            $env:PLANNER_SERVER_VERSION = $oldVersion
            Invoke-Compose -Arguments @('up', '-d', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '180', 'api', 'worker')
            $restored = Wait-LocalReady -ExpectedVersion $oldVersion
            Write-Warning ('Previous application restored: ' + $restored.version)
        } catch { Write-Warning 'Automatic application rollback failed. Use the retained release and the Windows update guide.' }
    }
    Write-OperationResult 'update' @{ success = $false; previousVersion = $oldVersion; errorCode = 'UPDATE_FAILED'; previousApp = $release }
    throw
} finally { $env:PLANNER_SERVER_VERSION = $oldOverride; $lock.Dispose() }
