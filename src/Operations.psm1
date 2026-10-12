$ErrorActionPreference = 'Stop'

function Read-GuardJson {
    param([string]$Path)
    $options = @{}
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $options.DateKind = 'String' }
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json @options
}

function Write-GuardJson {
    param([string]$Path, [object]$Value)
    $parent = Split-Path $Path -Parent
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temp = Join-Path $parent ([guid]::NewGuid().ToString() + '.tmp')
    try {
        [IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $Value -Depth 12), [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp } }
}

function Get-GuardDiagnosticsPath {
    param([string]$ConfigPath)
    $full = [IO.Path]::GetFullPath($ConfigPath)
    Join-Path (Split-Path $full -Parent) ([IO.Path]::GetFileNameWithoutExtension($full) + '-diagnostics')
}

function New-GuardRun {
    param([string]$ConfigPath, [string]$Kind = 'backup')
    $root = Get-GuardDiagnosticsPath $ConfigPath
    $id = (Get-Date -Format 'yyyy-MM-dd_HHmmss_fff') + '_' + [guid]::NewGuid().ToString('N').Substring(0,8)
    New-Item -ItemType Directory -Path (Join-Path $root 'runs') -Force | Out-Null
    [ordered]@{
        schema_version=2; tool_version='0.3.1'; id=$id; kind=$Kind; started_at=(Get-Date).ToString('o'); finished_at=$null
        status='Running'; phase='Initialization'; success=$false; warnings=0; warning_messages=@(); offline=$null
        storage=$null; sources=@(); error=$null; pid=$PID; host_name=$env:COMPUTERNAME
        process_started_at=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
        config_path=[IO.Path]::GetFullPath($ConfigPath); diagnostics_root=$root
        log_path=(Join-Path $root "$id.log"); event_path=(Join-Path $root "$id.events.jsonl")
    }
}

