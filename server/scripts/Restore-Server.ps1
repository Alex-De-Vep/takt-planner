[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-f0-9]{8,64}$')][string]$Snapshot,
    [string]$ProjectName = ('planner-restore-' + (Get-Date -Format 'yyyyMMddHHmmss')),
    [ValidateRange(1024, 65535)][int]$Port = 13030,
    [string]$ConfigPath = ''
)
. "$PSScriptRoot/Common.ps1"
if ($ProjectName -notmatch '^planner-restore-[a-z0-9-]+$') { throw 'Restore only accepts a separate planner-restore-* project.' }
Initialize-Context -ProjectName $ProjectName -ConfigPath $ConfigPath
Assert-Docker
$existing = & docker volume ls --filter ('label=com.docker.compose.project=' + $ProjectName) --format '{{.Name}}'
if ($LASTEXITCODE -ne 0 -or @($existing | Where-Object { $_ }).Count -ne 0) { throw 'Restore project must have no existing volumes. Choose a new project name.' }
$lock = Enter-OperationLock
$stage = $null
$oldPort = $env:PLANNER_API_PORT
$env:PLANNER_API_PORT = [string]$Port
try {
    if (-not (Read-EnvValue 'BACKUP_REPOSITORY_PATH')) { throw 'BACKUP_REPOSITORY_PATH is missing.' }
    $stats = (Invoke-Compose -Arguments @('run', '--rm', '--no-deps', 'backup', 'stats', $Snapshot, '--mode', 'restore-size', '--json') -Capture) | ConvertFrom-Json
    Assert-FreeSpace -Path $script:InstallRoot -RequiredBytes ([long]$stats.total_size + 268435456)
    $stage = New-OwnedStaging
    Invoke-Compose -Arguments @('run', '--rm', '--no-deps', 'backup', 'restore', $Snapshot, '--target', ('/backup/' + $stage.Id))
    $manifests = @(Get-ChildItem -LiteralPath $stage.Path -Filter 'manifest.json' -Recurse -File)
    if ($manifests.Count -ne 1) { throw 'Expected exactly one server backup manifest.' }
    $sourceDir = $manifests[0].Directory.FullName
    $stagingRoot = [System.IO.Path]::GetFullPath((Join-Path $script:InstallRoot 'backup-staging'))
    if (-not $sourceDir.StartsWith($stagingRoot + [System.IO.Path]::DirectorySeparatorChar)) { throw 'Invalid restore path.' }
    $inside = '/backup/' + $sourceDir.Substring($stagingRoot.Length + 1).Replace('\', '/')
    & docker image inspect ('planner-server:' + (Get-PackageVersion)) --format '{{.Id}}' 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Build the supplied server image before restoration.' }
    Invoke-Compose -Arguments @('run', '--rm', '--no-deps', 'api', 'node', 'dist/main.js', 'backup-verify', $inside)
    Invoke-Compose -Arguments @('up', '-d', '--wait', '--wait-timeout', '120', 'db')
    Invoke-Compose -Arguments @('exec', '--user', '1000:1000', '-T', 'db', 'pg_restore', '-U', 'planner', '-d', 'planner', '--exit-on-error', '--no-owner', '--no-acl', ($inside + '/database.dump'))
    Invoke-Compose -Arguments @('run', '--rm', '--no-deps', 'api', 'node', 'dist/main.js', 'migrate')
    Invoke-Compose -Arguments @('run', '--rm', '--no-deps', '-e', 'RESTORE_MODE=true', 'api', 'node', 'dist/main.js', 'restore-files', $inside)
    Invoke-Compose -Arguments @('up', '-d', '--wait', '--wait-timeout', '120', '--no-deps', 'api', '--no-build', '--pull', 'never')
    $ready = Invoke-RestMethod -Uri ('http://127.0.0.1:' + $Port + '/health/ready') -TimeoutSec 10
    if ($ready.status -ne 'ready') { throw 'Restored server is not ready.' }
    Write-OperationResult 'restore' @{ success = $true; snapshotId = $Snapshot; project = $ProjectName; port = $Port }
    Write-Host ('Restored into separate project ' + $ProjectName + ' on http://127.0.0.1:' + $Port)
    Write-Host 'Production volumes were not replaced. The worker is stopped; old sessions and pending emails were revoked.'
} catch {
    Write-OperationResult 'restore' @{ success = $false; snapshotId = $Snapshot; project = $ProjectName; errorCode = 'RESTORE_FAILED' }
    throw
} finally {
    $env:PLANNER_API_PORT = $oldPort
    if ($stage) { Remove-OwnedStaging -Id $stage.Id }
    $lock.Dispose()
}
