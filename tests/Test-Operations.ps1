$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $root 'src\Operations.psm1') -Force -PassThru
$temp=Join-Path ([IO.Path]::GetTempPath()) ('backup-guard-operations-'+[guid]::NewGuid())
New-Item -ItemType Directory -Path $temp | Out-Null
$passed=0
function Check($value,$label) { if(-not $value){throw $label}; $script:passed++; Write-Output "PASS $label" }
try {
    $path=Join-Path $temp 'config.psd1'
    $reports=Join-Path $temp 'reports'
    [IO.File]::WriteAllText($path, "@{ ScheduleTime='02:30'; ReportRoot='$($reports.Replace("'","''"))' }")
    $task=[pscustomobject]@{Exists=$true;State='Ready';Drift=@();NextRun='2026-01-05T02:30:00';LastResult=0}
    $now=[datetimeoffset]'2026-01-04T10:00:00'
    $status=Get-GuardStatus $path -Now $now -TaskSnapshot $task
    Check ($status.State -eq 'Missed' -and $status.Overdue) 'No journal cannot look healthy after expected schedule'
    $run=New-GuardRun $path
    $run.started_at='2026-01-01T02:30:00';$run.success=$true
    Complete-GuardRun $run
    $saved=Read-GuardJson (Join-Path $run.diagnostics_root "runs\$($run.id).json")
    $saved.finished_at='2026-01-01T03:00:00'
    Write-GuardJson (Join-Path $run.diagnostics_root "runs\$($run.id).json") $saved
    foreach($day in 2,3,4) {
        $failure=New-GuardRun $path
        $failure.started_at="2026-01-0${day}T02:30:00";$failure.error='Source unavailable';$failure.phase='Preflight'
        Complete-GuardRun $failure
    }
    $status=Get-GuardStatus $path -Now $now -TaskSnapshot $task
    Check ($status.State -eq 'Failed' -and $status.ConsecutiveFailures -eq 3) 'Failure streak survives independent invocations'
    Check (([datetimeoffset]$status.ProblemSince).Day -eq 2) 'First failure date is preserved'
    Check (([datetimeoffset]$status.LastSuccess).Day -eq 1) 'Last success is distinct from last attempt'
    Check ($status.Problem -eq 'Source unavailable') 'Failure reason is visible without opening disk'
    $missed=Get-GuardStatus $path -Now ([datetimeoffset]'2026-01-07T02:31:00') -TaskSnapshot $task
    Check ($missed.Overdue -and $missed.State -eq 'Missed') 'A new grace window does not hide earlier missed runs'
    $validation=New-GuardRun $path -Kind validation
    $validation.success=$true;Complete-GuardRun $validation
    $status=Get-GuardStatus $path -Now $now -TaskSnapshot $task
    Check ($status.ConsecutiveFailures -eq 3) 'Successful preflight does not reset backup failure streak'
    $active=New-GuardRun $path
    $active.started_at='2026-01-04T09:00:00'
    Write-GuardEvent $active 'Copy' 'Synthetic copy stage'
    $status=Get-GuardStatus $path -Now $now -TaskSnapshot $task
    Check ($status.State -eq 'Running' -and $status.Active.phase -eq 'Copy') 'Live PID plus process start identify active job'
    $active.process_started_at='1990-01-01T00:00:00Z'
    Write-GuardEvent $active 'Copy' 'Synthetic interrupted stage'
    $status=Get-GuardStatus $path -Now $now -TaskSnapshot $task
    Check ($status.State -eq 'Interrupted' -and -not $status.Active) 'PID reuse does not hide interrupted job'
    $task.Drift=@('Task is disabled')
    $status=Get-GuardStatus $path -Now $now -TaskSnapshot $task
    Check ($status.State -eq 'Needs attention' -and $status.Problem -match 'disabled') 'Scheduler drift overrides old success'
    $task.Drift=@()
    Write-GuardJson (Join-Path $reports 'storage-history.json') @(@{measured_at='2026-01-01T03:00:00';capacity_bytes=1000;used_bytes=400;free_bytes=600})
    $status=Get-GuardStatus $path -Now $now -TaskSnapshot $task
    Check ($status.Storage.stale -and $status.Storage.free_bytes -eq 600) 'Old storage keeps timestamp and becomes stale'
    [IO.File]::WriteAllText((Join-Path $active.diagnostics_root 'runs\broken.json'),'{broken')
    $status=Get-GuardStatus $path -Now $now -TaskSnapshot $task
    Check ($status.State -eq 'Unknown') 'Corrupt history is not silently reported healthy'
    $events=@(Get-Content -LiteralPath $failure.event_path | ForEach-Object { $_ | ConvertFrom-Json })
    Check ($events.Count -gt 0 -and $events[0].run_id -eq $failure.id) 'Events have durable run correlation and severity'
    $taskConfig=@{TaskName='Synthetic';TaskUser=[Security.Principal.WindowsIdentity]::GetCurrent().Name;TaskLogonType='Interactive';ScheduleTime='02:30'}
    & $module {
        param($cfg,$cfgPath,$moduleRoot)
        $script:fakeTask=[pscustomobject]@{
            Actions=@([pscustomobject]@{Execute=(Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe');Arguments=(Get-GuardTaskArguments $cfgPath);WorkingDirectory=$moduleRoot})
            Settings=[pscustomobject]@{Enabled=$true;MultipleInstances='IgnoreNew';ExecutionTimeLimit='PT0S';StartWhenAvailable=$true}
            Principal=[pscustomobject]@{RunLevel='Highest';UserId=$cfg.TaskUser;LogonType='Interactive'}
            Triggers=@([pscustomobject]@{Enabled=$true;DaysInterval=1;StartBoundary='2026-01-01T02:30:00';Repetition=[pscustomobject]@{Interval=$null}})
            State='Ready'
        }
        function script:Get-ScheduledTask { param($TaskName,$TaskPath,$ErrorAction) $script:fakeTask }
        function script:Get-ScheduledTaskInfo { param($InputObject,$ErrorAction) [pscustomobject]@{NextRunTime='2026-01-05T02:30:00';LastTaskResult=0;LastRunTime='2026-01-04T02:30:00'} }
    } $taskConfig $path (Join-Path $root 'src')
    $snapshot=Get-GuardTaskSnapshot $taskConfig $path
    Check ($snapshot.Exists -and $snapshot.Drift.Count -eq 0) 'Matching task definition has no drift'
    & $module { $script:fakeTask.Settings.MultipleInstances='Parallel'; $script:fakeTask.Triggers[0].Repetition.Interval='PT1H' }
    $snapshot=Get-GuardTaskSnapshot $taskConfig $path
    Check ($snapshot.Exists -and $snapshot.Drift.Count -eq 2) 'Parallel/repeating task drift is reported without losing task visibility'
    & $module { $script:fakeTask.Triggers[0].StartBoundary='2099-01-01T02:30:00';$script:fakeTask.Triggers[0] | Add-Member EndBoundary '2020-01-01T00:00:00' }
    $snapshot=Get-GuardTaskSnapshot $taskConfig $path
    Check ($snapshot.Drift -contains 'Daily trigger starts in the future' -and $snapshot.Drift -contains 'Daily trigger has expired') 'Effective task date boundaries are checked'
    Write-Output "All $passed operations checks passed. No disk or scheduler mutation."
} finally {
    $full=[IO.Path]::GetFullPath($temp)
    $allowed=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if (-not $full.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $full -Leaf) -notlike 'backup-guard-operations-*') { throw 'Unsafe test cleanup' }
    Remove-Item -LiteralPath $full -Recurse -Force
}
exit 0
