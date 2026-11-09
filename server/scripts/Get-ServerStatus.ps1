[CmdletBinding()]
param([string]$ProjectName = 'planner-server', [string]$ConfigPath = '', [switch]$Json)
. "$PSScriptRoot/Common.ps1"
Initialize-Context -ProjectName $ProjectName -ConfigPath $ConfigPath
Assert-Docker
$ready = Wait-LocalReady
$diagnostic = Invoke-Compose -Arguments @('exec', '-T', 'api', 'node', 'dist/main.js', 'diagnose') -Capture
$state = $diagnostic | ConvertFrom-Json
$report = [ordered]@{ api = $ready; operator = $state }
foreach ($name in @('backup', 'update', 'start')) {
    $path = Join-Path (Join-Path $script:InstallRoot 'logs') ($ProjectName + '-' + $name + '.json')
    if (Test-Path -LiteralPath $path) { $report[$name] = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json }
}
$restoreCheck = Get-ChildItem -LiteralPath (Join-Path $script:InstallRoot 'logs') -Filter 'planner-restore-*-restore.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
if ($restoreCheck) { $report['lastRestoreTest'] = Get-Content -LiteralPath $restoreCheck.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
if (-not $Json) { Invoke-Compose -Arguments @('ps', '-a') }
$report | ConvertTo-Json -Depth 12
