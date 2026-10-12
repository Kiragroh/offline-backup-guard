#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

function ConvertTo-GuardDataLiteral {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '$null' }
    if ($Value -is [bool]) { if ($Value) { return '$true' }; return '$false' }
    if ($Value -is [string]) { return "'" + $Value.Replace("'", "''") + "'" }
    if ($Value -is [System.Collections.IDictionary]) {
        $lines = foreach ($key in $Value.Keys) { '    ' + (ConvertTo-GuardDataLiteral ([string]$key)) + ' = ' + (ConvertTo-GuardDataLiteral $Value[$key]) }
        return "@{`r`n" + ($lines -join "`r`n") + "`r`n}"
    }
    if ($Value -is [array]) { return '@(' + ((@($Value | ForEach-Object { ConvertTo-GuardDataLiteral $_ })) -join ', ') + ')' }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        if ([double]::IsNaN([double]$Value) -or [double]::IsInfinity([double]$Value)) { throw 'Non-finite configuration number.' }
        return $Value.ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    throw "Unsupported configuration value type: $($Value.GetType().Name)"
}

function ConvertTo-GuardHashtable {
    param([AllowNull()][object]$Value)
    if ($Value -is [System.Collections.IDictionary]) {
        $map = @{}; foreach ($key in $Value.Keys) { $map[$key] = ConvertTo-GuardHashtable $Value[$key] }; return $map
    }
    if ($Value -is [pscustomobject]) {
        $map = @{}; foreach ($p in $Value.PSObject.Properties) { $map[$p.Name] = ConvertTo-GuardHashtable $p.Value }; return $map
    }
    if ($Value -is [array]) { return ,@($Value | ForEach-Object { ConvertTo-GuardHashtable $_ }) }
    return $Value
}

