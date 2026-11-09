# Runs cross-platform PowerShell logic with isolated files and a fake Docker command.
# Does not replace the target-Windows acceptance of Docker, NTFS or Task Scheduler.
[CmdletBinding()]
param([string]$SourceRoot = (Split-Path -Parent $PSScriptRoot), [string]$TestRoot = (Join-Path ([System.IO.Path]::GetTempPath()) ('planner-script-test-' + [guid]::NewGuid())))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
New-Item -ItemType Directory -Path $TestRoot -Force | Out-Null
function Assert-True($value, $message) { if (-not $value) { throw $message } }
function Manifest($root) {
    $entries = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Name -ne 'SHA256SUMS.json' } | ForEach-Object {
        @{ path = $_.FullName.Substring($root.Length + 1).Replace('\','/'); sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(); size = $_.Length }
    })
    @{ files = $entries } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root 'SHA256SUMS.json') -Encoding UTF8
}
$global:FakeFailNew = $false
$global:FakeBackupCreated = $false
$global:FakeInstall = ''
$global:FakeCalls = @()
$global:FakeMissingImage = $false
function global:docker {
    $global:LASTEXITCODE = 0
    $parts = @($args)
    $global:FakeCalls += ($parts -join ' ')
    if ($parts[0] -eq 'image' -and $global:FakeMissingImage) { $global:LASTEXITCODE = 1; return }
    if ($parts[0] -eq 'info') { return '28.1.1' }
    if ($parts -contains 'snapshots') {
        if ($global:FakeBackupCreated) { return ('[{"id":"' + ('a' * 64) + '"}]') }
        return '[]'
    }
    if ($parts -contains 'port') { return '127.0.0.1:3030' }
    if ($parts -contains 'up') {
        $version = (Get-Content (Join-Path $global:FakeInstall 'app/package.json') -Raw | ConvertFrom-Json).version
        if ($version -eq '0.1.1' -and $global:FakeFailNew) { $global:LASTEXITCODE = 1 }
    }
}
function global:Invoke-RestMethod {
    param($Uri, $TimeoutSec)
    return [pscustomobject]@{ status = 'ready'; version = (Get-Content (Join-Path $global:FakeInstall 'app/package.json') -Raw | ConvertFrom-Json).version }
}
try {
    foreach ($fail in @($false,$true)) {
        $case = Join-Path $TestRoot ([guid]::NewGuid().ToString()); $install = Join-Path $case 'installed'; $source = Join-Path $case 'new'
        $app = Join-Path $install 'app'
        foreach ($p in @((Join-Path $app 'scripts'),(Join-Path $source 'scripts'),(Join-Path $install 'config'),(Join-Path $install 'logs'))) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
        '{"version":"0.1.0"}' | Set-Content (Join-Path $app 'package.json')
        'old files' | Set-Content (Join-Path $app 'sentinel.txt')
        'old compose' | Set-Content (Join-Path $app 'compose.yaml')
        'param($ProjectName,$ConfigPath); $global:FakeBackupCreated=$true' | Set-Content (Join-Path $app 'scripts/Backup-Server.ps1')
        '{"version":"0.1.1"}' | Set-Content (Join-Path $source 'package.json')
        'new files' | Set-Content (Join-Path $source 'sentinel.txt')
        'new compose' | Set-Content (Join-Path $source 'compose.yaml')
        foreach ($name in @('Update-Server.ps1','Common.ps1')) { Copy-Item (Join-Path $SourceRoot ('scripts/' + $name)) (Join-Path $source ('scripts/' + $name)) }
        Manifest $app; Manifest $source
        $config = Join-Path $install 'config/server.env'
        $secret = "BACKUP_REPOSITORY_PATH='E:/Backup'`nAUTH_SECRET='test-secret-preserve'`n"
        [System.IO.File]::WriteAllText($config,$secret)
        'untouched-data' | Set-Content (Join-Path $install 'persistent-data-marker')
        $global:FakeFailNew=$fail; $global:FakeBackupCreated=$false; $global:FakeInstall=$install
        $failed=$false
        try { & (Join-Path $source 'scripts/Update-Server.ps1') -InstallRoot $install } catch { $failed=$true; Write-Output ("Fixture caught: " + $_.Exception.Message + " at " + $_.ScriptStackTrace) }
        Assert-True ($failed -eq $fail) 'Unexpected update result'
        $expected='0.1.1'; if ($fail) { $expected='0.1.0' }
        Assert-True (((Get-Content (Join-Path $app 'package.json') -Raw | ConvertFrom-Json).version) -eq $expected) 'Update/rollback version mismatch'
        Assert-True ([System.IO.File]::ReadAllText($config) -ceq $secret) 'Configuration changed during update'
        Assert-True ((Get-Content (Join-Path $install 'persistent-data-marker')).Trim() -eq 'untouched-data') 'Persistent data marker changed'
        Assert-True (@(Get-ChildItem (Join-Path $install 'releases') -Directory).Count -eq 1) 'Previous application was not retained'
        Assert-True (Test-Path (Join-Path $install 'logs/planner-server-update.json')) 'Structured update result missing'
        if ($fail) { Write-Output 'PASS: failed new start rolls back application and preserves config/data' }
        else {
            Write-Output 'PASS: update retains prior release and preserves config/data'
            Copy-Item (Join-Path $SourceRoot 'scripts/Start-Server.ps1') (Join-Path $app 'scripts/Start-Server.ps1')
            Copy-Item (Join-Path $SourceRoot 'scripts/Rollback-Server.ps1') (Join-Path $app 'scripts/Rollback-Server.ps1')
            'param($ProjectName,$ConfigPath,[switch]$FullCheck,$OperationLockHandle); $global:FakeBackupCreated=$true' | Set-Content (Join-Path $app 'scripts/Backup-Server.ps1')
            Manifest $app
            $global:FakeCalls=@()
            & (Join-Path $app 'scripts/Start-Server.ps1')
            Assert-True (-not @($global:FakeCalls | Where-Object { $_ -match '^build ' -or $_ -match ' pull (db|api|backup)' }).Count) 'Startup built or downloaded images'
            Assert-True (@($global:FakeCalls | Where-Object { $_ -match '--no-build --pull never' }).Count -gt 0) 'Startup did not enforce local images'
            $global:FakeMissingImage=$true; $rejected=$false
            try { & (Join-Path $app 'scripts/Start-Server.ps1') } catch { $rejected=$true }
            $global:FakeMissingImage=$false
            Assert-True $rejected 'Missing image was not rejected'
            Write-Output 'PASS: startup uses local images and refuses a missing image'
            $previous=(Get-ChildItem (Join-Path $install 'releases') -Directory | Select-Object -First 1).FullName
            & (Join-Path $app 'scripts/Rollback-Server.ps1') -PreviousApp $previous
            Assert-True (((Get-Content (Join-Path $app 'package.json') -Raw | ConvertFrom-Json).version) -eq '0.1.0') 'Manual rollback failed'
            Assert-True ([System.IO.File]::ReadAllText($config) -ceq $secret) 'Manual rollback changed configuration'
            Write-Output 'PASS: manual rollback preserves current configuration/data and retained release'
        }
    }
    . (Join-Path $SourceRoot 'scripts/Common.ps1')
    $script:InstallRoot=$TestRoot; $script:PlannerProjectName='planner-server-lock-test'
    $one=Enter-OperationLock
    try {
        $rejected=$false; try { $two=Enter-OperationLock; $two.Dispose() } catch { $rejected=$true }
        Assert-True $rejected 'Concurrent operation was allowed'
    } finally { $one.Dispose() }
    $again=Enter-OperationLock; $again.Dispose()
    Write-Output 'PASS: operation lock rejects overlap and releases after completion'
    Assert-FreeSpace -Path $TestRoot -RequiredBytes 0
    $rejected=$false; try { Assert-FreeSpace -Path $TestRoot -RequiredBytes ([long]::MaxValue) } catch { $rejected=$true }
    Assert-True $rejected 'Insufficient free space was accepted'
    Write-Output 'PASS: free-space guard rejects insufficient capacity'
} finally { Remove-Item -LiteralPath $TestRoot -Recurse -Force }
