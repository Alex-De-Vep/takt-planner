[CmdletBinding()]
param([string]$ProjectName = 'planner-server', [string]$ConfigPath = '')
. "$PSScriptRoot/Common.ps1"
Initialize-Context -ProjectName $ProjectName -ConfigPath $ConfigPath
Assert-Docker
$lock = Enter-OperationLock
try {
    Invoke-Compose -Arguments @('config', '--quiet')
    Invoke-Compose -Arguments @('build', 'api')
    Invoke-Compose -Arguments @('pull', 'db', 'backup')
    Write-Host 'Build and prerequisite image download completed. Start-Server.ps1 now works with these local images.'
} finally { $lock.Dispose() }
