#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string] $ConfigPath,
    [switch] $ValidateOnly,
    [switch] $AllowManualRun
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'BackupGuard.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Reporting.psm1') -Force
$config = Import-PowerShellDataFile -LiteralPath $ConfigPath

function Assert-Configuration {
    if ($config.ReadyForUse -ne $true) { throw 'Review the example configuration and set ReadyForUse before running.' }
    foreach ($key in @('SourceListPath','StateRoot','LogRoot','ReportRoot')) {
        if (-not [IO.Path]::IsPathRooted($config[$key])) { throw "Absolute path required: $key" }
    }
    if ($config.Threads -lt 1 -or $config.Threads -gt 32 -or $config.RetentionDays -lt 1) { throw 'Invalid thread count or retention period.' }
    if ($config.Canary.ExpectedSha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Pin a trusted canary SHA256 first.' }
    if ([string]::IsNullOrWhiteSpace($config.BackupDisk.VolumeLabel)) { throw 'A volume label is required.' }
    if (-not [IO.Path]::IsPathRooted($config.BackupDisk.PreferredAccessPath)) { throw 'Use an absolute mount folder.' }
    $access = [IO.Path]::GetFullPath($config.BackupDisk.PreferredAccessPath).TrimEnd('\') + '\'
    if ($access -notmatch '^[a-zA-Z]:\\.+\\$') { throw 'Use a dedicated local mount folder, not a drive root or share.' }
    foreach ($key in @('StateRoot','LogRoot','ReportRoot','SourceListPath')) {
        if ([IO.Path]::GetFullPath($config[$key]).StartsWith($access, [StringComparison]::OrdinalIgnoreCase)) { throw 'Configuration, logs and reports must remain accessible while the disk is offline.' }
    }
    Test-BackupCanary -Path $config.Canary.Path -ExpectedText $config.Canary.ExpectedText -ExpectedSha256 $config.Canary.ExpectedSha256 | Out-Null
    $sources = Import-BackupSourceList -Path $config.SourceListPath
    if ($sources.Count -eq 0) { throw 'Enable at least one source.' }
    $names = @{}
    foreach ($source in $sources) {
        $name = $source.DestinationSubfolder
        if ($name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}$' -or $names.ContainsKey($name)) { throw 'Destination names must be unique simple folder names.' }
        $names[$name] = $true
        $full = [IO.Path]::GetFullPath($source.SourcePath).TrimEnd('\') + '\'
        if (-not [IO.Path]::IsPathRooted($source.SourcePath) -or $full.StartsWith($access, [StringComparison]::OrdinalIgnoreCase) -or $access.StartsWith($full, [StringComparison]::OrdinalIgnoreCase)) { throw 'A source cannot overlap the backup mount folder.' }
        if (-not (Test-Path -LiteralPath $source.SourcePath -PathType Container)) { throw "Source unavailable: $($source.Name)" }
        if ((Get-Item -LiteralPath $source.SourcePath).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Source roots must not be reparse points.' }
        Test-BackupSourceCanary -Source $source | Out-Null
    }
    Get-BackupAirDisk -DiskConfig $config.BackupDisk | Out-Null
    return ,$sources
}

$sources = Assert-Configuration
if ($ValidateOnly) { Write-Output 'Preflight passed. No mount or copy performed.'; exit 0 }
$start = [TimeSpan]::ParseExact($config.WindowStart, 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture)
$end = [TimeSpan]::ParseExact($config.WindowEnd, 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture)
$time = (Get-Date).TimeOfDay
$inside = if ($start -lt $end) { $time -ge $start -and $time -lt $end } else { $time -ge $start -or $time -lt $end }
if ($start -eq $end -or (-not $inside -and -not $AllowManualRun)) { throw 'Outside the permitted start window. No disk changes made.' }
$mutex = [Threading.Mutex]::new($false, 'Global\OfflineBackupGuard')
$held = $false
try {
    try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { throw 'Another backup run is active.' }
    $run = [ordered]@{ started_at=(Get-Date).ToString('o'); finished_at=$null; success=$false; offline=$null; storage=$null; sources=@(); error=$null }
    $id = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    New-Item -ItemType Directory -Path $config.LogRoot -Force | Out-Null
    $log = Join-Path $config.LogRoot "$id.log"
    # From this point every exit attempts to offline only the pinned dedicated disk.
    try {
        $mount = Mount-BackupAirDisk -DiskConfig $config.BackupDisk
        $root = Join-Path $mount 'OfflineBackupGuard'
        $quarantine = Join-Path $root 'Quarantine'
        foreach ($source in $sources) {
            try {
                Test-BackupSourceCanary -Source $source | Out-Null
                $dest = Get-BackupMirrorPath -DestinationRoot $root -Source $source
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
                $copyArgs = Get-RobocopyArguments -SourcePath $source.SourcePath -DestinationPath $dest -LogPath $log -MirrorDeletes:$source.MirrorDeletes -ExtraArgs @('/COPY:DAT','/DCOPY:DAT','/FFT','/XJ','/NP','/R:0','/W:0',"/MT:$($config.Threads)",'/XF','backup-manifest.json')
                $preview = Invoke-RobocopyPreview -Arguments $copyArgs -LogPath $log
                Assert-RobocopyPreviewPolicy -Source $source -Summary $preview | Out-Null
                $archived = 0
                if ($preview.ChangedLines -gt 0) {
                    $retained = Save-LastResortMirrorChanges -SourcePath $source.SourcePath -DestinationPath $dest -LastResortRunPath (Get-BackupQuarantineRunPath -QuarantineRoot $quarantine -Source $source -RunId $id) -ExcludeNames @('backup-manifest.json') -PreviewSummary $preview -LogPath $log -SourceName $source.Name
                    $archived = $retained.ArchivedFiles
                }
                $exitCode = Invoke-RobocopyChecked -Arguments $copyArgs -PreviewSummary $preview
                $run.sources += [ordered]@{ name=$source.Name; success=$true; robocopy_exit=$exitCode; archived_files=$archived; locked_at_preflight=([int]($preview.LockedPaths.Count / 2)) }
            } catch {
                Write-BackupAirLog -Path $log -Message $_.Exception.Message
                $run.sources += [ordered]@{ name=$source.Name; success=$false; error='Source failed; inspect local log.' }
            }
        }
        $run.success = @($run.sources | Where-Object { -not $_.success }).Count -eq 0
        # Do not expire recovery copies during a failed run.
        if ($run.success -and (Test-Path -LiteralPath $quarantine)) {
            $expired = Remove-ExpiredLastResortRuns -LastResortRoot $quarantine -RetentionDays $config.RetentionDays
            $run.retention_deleted_files = $expired.RemovedFiles
        }
        $volume = Get-Volume -FilePath $mount
        $run.storage = [ordered]@{ measured_at=(Get-Date).ToString('o'); capacity_bytes=[long]$volume.Size; free_bytes=[long]$volume.SizeRemaining; used_bytes=[long]($volume.Size-$volume.SizeRemaining) }
    } catch {
        $run.success=$false; $run.error='Backup failed; inspect the local log.'
        Write-BackupAirLog -Path $log -Message $_.Exception.Message
    } finally {
        try { Dismount-BackupAirDisk -DiskConfig $config.BackupDisk; $run.offline=(Get-BackupAirDisk -DiskConfig $config.BackupDisk).IsOffline }
        catch { $run.offline=$false; $run.success=$false; $run.error='Disk offline transition failed. Operator action required.' }
        $run.finished_at=(Get-Date).ToString('o')
        Publish-BackupReport -ReportRoot $config.ReportRoot -Run $run
    }
    if (-not $run.success -or -not $run.offline) { exit 1 }
    exit 0
} finally {
    if ($held) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
