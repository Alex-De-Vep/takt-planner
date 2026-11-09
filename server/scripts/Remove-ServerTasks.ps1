[CmdletBinding()]
param([string]$ProjectName = 'planner-server', [string]$ConfigPath = '')
. "$PSScriptRoot/Common.ps1"
Initialize-Context -ProjectName $ProjectName -ConfigPath $ConfigPath
if ($env:OS -ne 'Windows_NT') { throw 'Run on Windows.' }
foreach ($kind in @('Start', 'Backup')) {
    $taskName = 'PlannerServer-' + $ProjectName + '-' + $kind
    $path = Join-Path $script:AppRoot ('scripts/' + $kind + '-Server.ps1')
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        if (@($task.Actions | Where-Object { $_.Arguments -notlike ('*"' + $path + '"*') }).Count) { throw 'Task belongs to another installation.' }
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
}
