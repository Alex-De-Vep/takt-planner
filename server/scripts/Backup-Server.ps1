[CmdletBinding()]
param([string]$ProjectName = 'planner-server', [string]$ConfigPath = '', [switch]$FullCheck,
      [System.IO.FileStream]$OperationLockHandle = $null)
. "$PSScriptRoot/Common.ps1"
Initialize-Context -ProjectName $ProjectName -ConfigPath $ConfigPath
Assert-Docker
$lock = $OperationLockHandle
$ownsLock = $null -eq $lock
if ($ownsLock) { $lock = Enter-OperationLock }
$stage = $null
$maintenance = $false
try {
    $repo = Read-EnvValue 'BACKUP_REPOSITORY_PATH'
    if (-not $repo -or -not [System.IO.Path]::IsPathRooted($repo)) { throw 'Set an absolute BACKUP_REPOSITORY_PATH on a separate backup drive.' }
    if (-not (Read-EnvValue 'RESTIC_PASSWORD')) { throw 'RESTIC_PASSWORD is missing.' }
    $repoRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($repo))
    $installDrive = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($script:InstallRoot))
    if ($repoRoot -eq $installDrive) { throw 'Backup repository must be on a separate volume or mapped backup drive.' }
    $sizeText = Invoke-Compose -Arguments @('exec', '-T', 'db', 'psql', '-U', 'planner', '-d', 'planner', '-t', '-A', '-c', 'SELECT pg_database_size(current_database()) + (SELECT COALESCE(sum(size),0) FROM blobs)') -Capture
    [long]$estimate = [long]::Parse($sizeText.Trim()) + 268435456
    Assert-FreeSpace -Path $script:InstallRoot -RequiredBytes $estimate
    if (-not (Test-Path -LiteralPath $repo)) { New-Item -ItemType Directory -Path $repo | Out-Null }
    Assert-FreeSpace -Path $repo -RequiredBytes $estimate
    $items = @(Get-ChildItem -LiteralPath $repo -Force)
    if (-not (Test-Path -LiteralPath (Join-Path $repo 'config'))) {
        if ($items.Count -ne 0) { throw 'The selected directory is not an empty restic repository.' }
        Invoke-Compose -Arguments @('run', '--rm', '--no-deps', 'backup', 'init')
    }
    $stage = New-OwnedStaging
    Invoke-Compose -Arguments @('exec', '-T', 'api', 'node', 'dist/main.js', 'maintenance', 'on')
    $maintenance = $true
    Invoke-Compose -Arguments @('exec', '--user', '1000:1000', '-T', 'db', 'pg_dump', '-U', 'planner', '-d', 'planner', '--format=custom', ('--file=/backup/' + $stage.Id + '/database.dump'))
    Invoke-Compose -Arguments @('exec', '-T', 'api', 'node', 'dist/main.js', 'backup-stage', $stage.Id)
    Invoke-Compose -Arguments @('exec', '-T', 'api', 'node', 'dist/main.js', 'maintenance', 'off')
    $maintenance = $false
    Invoke-Compose -Arguments @('run', '--rm', '--no-deps', 'backup', 'backup', ('/backup/' + $stage.Id), '--host', 'planner-server', '--tag', 'planner-server', '--tag', $stage.Id)
    $checkArgs = @('run', '--rm', '--no-deps', 'backup', 'check')
    if ($FullCheck) { $checkArgs += '--read-data' }
    Invoke-Compose -Arguments $checkArgs
    $snapshots = (Invoke-Compose -Arguments @('run', '--rm', '--no-deps', 'backup', 'snapshots', '--json', '--tag', $stage.Id) -Capture) | ConvertFrom-Json
    if (@($snapshots).Count -ne 1) { throw 'Could not confirm the new backup snapshot.' }
    $snapshot = @($snapshots)[0].id
    # First bound retention to 30 days, then select 7 daily and 4 weekly snapshots inside that range.
    Invoke-Compose -Arguments @('run', '--rm', '--no-deps', 'backup', 'forget', '--tag', 'planner-server', '--host', 'planner-server', '--group-by', 'host', '--keep-within', '30d')
    Invoke-Compose -Arguments @('run', '--rm', '--no-deps', 'backup', 'forget', '--tag', 'planner-server', '--host', 'planner-server', '--group-by', 'host', '--keep-daily', '7', '--keep-weekly', '4', '--prune')
    $mode = 'structural'; if ($FullCheck) { $mode = 'full' }
    Write-OperationResult 'backup' @{ success = $true; snapshotId = $snapshot; check = $mode; estimatedBytes = $estimate }
    Invoke-Compose -Arguments @('exec', '-T', 'api', 'node', 'dist/main.js', 'record-backup', 'success', $snapshot, $mode)
    Write-Host ('Encrypted backup verified. Snapshot: ' + $snapshot)
} catch {
    Write-OperationResult 'backup' @{ success = $false; errorCode = 'BACKUP_FAILED' }
    try { Invoke-Compose -Arguments @('exec', '-T', 'api', 'node', 'dist/main.js', 'record-backup', 'failed') } catch { Write-Warning 'Could not record backup state in PostgreSQL; see the local backup result.' }
    throw
} finally {
    if ($maintenance) {
        try { Invoke-Compose -Arguments @('exec', '-T', 'api', 'node', 'dist/main.js', 'maintenance', 'off') }
        catch { Write-Warning 'Maintenance is still enabled. Run node dist/main.js maintenance off inside the API container.' }
    }
    if ($stage) { Remove-OwnedStaging -Id $stage.Id }
    if ($ownsLock) { $lock.Dispose() }
}