function Write-GuardEvent {
    param([System.Collections.IDictionary]$Run, [string]$Phase, [string]$Message, [string]$Level='Information', [string]$Source='')
    $Run.phase=$Phase
    if ($Level -eq 'Warning') { $Run.warning_messages+=($Source+': '+$Message).TrimStart(':',' ') }
    if ($Level -eq 'Error' -and -not $Run.failure_phase) { $Run.failure_phase=$Phase }
    $event=[ordered]@{time=(Get-Date).ToString('o');run_id=$Run.id;phase=$Phase;level=$Level;source=$Source;message=$Message}
    [IO.File]::AppendAllText($Run.event_path, (($event | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    [IO.File]::AppendAllText($Run.log_path, ("{0} [{1}] {2} {3}: {4}{5}" -f $event.time,$Level,$Phase,$Source,$Message,[Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Write-GuardJson -Path (Join-Path $Run.diagnostics_root "runs\$($Run.id).json") -Value $Run
    if ($Run.kind -eq 'backup') {
        Write-GuardJson -Path (Join-Path $Run.diagnostics_root 'active.json') -Value $Run
    }
}

function Complete-GuardRun {
    param([System.Collections.IDictionary]$Run)
    $Run.finished_at=(Get-Date).ToString('o')
    $Run.status=if (-not $Run.success) { 'Failed' } elseif ($Run.warnings -gt 0) { 'Warning' } else { 'Succeeded' }
    if (-not $Run.success -and $Run.failure_phase) { $Run.phase=$Run.failure_phase }
    Write-GuardEvent $Run $Run.phase "Run finished: $($Run.status)" $(if($Run.success){'Information'}else{'Error'})
    $active=Join-Path $Run.diagnostics_root 'active.json'
    if (Test-Path -LiteralPath $active) {
        if ((Read-GuardJson $active).id -eq $Run.id) { Remove-Item -LiteralPath $active }
    }
}

function Get-GuardTaskArguments {
    param([string]$ConfigPath)
    '-NoProfile -NonInteractive -File "{0}" -ConfigPath "{1}"' -f (Join-Path $PSScriptRoot 'Run-Backup.ps1'),[IO.Path]::GetFullPath($ConfigPath)
}

function Get-GuardTaskSnapshot {
    param([System.Collections.IDictionary]$Config, [string]$ConfigPath, [datetime]$Now=(Get-Date))
    if (-not $Config.TaskName) { return [pscustomobject]@{Exists=$false;State='Not configured';Drift=@('No task configured');NextRun=$null;LastResult=$null} }
    try {
        $task=Get-ScheduledTask -TaskName $Config.TaskName -TaskPath '\' -ErrorAction Stop
        $info=Get-ScheduledTaskInfo -InputObject $task -ErrorAction Stop
        $drift=@()
        $expectedProgram=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if ($Config.TaskPowerShellPath) { $expectedProgram=$Config.TaskPowerShellPath }
        if (@($task.Actions).Count -ne 1 -or $task.Actions[0].Arguments -ne (Get-GuardTaskArguments $ConfigPath) -or $task.Actions[0].Execute -ne $expectedProgram -or $task.Actions[0].WorkingDirectory -ne $PSScriptRoot) { $drift+='Task action differs from this installation' }
        if (-not $task.Settings.Enabled -or $task.State -eq 'Disabled') { $drift+='Task is disabled' }
        if ([string]$task.Settings.MultipleInstances -notin @('IgnoreNew','2')) { $drift+='Task overlap protection differs' }
        if ([string]$task.Principal.RunLevel -notin @('Highest','1')) { $drift+='Task is not elevated' }
        if ($task.Settings.ExecutionTimeLimit -ne 'PT0S') { $drift+='Task has a forced execution timeout' }
        if (-not $task.Settings.StartWhenAvailable) { $drift+='Missed-start recovery is disabled' }
        $actualUser=$task.Principal.UserId
        try { $actualSid=([Security.Principal.NTAccount]$actualUser).Translate([Security.Principal.SecurityIdentifier]).Value } catch { $actualSid=$actualUser }
        try { $expectedSid=([Security.Principal.NTAccount]$Config.TaskUser).Translate([Security.Principal.SecurityIdentifier]).Value } catch { $expectedSid=$Config.TaskUser }
        if ($actualSid -ne $expectedSid) { $drift+='Task account differs' }
        if ([string]$task.Principal.LogonType -ne $Config.TaskLogonType) { $drift+='Task logon mode differs' }
        if (@($task.Triggers).Count -ne 1 -or -not $task.Triggers[0].Enabled -or $task.Triggers[0].DaysInterval -ne 1 -or ([datetime]$task.Triggers[0].StartBoundary).ToString('HH:mm') -ne $Config.ScheduleTime) { $drift+='Daily schedule differs' }
        if ($task.Triggers[0].Repetition.Interval -and $task.Triggers[0].Repetition.Interval -ne 'PT0S') { $drift+='Unexpected repeating trigger' }
        if ([datetime]$task.Triggers[0].StartBoundary -gt $Now.Date.AddDays(1)) { $drift+='Daily trigger starts in the future' }
        if ($task.Triggers[0].EndBoundary -and [datetime]$task.Triggers[0].EndBoundary -le $Now) { $drift+='Daily trigger has expired' }
        [pscustomobject]@{Exists=$true;State=[string]$task.State;Drift=$drift;NextRun=$info.NextRunTime;LastResult=$info.LastTaskResult;LastRun=$info.LastRunTime}
    } catch {
        [pscustomobject]@{Exists=$false;State='Missing or inaccessible';Drift=@($_.Exception.Message);NextRun=$null;LastResult=$null}
    }
}

function Get-GuardStatus {
    param([string]$ConfigPath, [datetimeoffset]$Now=[datetimeoffset]::Now, [object]$TaskSnapshot=$null)
    $diag=Get-GuardDiagnosticsPath $ConfigPath
    $history=@(); $readErrors=@(); $config=$null
    try { $config=Import-PowerShellDataFile -LiteralPath $ConfigPath } catch { $readErrors+="Configuration unreadable: $($_.Exception.Message)" }
    if (Test-Path -LiteralPath (Join-Path $diag 'runs')) {
        foreach($file in Get-ChildItem -LiteralPath (Join-Path $diag 'runs') -Filter '*.json' -File | Sort-Object Name -Descending | Select-Object -First 2000) {
            try { $item=Read-GuardJson $file.FullName; if ($item.kind -eq 'backup') { $history+=$item } }
            catch { $readErrors+="Unreadable run record: $($file.Name)" }
        }
    }
    $history=@($history | Sort-Object { [datetimeoffset]$_.started_at } -Descending)
    $active=$null
    foreach($item in $history | Where-Object { -not $_.finished_at }) {
        $alive=$false
        if ($item.host_name -eq $env:COMPUTERNAME) {
            try {
                $process=Get-Process -Id $item.pid -ErrorAction Stop
                $alive=([Math]::Abs(($process.StartTime.ToUniversalTime() - ([datetimeoffset]$item.process_started_at).UtcDateTime).TotalSeconds) -lt 1)
            } catch { }
        }
        if ($alive) { if (-not $active) { $active=$item } }
        else { $item.status='Interrupted'; $item.error='No matching runner process. Offline transition is unconfirmed.' }
    }
    $last=$history | Select-Object -First 1
    $success=$history | Where-Object { $_.success -and $_.finished_at } | Select-Object -First 1
    $streak=0; $since=$null
    foreach($item in $history) {
        if ($item.success -and $item.finished_at) { break }
        if ($item.status -eq 'Running') { continue }
        $streak++; $since=$item.started_at
    }
    $warningStreak=0
    foreach($item in $history) {
        if ($item.status -eq 'Running') { continue }
        if ($item.status -eq 'Succeeded') { break }
        if ($item.status -eq 'Warning') { $warningStreak++ }
        $since=$item.started_at
    }
    if ($null -eq $TaskSnapshot -and $config) { $TaskSnapshot=Get-GuardTaskSnapshot $config $ConfigPath }
    if ($null -eq $TaskSnapshot) { $TaskSnapshot=[pscustomobject]@{Exists=$false;State='Unknown';Drift=@('Configuration unavailable');NextRun=$null;LastResult=$null} }
    $state=if ($last) { $last.status } else { 'Never run' }
    $problem=if ($last) { $last.error } else { 'No backup attempts recorded' }
    if ($last -and $last.status -eq 'Warning' -and -not $problem) { $problem=@($last.warning_messages) -join '; ' }
    $overdue=$false
    if ($config -and $config.ScheduleTime -match '^\d{2}:\d{2}$') {
        $graceCutoff=$Now.LocalDateTime.AddHours(-2)
        $due=$graceCutoff.Date.Add([TimeSpan]::Parse($config.ScheduleTime))
        if ($due -gt $graceCutoff) { $due=$due.AddDays(-1) }
        if (-not $last -or ([datetimeoffset]$last.started_at).LocalDateTime -lt $due) {
            $overdue=$true; $state='Missed'; $problem='The expected daily backup did not start (two-hour grace period).'
            if (-not $since) { $since=if($last){([datetimeoffset]$last.started_at).AddDays(1).ToString('o')}else{$due.ToString('o')} }
        }
    }
    if ($active) {
        $state='Running'; $problem="Current phase: $($active.phase)"
        if (($Now-[datetimeoffset]$active.started_at).TotalHours -gt 24) { $state='Needs attention'; $problem='Runner has been active for over 24 hours; inspect progress logs. Do not force-stop without an offline recovery procedure.' }
    }
    if ($TaskSnapshot.Drift.Count -gt 0 -and -not $active) { $state='Needs attention'; $problem=(@($problem)+@($TaskSnapshot.Drift) | Where-Object {$_}) -join '; ' }
    if (-not $active -and $null -ne $TaskSnapshot.LastResult -and $TaskSnapshot.LastResult -notin @(0,267009,267011) -and $TaskSnapshot.LastRun -and
        (-not $last -or ([datetimeoffset]$TaskSnapshot.LastRun - [datetimeoffset]$last.started_at).TotalSeconds -gt 60)) {
        $state='Needs attention'; $problem="Task Scheduler result $($TaskSnapshot.LastResult) without a matching runner journal. Check Windows task history, credentials and script policy. $problem"
        if (-not $since) { $since=$TaskSnapshot.LastRun }
    }
    if ($readErrors.Count) { $state='Unknown'; $problem=$readErrors -join '; ' }
    $storage=$null; $samples=@()
    $reportRoot=if($config){$config.ReportRoot}else{$null}
    if ($reportRoot -and (Test-Path -LiteralPath (Join-Path $reportRoot 'storage-history.json'))) {
        try {
            $samples=Read-GuardJson (Join-Path $reportRoot 'storage-history.json')
            $storage=$samples | Sort-Object { [datetimeoffset]$_.measured_at } | Select-Object -Last 1
            if ($storage) { $storage | Add-Member -NotePropertyName stale -NotePropertyValue (($Now-[datetimeoffset]$storage.measured_at).TotalHours -gt 36) -Force }
        } catch { $readErrors+='Storage history unreadable'; $state='Unknown'; $problem=(@($problem)+$readErrors) -join '; ' }
    }
    [pscustomobject]@{
        State=$state;LastAttempt=$last.started_at;LastSuccess=$success.finished_at;NextRun=$TaskSnapshot.NextRun
        ConsecutiveFailures=$streak;ConsecutiveWarnings=$warningStreak;ProblemSince=$since;Problem=$problem;TaskState=$TaskSnapshot.State
        Drift=@($TaskSnapshot.Drift);Storage=$storage;StorageHistory=@($samples);History=$history;Active=$active;ReportRoot=$reportRoot
        LogRoot=$diag;Overdue=$overdue;LastTaskResult=$TaskSnapshot.LastResult
    }
}

Export-ModuleMember -Function Get-GuardStatus,Get-GuardTaskArguments,Get-GuardTaskSnapshot,Get-GuardDiagnosticsPath,New-GuardRun,Write-GuardEvent,Complete-GuardRun,Read-GuardJson,Write-GuardJson
