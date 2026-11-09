[CmdletBinding()]
param([string]$ProjectName = 'planner-server', [string]$ConfigPath = '')
. "$PSScriptRoot/Common.ps1"
Initialize-Context -ProjectName $ProjectName -ConfigPath $ConfigPath
Assert-Docker
$lock = Enter-OperationLock
try { Invoke-Compose -Arguments @('stop') } finally { $lock.Dispose() }
Write-Host 'Server containers stopped. Persistent data volumes are preserved.'
