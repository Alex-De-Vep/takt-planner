[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$To, [string]$ProjectName = 'planner-server', [string]$ConfigPath = '')
. "$PSScriptRoot/Common.ps1"
Initialize-Context -ProjectName $ProjectName -ConfigPath $ConfigPath
Assert-Email $To
Assert-Docker
Invoke-Compose -Arguments @('exec', '-T', 'api', 'node', 'dist/main.js', 'mail-test', $To)
Write-Host 'Check the destination inbox and spam folder. SMTP credentials were not displayed.'