function Get-GuardTextHash {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function New-GuardSetupConfiguration {
    param([Parameter(Mandatory=$true)][string]$ConfigPath, [string]$TaskUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name)
    $directory = Split-Path ([IO.Path]::GetFullPath($ConfigPath)) -Parent
    $text = 'Backup integrity sentinel. Do not edit.'
    @{
        ReadyForUse = $false; SourceListPath = (Join-Path $directory 'sources.csv')
        StateRoot = (Join-Path $directory 'state'); LogRoot = (Join-Path $directory 'logs'); ReportRoot = (Join-Path $directory 'reports')
        WindowStart = '02:00'; WindowEnd = '06:00'; RetentionDays = 30; Threads = 8
        Canary = @{ Path = (Join-Path $directory 'canary.txt'); ExpectedText = $text; ExpectedSha256 = (Get-GuardTextHash $text) }
        BackupDisk = @{ FriendlyName = ''; SerialNumber = ''; VolumeLabel = 'OFFLINE_BACKUP'; PreferredAccessPath = (Join-Path $env:SystemDrive 'OfflineBackup') }
        TaskName = 'OfflineBackupGuard'; ScheduleTime = '02:00'; TaskUser = $TaskUser; TaskLogonType = 'Interactive'
    }
}

function New-GuardSetupSource {
    [pscustomobject][ordered]@{
        Enabled = $true; Name = ''; SourcePath = ''; DestinationSubfolder = ''; CanaryPath = ''; CanarySha256 = ''
        CanaryRequired = $false; MirrorDeletes = $false; MaxDeleteCount = 1000; PreviousVersions = 1; DeletedRetentionDays = 30
    }
}

function Read-GuardSetupConfiguration {
    param([Parameter(Mandatory=$true)][string]$ConfigPath)
    $config = Import-PowerShellDataFile -LiteralPath $ConfigPath
    $defaults = New-GuardSetupConfiguration $ConfigPath
    foreach ($key in @('TaskName','ScheduleTime','TaskUser','TaskLogonType')) {
        if (-not $config.ContainsKey($key)) { $config[$key] = $defaults[$key] }
    }
    $lines = @(Get-Content -LiteralPath $config.SourceListPath | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') })
    $sources = @($lines | ConvertFrom-Csv -Delimiter ';')
    # Empty legacy policies deliberately stay empty, never silently become new defaults.
    foreach ($source in $sources) {
        foreach ($field in @('PreviousVersions','DeletedRetentionDays')) {
            if (-not $source.PSObject.Properties[$field]) { $source | Add-Member -NotePropertyName $field -NotePropertyValue '' }
        }
    }
    [pscustomobject]@{ Config = $config; Sources = $sources }
}

function Test-GuardAbsolutePath {
    param([string]$Path)
    return ($Path -match '^(?:[a-zA-Z]:\\|\\\\[^\\]+\\[^\\]+\\?)' -and $Path -notmatch '[\x00-\x1f"<>|?*]' -and $Path -notmatch '^\\\\[.?]\\')
}

function Test-GuardPathOverlap {
    param([string]$Left, [string]$Right)
    $a = [IO.Path]::GetFullPath($Left).TrimEnd('\') + '\'
    $b = [IO.Path]::GetFullPath($Right).TrimEnd('\') + '\'
    $a.StartsWith($b, [StringComparison]::OrdinalIgnoreCase) -or $b.StartsWith($a, [StringComparison]::OrdinalIgnoreCase)
}

function Test-GuardSetupConfiguration {
    param([Parameter(Mandatory=$true)][System.Collections.IDictionary]$Config, [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Sources, [Parameter(Mandatory=$true)][string]$ConfigPath)
    foreach ($path in @($ConfigPath, $Config.SourceListPath, $Config.StateRoot, $Config.LogRoot, $Config.ReportRoot, $Config.Canary.Path, $Config.BackupDisk.PreferredAccessPath)) {
        if (-not (Test-GuardAbsolutePath $path)) { throw 'Configuration paths must be absolute Windows paths without wildcards or device prefixes.' }
    }
    if ([IO.Path]::GetExtension($ConfigPath) -ne '.psd1') { throw 'The configuration must have a .psd1 extension.' }
    $mount = $Config.BackupDisk.PreferredAccessPath
    if ($mount -notmatch '^[a-zA-Z]:\\.+' -or [IO.Path]::GetFullPath($mount).TrimEnd('\').Length -le 2) { throw 'Use a dedicated local mount folder, never a drive root or share.' }
    foreach ($path in @($ConfigPath, $Config.SourceListPath, $Config.StateRoot, $Config.LogRoot, $Config.ReportRoot, $Config.Canary.Path)) {
        if (Test-GuardPathOverlap $path $mount) { throw 'Private configuration, canary, state, logs and reports cannot overlap the backup mount.' }
    }
    $files = @($ConfigPath, $Config.SourceListPath, $Config.Canary.Path | ForEach-Object { [IO.Path]::GetFullPath($_).ToLowerInvariant() })
    if (@($files | Select-Object -Unique).Count -ne 3) { throw 'Configuration, source list and canary must be different files.' }
    foreach ($key in @('FriendlyName','SerialNumber','VolumeLabel')) {
        if ([string]::IsNullOrWhiteSpace($Config.BackupDisk[$key]) -or $Config.BackupDisk[$key] -like 'REPLACE*') { throw "An explicit reviewed disk $key is required." }
    }
    foreach ($key in @('WindowStart','WindowEnd','ScheduleTime')) {
        if ($Config[$key] -notmatch '^(?:[01][0-9]|2[0-3]):[0-5][0-9]$') { throw "$key must be HH:mm." }
    }
    $start = [TimeSpan]::Parse($Config.WindowStart); $end = [TimeSpan]::Parse($Config.WindowEnd); $at = [TimeSpan]::Parse($Config.ScheduleTime)
    $inside = if ($start -lt $end) { $at -ge $start -and $at -lt $end } else { $at -ge $start -or $at -lt $end }
    if ($start -eq $end -or -not $inside) { throw 'Daily schedule must be within a nonempty permitted start window.' }
    if ($Config.TaskLogonType -notin @('Interactive','Password')) { throw 'TaskLogonType must be Interactive or Password.' }
    if ([string]::IsNullOrWhiteSpace($Config.TaskUser)) { throw 'Specify the Windows task account.' }
    if ($Config.TaskName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_. -]{0,99}$') { throw 'Use a simple task name (letters, numbers, spaces, dot, dash or underscore).' }
    if ($Config.Contains('TaskPowerShellPath') -and $Config.TaskPowerShellPath -and -not (Test-GuardAbsolutePath $Config.TaskPowerShellPath)) { throw 'TaskPowerShellPath must be absolute.' }
    foreach ($item in @(@('Threads',1,32), @('RetentionDays',1,36500))) {
        $n = 0
        if (-not [int]::TryParse([string]$Config[$item[0]], [ref]$n) -or $n -lt $item[1] -or $n -gt $item[2]) { throw "Invalid $($item[0])." }
    }
    if ($Config.Canary.ExpectedSha256 -notmatch '^[a-fA-F0-9]{64}$' -or [string]::IsNullOrWhiteSpace($Config.Canary.ExpectedText)) { throw 'Pin trusted canary text and SHA256; never relearn them from a suspect file.' }
    if ($Config.ReadyForUse -isnot [bool]) { throw 'ReadyForUse must be a boolean.' }
    $names = @{}; $enabledCount = 0
    foreach ($row in $Sources) {
        foreach ($key in @('Enabled','MirrorDeletes','CanaryRequired')) {
            if ([string]$row.$key -notmatch '^(?i:true|false)$') { throw "Source $key must be true or false." }
        }
        if ([string]$row.Enabled -eq 'true') { $enabledCount++ }
        if ([string]::IsNullOrWhiteSpace($row.Name) -or -not (Test-GuardAbsolutePath $row.SourcePath)) { throw 'Every source needs a name and an absolute path.' }
        if (Test-GuardPathOverlap $row.SourcePath $mount) { throw 'Sources cannot overlap the backup mount.' }
        $diagnostics = Join-Path (Split-Path ([IO.Path]::GetFullPath($ConfigPath)) -Parent) ([IO.Path]::GetFileNameWithoutExtension($ConfigPath) + '-diagnostics')
        foreach ($privatePath in @($ConfigPath, $Config.SourceListPath, $Config.Canary.Path, $Config.StateRoot, $Config.LogRoot, $Config.ReportRoot, $diagnostics)) {
            if (Test-GuardPathOverlap $row.SourcePath $privatePath) { throw 'Configuration, canary, state, diagnostics, logs and reports must remain outside every source.' }
        }
        $alias = [string]$row.DestinationSubfolder
        if ($alias -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}$' -or $alias -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$' -or $names.ContainsKey($alias)) { throw 'Destination aliases must be unique, nonreserved simple folder names.' }
        $names[$alias] = $true
        foreach ($key in @('PreviousVersions','DeletedRetentionDays','MaxDeleteCount')) {
            $value = [string]$row.$key; $n = 0
            if ($key -ne 'MaxDeleteCount' -and [string]::IsNullOrWhiteSpace($value)) { continue }
            $minimum = if ($key -eq 'DeletedRetentionDays') { 1 } else { 0 }
            if (-not [int]::TryParse($value, [ref]$n) -or $n -lt $minimum) { throw "Invalid source $key." }
            if ($key -eq 'PreviousVersions' -and $n -gt 1000) { throw 'PreviousVersions cannot exceed 1000.' }
        }
        if ($row.CanarySha256 -and $row.CanarySha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Source canary hash must be a pinned SHA256.' }
        if ([string]$row.CanaryRequired -eq 'true' -and (-not (Test-GuardAbsolutePath $row.CanaryPath) -or -not $row.CanarySha256)) { throw 'Required source canaries need an absolute path and trusted SHA256.' }
    }
    if ($enabledCount -eq 0) { throw 'Enable at least one source before saving.' }
    return $true
}

function Get-GuardRetentionReductions {
    param([System.Collections.IDictionary]$Config, [object[]]$Sources, [AllowNull()][object]$Previous)
    $changes = @()
    if ($Previous -and [int]$Config.RetentionDays -lt [int]$Previous.Config.RetentionDays) { $changes += 'Global legacy retention is reduced.' }
    foreach ($row in $Sources) {
        $old = if ($Previous) { $Previous.Sources | Where-Object { $_.DestinationSubfolder -eq $row.DestinationSubfolder } | Select-Object -First 1 } else { $null }
        $value = [string]$row.PreviousVersions
        if ($value -eq '0' -and (-not $old -or [string]$old.PreviousVersions -ne '0')) { $changes += "Previous versions disabled: $($row.Name)" }
        elseif ($old -and $value -ne '' -and ([string]$old.PreviousVersions -eq '' -or [int]$value -lt [int]$old.PreviousVersions)) { $changes += "Previous versions reduced: $($row.Name)" }
        $days = if ([string]::IsNullOrWhiteSpace([string]$row.DeletedRetentionDays)) { [int]$Config.RetentionDays } else { [int]$row.DeletedRetentionDays }
        $oldDays = if ($old) { if ([string]::IsNullOrWhiteSpace([string]$old.DeletedRetentionDays)) { [int]$Previous.Config.RetentionDays } else { [int]$old.DeletedRetentionDays } } else { 30 }
        if ($days -lt $oldDays) { $changes += "Deleted-file retention reduced: $($row.Name)" }
    }
    return ,$changes
}

function Assert-GuardNoReparseAncestor {
    param([string]$Path)
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing to write through a reparse point.' }
        }
        $cursor = Split-Path $cursor -Parent
    }
}

function Save-GuardSetupConfiguration {
    param([Parameter(Mandatory=$true)][string]$ConfigPath, [Parameter(Mandatory=$true)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory=$true)][object[]]$Sources, [switch]$InitializeCanary, [switch]$ConfirmRetentionReduction)
    $mutex = [Threading.Mutex]::new($false, 'Global\OfflineBackupGuard')
    $held = $false
    try {
        try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'A backup or another setup save is active. Configuration was not changed.' }
        Save-GuardSetupConfigurationCore @PSBoundParameters
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Save-GuardSetupConfigurationCore {
    param([Parameter(Mandatory=$true)][string]$ConfigPath, [Parameter(Mandatory=$true)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory=$true)][object[]]$Sources, [switch]$InitializeCanary, [switch]$ConfirmRetentionReduction)
    Test-GuardSetupConfiguration $Config $Sources $ConfigPath | Out-Null
    $ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
    $previous = if (Test-Path -LiteralPath $ConfigPath) { Read-GuardSetupConfiguration $ConfigPath } else { $null }
    $reductions = Get-GuardRetentionReductions $Config $Sources $previous
    if ($reductions.Count -and -not $ConfirmRetentionReduction) { throw ('Confirmation required: ' + ($reductions -join ' ')) }
    if ($previous -and ((ConvertTo-GuardDataLiteral $previous.Config.Canary) -ne (ConvertTo-GuardDataLiteral $Config.Canary))) {
        # Compare fields, not hash-table enumeration order.
        foreach ($key in @('Path','ExpectedText','ExpectedSha256')) {
            if ($previous.Config.Canary[$key] -cne $Config.Canary[$key]) { throw 'Existing canary pins cannot be changed by setup. Investigate or perform a separately reviewed recovery.' }
        }
    }
    foreach ($path in @($ConfigPath, $Config.SourceListPath, $Config.Canary.Path)) { Assert-GuardNoReparseAncestor $path }
    $canaryExists = Test-Path -LiteralPath $Config.Canary.Path -PathType Leaf
    if (-not $canaryExists -and ($previous -or -not $InitializeCanary)) { throw 'Canary missing. Only an explicitly confirmed new installation may initialize it.' }
    if ($canaryExists) {
        if ([IO.File]::ReadAllText($Config.Canary.Path, [Text.Encoding]::UTF8) -cne $Config.Canary.ExpectedText -or (Get-FileHash -LiteralPath $Config.Canary.Path -Algorithm SHA256).Hash -ne $Config.Canary.ExpectedSha256) { throw 'Canary mismatch. Setup will not overwrite or relearn it.' }
    } elseif ((Get-GuardTextHash $Config.Canary.ExpectedText) -ne $Config.Canary.ExpectedSha256) { throw 'New canary text does not match its trusted pin.' }
    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmssfff') + '-' + [guid]::NewGuid().ToString('N')
    $backups = @{}; $staged = @{}; $committed = @()
    $targets = @($Config.SourceListPath, $ConfigPath)
    try {
        foreach ($path in $targets) {
            New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
            if (Test-Path -LiteralPath $path) { $backups[$path] = "$path.bak-$stamp"; [IO.File]::Copy($path, $backups[$path], $false) }
            $staged[$path] = "$path.tmp-$stamp"
        }
        $csv = @($Sources | Select-Object Enabled,Name,SourcePath,DestinationSubfolder,CanaryPath,CanarySha256,CanaryRequired,MirrorDeletes,MaxDeleteCount,PreviousVersions,DeletedRetentionDays | ConvertTo-Csv -Delimiter ';' -NoTypeInformation)
        [IO.File]::WriteAllText($staged[$Config.SourceListPath], (($csv -join "`r`n") + "`r`n"), [Text.UTF8Encoding]::new($true))
        [IO.File]::WriteAllText($staged[$ConfigPath], (ConvertTo-GuardDataLiteral $Config), [Text.UTF8Encoding]::new($true))
        # Parse using the same data-file loader before replacing either current file.
        $parsePath = $staged[$ConfigPath] + '.psd1'
        [IO.File]::Move($staged[$ConfigPath], $parsePath); $staged[$ConfigPath] = $parsePath
        Import-PowerShellDataFile -LiteralPath $parsePath | Out-Null
        if (-not $canaryExists) {
            New-Item -ItemType Directory -Path (Split-Path $Config.Canary.Path -Parent) -Force | Out-Null
            $stream = [IO.File]::Open($Config.Canary.Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $bytes = [Text.Encoding]::UTF8.GetBytes($Config.Canary.ExpectedText); $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
        }
        foreach ($path in $targets) {
            if (Test-Path -LiteralPath $path) { [IO.File]::Replace($staged[$path], $path, [NullString]::Value) }
            else { [IO.File]::Move($staged[$path], $path) }
            $committed += $path
        }
    } catch {
        foreach ($path in $committed) {
            if ($backups.ContainsKey($path)) { [IO.File]::Copy($backups[$path], $path, $true) }
            else { [IO.File]::Delete($path) }
        }
        throw
    } finally {
        foreach ($path in $staged.Values) { if (Test-Path -LiteralPath $path) { [IO.File]::Delete($path) } }
    }
    [pscustomobject]@{ ConfigPath = $ConfigPath; Backups = @($backups.Values); Saved = $true }
}

function Get-GuardSetupTaskDefinition {
    param([System.Collections.IDictionary]$Config, [string]$ConfigPath)
    Import-Module (Join-Path $PSScriptRoot 'Operations.psm1') -Force
    $program = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if ($Config.TaskPowerShellPath) { $program = $Config.TaskPowerShellPath }
    [pscustomobject]@{
        Execute = $program; Arguments = (Get-GuardTaskArguments -ConfigPath $ConfigPath)
        WorkingDirectory = $PSScriptRoot; TaskName = $Config.TaskName; ScheduleTime = $Config.ScheduleTime
        TaskUser = $Config.TaskUser; TaskLogonType = $Config.TaskLogonType; MultipleInstances = 'IgnoreNew'; RunLevel = 'Highest'
    }
}

function Measure-GuardSetupSources {
    param([object[]]$Sources)
    foreach ($source in $Sources | Where-Object { [string]$_.Enabled -eq 'true' }) {
        [long]$bytes = 0; [long]$files = 0; $errors = 0; $skipped = 0
        $pending = New-Object 'System.Collections.Generic.Stack[string]'
        $pending.Push($source.SourcePath)
        while ($pending.Count) {
            $path = $pending.Pop()
            try {
                Assert-GuardNoReparseAncestor $path
                $directory = Get-Item -LiteralPath $path -Force -ErrorAction Stop
                if (-not $directory.PSIsContainer) { throw 'Source is not a directory.' }
                if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { $skipped++; continue }
                foreach ($item in Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop) {
                    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $skipped++; continue }
                    if ($item.PSIsContainer) { $pending.Push($item.FullName) } else { $files++; $bytes += $item.Length }
                }
            } catch { $errors++ }
        }
        [pscustomobject]@{ Name = $source.Name; Bytes = $bytes; Files = $files; SkippedReparsePoints = $skipped; Errors = $errors; Complete = ($errors -eq 0 -and $skipped -eq 0); MeasuredAt = (Get-Date).ToString('o') }
    }
}

function Save-GuardRestoreRecord {
    param([string]$ConfigPath, [string]$Note, [switch]$ConfirmExternalRestore)
    if (-not $ConfirmExternalRestore -or [string]::IsNullOrWhiteSpace($Note)) { throw 'An explicit operator statement about a separate restore drill is required.' }
    Import-Module (Join-Path $PSScriptRoot 'Operations.psm1') -Force
    $directory = Get-GuardDiagnosticsPath $ConfigPath
    Assert-GuardNoReparseAncestor $directory
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $record = [ordered]@{ recorded_at = (Get-Date).ToString('o'); kind = 'Operator statement only'; note = $Note; scheduled_identity_accepted = $false; recoverability_verified_by_tool = $false }
    $path = Join-Path $directory ('restore-drill-' + (Get-Date -Format 'yyyyMMdd-HHmmssfff') + '-' + [guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($path, ($record | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    $record
}

Export-ModuleMember -Function ConvertTo-GuardDataLiteral,ConvertTo-GuardHashtable,New-GuardSetupConfiguration,New-GuardSetupSource,Read-GuardSetupConfiguration,Test-GuardSetupConfiguration,Get-GuardRetentionReductions,Save-GuardSetupConfiguration,Get-GuardSetupTaskDefinition,Measure-GuardSetupSources,Save-GuardRestoreRecord,Assert-GuardNoReparseAncestor
