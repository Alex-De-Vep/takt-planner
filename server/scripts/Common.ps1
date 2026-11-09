Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:AppRoot = Split-Path -Parent $PSScriptRoot
$script:InstallRoot = Split-Path -Parent $script:AppRoot
$script:ComposePath = Join-Path $script:AppRoot 'compose.yaml'

function Initialize-Context {
    param([string]$ProjectName = 'planner-server', [string]$ConfigPath = '', [bool]$RequireConfig = $true)
    if ($ProjectName -notmatch '^(planner-server(-[a-z0-9-]+)?|planner-restore-[a-z0-9-]+)$') { throw 'Use a planner-server or planner-restore-* project name.' }
    $script:PlannerProjectName = $ProjectName
    if (-not $ConfigPath) { $ConfigPath = Join-Path $script:InstallRoot 'config/server.env' }
    $script:ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
    if ($RequireConfig -and -not (Test-Path -LiteralPath $script:ConfigPath)) { throw 'Run Initialize-Server.ps1 first: config/server.env is missing.' }
    Assert-Delivery
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Install Docker Desktop and reopen PowerShell.' }
}
function Invoke-Compose {
    param([string[]]$Arguments, [switch]$Capture)
    $base = @('compose', '--project-name', $script:PlannerProjectName, '--env-file', $script:ConfigPath, '-f', $script:ComposePath)
    if ($Capture) {
        $output = & docker @base @Arguments
        if ($LASTEXITCODE -ne 0) { throw 'Docker Compose command failed. Check the message above.' }
        return ($output -join "`n")
    }
    & docker @base @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'Docker Compose command failed. Check the message above.' }
}
function Assert-Docker {
    & docker info --format '{{.ServerVersion}}' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Start Docker Desktop and wait until the Engine is running.' }
}
function Read-EnvValue {
    param([string]$Name)
    $lines = @(Get-Content -LiteralPath $script:ConfigPath -Encoding UTF8 | Where-Object { $_ -match ('^' + [regex]::Escape($Name) + '=') })
    if ($lines.Count -ne 1) { throw ('Configuration must contain exactly one ' + $Name) }
    $value = $lines[0].Substring($Name.Length + 1)
    if ($value.StartsWith("'") -and $value.EndsWith("'")) { return $value.Substring(1, $value.Length - 2).Replace("\'", "'") }
    return $value
}
function ConvertTo-EnvLiteral {
    param([string]$Value)
    if ($Value -match "[`r`n`0]") { throw 'Multiline configuration values are not supported.' }
    return "'" + $Value.Replace("'", "\'") + "'"
}
function New-Secret {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ([System.BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
}
function Assert-Email {
    param([string]$Value)
    if ($Value -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') { throw 'Enter a valid full email address.' }
}
function New-OwnedStaging {
    $id = [guid]::NewGuid().ToString()
    $root = Join-Path $script:InstallRoot 'backup-staging'
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $dir = Join-Path $root $id
    New-Item -ItemType Directory -Path $dir | Out-Null
    return @{ Id = $id; Path = $dir }
}
function Remove-OwnedStaging {
    param([string]$Id)
    if ($Id -notmatch '^[a-f0-9-]{36}$') { throw 'Invalid staging identifier.' }
    $path = Join-Path (Join-Path $script:InstallRoot 'backup-staging') $Id
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
}

function Assert-Delivery {
    param([string]$Root = $script:AppRoot, [switch]$Required)
    $manifestPath = Join-Path $Root 'SHA256SUMS.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { if ($Required) { throw 'Delivery manifest is missing.' }; return }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($entry in $manifest.files) {
        if ([System.IO.Path]::IsPathRooted($entry.path) -or ($entry.path -split '[/\\]') -contains '..') { throw 'Invalid delivery manifest path.' }
        $file = Join-Path $Root $entry.path
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw ('Missing delivery file: ' + $entry.path) }
        $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -cne $entry.sha256) { throw ('Delivery file changed: ' + $entry.path) }
    }
}

function Enter-OperationLock {
    $root = Join-Path $script:InstallRoot 'logs'
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $path = Join-Path $root 'planner-server-operation.lock'
    if (-not (Get-Variable -Name PlannerOperationLocks -Scope Global -ErrorAction SilentlyContinue)) { $global:PlannerOperationLocks = @{} }
    if ($global:PlannerOperationLocks.ContainsKey($path) -and $global:PlannerOperationLocks[$path].CanWrite) { throw 'Another server operation holds the installation lock.' }
    try {
        $handle = [System.IO.File]::Open($path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $global:PlannerOperationLocks[$path] = $handle
        return $handle
    }
    catch { throw 'Another server operation holds the installation lock. Wait for it to finish.' }
}
function Write-OperationResult {
    param([string]$Operation, [hashtable]$Result)
    if ($Operation -notmatch '^[a-z-]+$') { throw 'Invalid operation name.' }
    $root = Join-Path $script:InstallRoot 'logs'
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $Result['recordedAt'] = [DateTime]::UtcNow.ToString('o')
    $path = Join-Path $root ($script:PlannerProjectName + '-' + $Operation + '.json')
    $temp = $path + '.' + [guid]::NewGuid().ToString() + '.tmp'
    [System.IO.File]::WriteAllText($temp, ($Result | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $path) { [System.IO.File]::Replace($temp, $path, $null) }
    else { [System.IO.File]::Move($temp, $path) }
}
function Assert-FreeSpace {
    param([string]$Path, [long]$RequiredBytes)
    $driveRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
    try { $drive = New-Object System.IO.DriveInfo($driveRoot); $available = $drive.AvailableFreeSpace }
    catch { throw 'Cannot determine free space. Use a local or mapped backup drive accessible to this Windows user.' }
    if ($available -lt $RequiredBytes) { throw 'Insufficient free space for a coherent backup and repository overhead.' }
}
function Get-PackageVersion {
    param([string]$Root = $script:AppRoot)
    return (Get-Content -LiteralPath (Join-Path $Root 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version
}
function Wait-LocalReady {
    param([string]$ExpectedVersion = '')
    $mapping = Invoke-Compose -Arguments @('port', 'api', '3030') -Capture
    if ($mapping -notmatch '^127\.0\.0\.1:(\d+)$') { throw 'Expected a loopback-only API mapping.' }
    $ready = Invoke-RestMethod -Uri ('http://' + $mapping.Trim() + '/health/ready') -TimeoutSec 10
    if ($ready.status -ne 'ready' -or ($ExpectedVersion -and $ready.version -ne $ExpectedVersion)) { throw 'API is not ready at the expected server version.' }
    return $ready
}
