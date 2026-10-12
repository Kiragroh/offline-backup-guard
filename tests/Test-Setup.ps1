#Requires -Version 5.1
[CmdletBinding()]
param([switch]$HoldMutex, [string]$SignalPath, [string]$ReleasePath)
$ErrorActionPreference = 'Stop'
if ($HoldMutex) {
    $mutex = [Threading.Mutex]::new($false, 'Global\OfflineBackupGuard')
    $held = $false
    try {
        $held = $mutex.WaitOne(0)
        if (-not $held) { throw 'Synthetic mutex holder could not acquire the lock.' }
        [IO.File]::WriteAllText($SignalPath, 'ready')
        $deadline = [datetime]::Now.AddSeconds(15)
        while (-not (Test-Path -LiteralPath $ReleasePath) -and [datetime]::Now -lt $deadline) { Start-Sleep -Milliseconds 50 }
    } finally { if ($held) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
    exit 0
}
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src\Setup.psm1') -Force
$temp = Join-Path ([IO.Path]::GetTempPath()) ('backup-guard-setup-test-' + [guid]::NewGuid().ToString('N'))
$script:passed = 0
function Check([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:passed++; Write-Output "PASS $Message"
}
function MustThrow([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Check $threw $Message
}
try {
    New-Item -ItemType Directory -Path $temp | Out-Null
    $path = Join-Path $temp "operator's config.psd1"
    $config = New-GuardSetupConfiguration -ConfigPath $path -TaskUser 'EXAMPLE\backup-user'
    $config.BackupDisk.FriendlyName = "Example USB 'disk'"
    $config.BackupDisk.SerialNumber = 'SYNTHETIC-ONLY-001'
    $config.BackupDisk.PreferredAccessPath = Join-Path $temp 'mount'
    $config.ReadyForUse = $true
    $source = New-GuardSetupSource
    $source.Name = "Example 'source'; `$notCode"
    $source.SourcePath = Join-Path $temp 'source'
    $source.DestinationSubfolder = 'example'
    $sources = @($source)
    Check ($source.PreviousVersions -eq 1 -and $source.DeletedRetentionDays -eq 30) 'New source defaults are one previous version and 30 deleted days'
    Check (Test-GuardSetupConfiguration $config $sources $path) 'Synthetic configuration validates without source access or disk discovery'
    $config.ExtraLiteral = "quote ' ; `$(throw 'must not run') `r`nUnicode: $([char]0x00e9)"
    Save-GuardSetupConfiguration -ConfigPath $path -Config $config -Sources $sources -InitializeCanary | Out-Null
    $loaded = Read-GuardSetupConfiguration $path
    Check ($loaded.Config.ExtraLiteral -ceq $config.ExtraLiteral) 'PSD1 strings round-trip literally, including quotes, dollar signs, newlines and Unicode'
    Check ($loaded.Sources[0].Name -ceq $source.Name) 'Semicolon CSV round-trips quoted fields'
    Check ($loaded.Config.SourceListPath -eq $config.SourceListPath) 'External absolute source list path is preserved'
    $before = [IO.File]::ReadAllText($path)
    $config.Threads = 4
    Save-GuardSetupConfiguration -ConfigPath $path -Config $config -Sources $sources | Out-Null
    Check (@(Get-ChildItem -LiteralPath $temp -Filter '*.bak-*').Count -eq 2) 'Existing PSD1 and CSV are backed up before replacement'
    Check (@(Get-ChildItem -LiteralPath $temp -Filter '*.psd1.bak-*' | Where-Object { [IO.File]::ReadAllText($_.FullName) -ceq $before }).Count -eq 1) 'PSD1 backup retains exact prior bytes'
    $program = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $signal = Join-Path $temp 'mutex-ready'; $release = Join-Path $temp 'mutex-release'
    $holder = Start-Process -FilePath $program -ArgumentList ('-NoProfile -NonInteractive -File "{0}" -HoldMutex -SignalPath "{1}" -ReleasePath "{2}"' -f $PSCommandPath,$signal,$release) -WindowStyle Hidden -PassThru
    try {
        $deadline = [datetime]::Now.AddSeconds(5)
        while (-not (Test-Path -LiteralPath $signal) -and [datetime]::Now -lt $deadline -and -not $holder.HasExited) { Start-Sleep -Milliseconds 50 }
        Check (Test-Path -LiteralPath $signal) 'Synthetic child holds the shared runner mutex'
        $beforeHash = (Get-FileHash -LiteralPath $path).Hash
        MustThrow { Save-GuardSetupConfiguration $path $config $sources } 'Save refuses a busy shared backup mutex without waiting'
        Check ((Get-FileHash -LiteralPath $path).Hash -eq $beforeHash) 'Busy mutex leaves the existing config untouched'
    } finally { [IO.File]::WriteAllText($release, 'release'); $holder.WaitForExit(); $holder.Dispose() }
    Save-GuardSetupConfiguration $path $config $sources | Out-Null
    Check $true 'Save succeeds after the shared mutex is released'
    $source.PreviousVersions = 0
    MustThrow { Save-GuardSetupConfiguration $path $config $sources } 'Disabling versions requires explicit retention confirmation'
    Save-GuardSetupConfiguration $path $config $sources -ConfirmRetentionReduction | Out-Null
    $source.PreviousVersions = 5
    Save-GuardSetupConfiguration $path $config $sources | Out-Null
    $source.PreviousVersions = 2
    MustThrow { Save-GuardSetupConfiguration $path $config $sources } 'Reducing N versions requires confirmation'
    $source.PreviousVersions = 5; $source.DeletedRetentionDays = 1
    MustThrow { Save-GuardSetupConfiguration $path $config $sources } 'Reducing deleted-file retention requires confirmation'
    $source.DeletedRetentionDays = 30
    $source.PreviousVersions = ''
    Save-GuardSetupConfiguration $path $config $sources | Out-Null
    $source.PreviousVersions = 1
    MustThrow { Save-GuardSetupConfiguration $path $config $sources } 'Changing legacy retention to a finite count requires confirmation'
    $source.PreviousVersions = ''
    $config.RetentionDays = 10
    MustThrow { Save-GuardSetupConfiguration $path $config $sources } 'Reducing global legacy retention requires confirmation'
    $config.RetentionDays = 30
    $source.PreviousVersions = -1
    MustThrow { Test-GuardSetupConfiguration $config $sources $path } 'Negative version counts fail'
    $source.PreviousVersions = 1001
    MustThrow { Test-GuardSetupConfiguration $config $sources $path } 'More than 1000 previous versions fails'
    $source.PreviousVersions = 1; $source.DeletedRetentionDays = 0
    MustThrow { Test-GuardSetupConfiguration $config $sources $path } 'Deleted retention cannot silently be disabled'
    $source.DeletedRetentionDays = 30
    $config.ScheduleTime = '25:00'
    MustThrow { Test-GuardSetupConfiguration $config $sources $path } 'Invalid schedule fails'
    $config.ScheduleTime = '12:00'
    MustThrow { Test-GuardSetupConfiguration $config $sources $path } 'Schedule outside allowed start window fails'
    $config.ScheduleTime = '02:00'
    $config.BackupDisk.SerialNumber = ''
    MustThrow { Test-GuardSetupConfiguration $config $sources $path } 'Explicit disk serial is required'
    $config.BackupDisk.SerialNumber = 'SYNTHETIC-ONLY-001'
    $config.TaskLogonType = 'S4U'
    MustThrow { Test-GuardSetupConfiguration $config $sources $path } 'Unsupported task logon mode fails'
    $config.TaskLogonType = 'Interactive'
    $oldSource = $source.SourcePath; $source.SourcePath = $config.BackupDisk.PreferredAccessPath
    MustThrow { Test-GuardSetupConfiguration $config $sources $path } 'Source and mount overlap fails'
    $source.SourcePath = $oldSource
    $oldLogs = $config.LogRoot; $config.LogRoot = Join-Path $source.SourcePath 'logs'
    MustThrow { Test-GuardSetupConfiguration $config $sources $path } 'Logs inside a source fail validation'
    $config.LogRoot = $oldLogs
    $source.SourcePath = Join-Path $temp "operator's config-diagnostics"
    MustThrow { Test-GuardSetupConfiguration $config $sources $path } 'Sibling diagnostics inside a source fail validation'
    $source.SourcePath = $oldSource
    $config.WindowStart = '22:00'; $config.WindowEnd = '04:00'; $config.ScheduleTime = '01:00'
    Check (Test-GuardSetupConfiguration $config $sources $path) 'Overnight start window validates'
    $config.WindowStart = '02:00'; $config.WindowEnd = '06:00'; $config.ScheduleTime = '02:00'
    New-Item -ItemType Directory -Path $source.SourcePath | Out-Null
    [IO.File]::WriteAllText((Join-Path $source.SourcePath 'example.txt'), '12345')
    $estimate = @(Measure-GuardSetupSources $sources)
    Check ($estimate.Count -eq 1 -and $estimate[0].Complete -and $estimate[0].Files -eq 1 -and $estimate[0].Bytes -eq 5) 'Synthetic source estimate counts files without disk discovery'
    $source.SourcePath = Join-Path $temp 'missing-source'
    $estimate = @(Measure-GuardSetupSources $sources)
    Check (-not $estimate[0].Complete -and $estimate[0].Errors -gt 0) 'Unavailable estimate is marked incomplete rather than zero-success'
    $source.SourcePath = $oldSource
    $target = Join-Path $temp 'reparse-target'
    New-Item -ItemType Directory -Path $target | Out-Null
    [IO.File]::WriteAllText((Join-Path $target 'excluded.txt'), 'do not count')
    $junction = Join-Path $source.SourcePath 'junction'
    New-Item -ItemType Junction -Path $junction -Target $target | Out-Null
    try {
        $estimate = @(Measure-GuardSetupSources $sources)
        Check ($estimate[0].Files -eq 1 -and $estimate[0].SkippedReparsePoints -eq 1 -and -not $estimate[0].Complete) 'Size estimate skips a synthetic junction and marks the estimate incomplete'
    } finally { [IO.Directory]::Delete($junction) }
    MustThrow { Save-GuardRestoreRecord $path 'synthetic drill' } 'Restore note requires an explicit operator confirmation'
    $record = Save-GuardRestoreRecord $path 'Synthetic separate restore statement, no hardware test.' -ConfirmExternalRestore
    Check (-not $record.recoverability_verified_by_tool -and -not $record.scheduled_identity_accepted) 'Operator restore record never claims tool verification or account acceptance'
    $workerDirectory = Join-Path $temp ('backup-guard-ui-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workerDirectory | Out-Null
    $requestFile = Join-Path $workerDirectory ('request-' + [guid]::NewGuid().ToString('N') + '.json')
    $resultFile = Join-Path $workerDirectory ('result-' + [guid]::NewGuid().ToString('N') + '.clixml')
    [IO.File]::WriteAllText($requestFile, (@{ConfigPath=$path} | ConvertTo-Json), [Text.UTF8Encoding]::new($true))
    & $program -NoProfile -NonInteractive -File (Join-Path $root 'Start-BackupGuard.ps1') -WorkerOperation Load -RequestPath $requestFile -ResultPath $resultFile
    Check ($LASTEXITCODE -eq 0) 'Actual noninteractive GUI load worker completes on synthetic data'
    $workerResult = Import-Clixml -LiteralPath $resultFile
    Check ($workerResult.Success -and $workerResult.Data.Config.ExtraLiteral -ceq $config.ExtraLiteral) 'Worker result preserves literal configuration through process serialization'
    $plan = Get-GuardSetupTaskDefinition $config $path
    Check ($plan.Arguments -like '*-NoProfile -NonInteractive -File*' -and $plan.Arguments.Contains($path)) 'Task action has an absolute config path and no profile'
    Check ($plan.Arguments -notmatch 'ExecutionPolicy' -and $plan.MultipleInstances -eq 'IgnoreNew' -and $plan.RunLevel -eq 'Highest') 'Task plan has overlap protection, elevation and no policy bypass'
    $canary = $config.Canary.Path
    [IO.File]::WriteAllText($canary, 'changed')
    MustThrow { Save-GuardSetupConfiguration $path $config $sources -InitializeCanary -ConfirmRetentionReduction } 'Changed existing canary is never relearned or overwritten'
    Check ([IO.File]::ReadAllText($canary) -eq 'changed') 'Compromised canary remains untouched'
    Remove-Item -LiteralPath $canary
    MustThrow { Save-GuardSetupConfiguration $path $config $sources -InitializeCanary -ConfirmRetentionReduction } 'Missing canary in an existing installation cannot be recreated'
    Check (-not (Test-Path -LiteralPath $canary)) 'Missing canary remains missing'
    foreach ($file in @('Start-BackupGuard.ps1','src\Setup.psm1','src\Configure-Task.ps1','tests\Test-Setup.ps1')) {
        $tokens = $null; $errors = $null
        [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file), [ref]$tokens, [ref]$errors) | Out-Null
        Check ($errors.Count -eq 0) "PowerShell parses: $file"
    }
    Write-Output "All $script:passed setup checks passed on PowerShell $($PSVersionTable.PSVersion). No disk enumeration or task mutations performed."
} finally {
    $resolved = [IO.Path]::GetFullPath($temp)
    $allowed = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'backup-guard-setup-test-*') { throw 'Unsafe test cleanup path' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
