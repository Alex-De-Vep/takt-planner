[CmdletBinding()]
param([string]$ProjectName = 'planner-server', [string]$ConfigPath = '', [ValidatePattern('^([01][0-9]|2[0-3]):[0-5][0-9]$')][string]$BackupTime = '03:00')
. "$PSScriptRoot/Common.ps1"
Initialize-Context -ProjectName $ProjectName -ConfigPath $ConfigPath
if ($env:OS -ne 'Windows_NT') { throw 'Scheduled Tasks installation must run on the target Windows computer.' }
if (-not (Read-EnvValue 'BACKUP_REPOSITORY_PATH')) { throw 'Configure and verify backup and restore before installing recurring tasks.' }
Assert-Docker
$backupResult = Join-Path (Join-Path $script:InstallRoot 'logs') ($ProjectName + '-backup.json')
$restoreResult = Get-ChildItem -LiteralPath (Join-Path $script:InstallRoot 'logs') -Filter 'planner-restore-*-restore.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
if (-not (Test-Path -LiteralPath $backupResult) -or -not $restoreResult) { throw 'Run the supplied Backup-Server and Restore-Server successfully before installing tasks.' }
if (-not (Get-Content -LiteralPath $backupResult -Raw | ConvertFrom-Json).success -or -not (Get-Content -LiteralPath $restoreResult.FullName -Raw | ConvertFrom-Json).success) { throw 'The latest backup and restore must have succeeded.' }
$lock = Enter-OperationLock
try {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::FromHours(6)) -RestartCount 3 -RestartInterval ([TimeSpan]::FromMinutes(5))
    $time = [DateTime]::Today.Add([TimeSpan]::Parse($BackupTime))
    foreach ($kind in @('Start', 'Backup')) {
        $taskName = 'PlannerServer-' + $ProjectName + '-' + $kind
        $scriptPath = Join-Path $script:AppRoot ('scripts/' + $kind + '-Server.ps1')
        if ($scriptPath -match '["\r\n]' -or $script:ConfigPath -match '["\r\n]') { throw 'Unsupported quote or newline in installation path.' }
        $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existing -and @($existing.Actions | Where-Object { $_.Arguments -notlike ('*"' + $scriptPath + '"*') }).Count) { throw 'Task name is used by another installation.' }
        $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $scriptPath + '" -ProjectName "' + $ProjectName + '" -ConfigPath "' + $script:ConfigPath + '"'
        if ($kind -eq 'Backup') { $arguments += ' -FullCheck' }
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments -WorkingDirectory $script:AppRoot
        if ($kind -eq 'Start') { $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity }
        else { $trigger = New-ScheduledTaskTrigger -Daily -At $time }
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Planner Server: runs as the signed-in owner; secrets remain in protected server.env.' -Force | Out-Null
    }
    Write-Host ('Installed own-user startup and daily full-checked backup at ' + $BackupTime + ' local Windows time.')
    Write-Host 'Owner login and Docker Desktop remain required. Enable Docker startup at login and disable Resource Saver and sleep separately.'
} finally { $lock.Dispose() }
