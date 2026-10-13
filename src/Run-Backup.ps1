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
Import-Module (Join-Path $PSScriptRoot 'Operations.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Versioning.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DeferredFiles.psm1')
$config = $null

function Assert-Configuration {
    if ($config.ReadyForUse -ne $true) { throw 'Review the example configuration and set ReadyForUse before running.' }
    foreach ($key in @('SourceListPath','StateRoot','LogRoot','ReportRoot')) {
        if (-not [IO.Path]::IsPathRooted($config[$key])) { throw "Absolute path required: $key" }
    }
    if ($config.Threads -lt 1 -or $config.Threads -gt 32 -or $config.RetentionDays -lt 1) { throw 'Invalid thread count or retention period.' }
    if($config.ContainsKey('DeferredWarningAfterRuns') -and ($config.DeferredWarningAfterRuns -notmatch '^\d+$' -or $config.DeferredWarningAfterRuns -lt 1 -or $config.DeferredWarningAfterRuns -gt 365)){throw 'DeferredWarningAfterRuns must be between 1 and 365.'}
    if(-not (Get-GuardDeferredStatus $config.StateRoot).Valid){throw 'Deferred-file ledger is unreadable. No disk changes made.'}
    if ($config.Canary.ExpectedSha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Pin a trusted canary SHA256 first.' }
    if ([string]::IsNullOrWhiteSpace($config.BackupDisk.VolumeLabel)) { throw 'A volume label is required.' }
    if (-not [IO.Path]::IsPathRooted($config.BackupDisk.PreferredAccessPath)) { throw 'Use an absolute mount folder.' }
    $access = [IO.Path]::GetFullPath($config.BackupDisk.PreferredAccessPath).TrimEnd('\') + '\'
    if ($access -notmatch '^[a-zA-Z]:\\.+\\$') { throw 'Use a dedicated local mount folder, not a drive root or share.' }
    $controlPaths=@($ConfigPath,$run.diagnostics_root,$config.Canary.Path,$config.StateRoot,$config.LogRoot,$config.ReportRoot,$config.SourceListPath)
    foreach ($controlPath in $controlPaths) {
        if (([IO.Path]::GetFullPath($controlPath).TrimEnd('\')+'\').StartsWith($access, [StringComparison]::OrdinalIgnoreCase)) { throw 'Configuration, logs and reports must remain accessible while the disk is offline.' }
    }
    Test-BackupCanary -Path $config.Canary.Path -ExpectedText $config.Canary.ExpectedText -ExpectedSha256 $config.Canary.ExpectedSha256 | Out-Null
    $sources = Import-BackupSourceList -Path $config.SourceListPath
    if ($sources.Count -eq 0) { throw 'Enable at least one source.' }
    $names = @{}
    foreach ($source in $sources) {
        $name = $source.DestinationSubfolder
        if (($null -ne $source.PreviousVersions -and ($source.PreviousVersions -lt 0 -or $source.PreviousVersions -gt 1000)) -or ($null -ne $source.DeletedRetentionDays -and $source.DeletedRetentionDays -lt 1)) { throw 'Invalid per-source version count or deleted-file retention.' }
        if ($name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}$' -or $names.ContainsKey($name)) { throw 'Destination names must be unique simple folder names.' }
        $names[$name] = $true
        $full = [IO.Path]::GetFullPath($source.SourcePath).TrimEnd('\') + '\'
        if (-not [IO.Path]::IsPathRooted($source.SourcePath) -or $full.StartsWith($access, [StringComparison]::OrdinalIgnoreCase) -or $access.StartsWith($full, [StringComparison]::OrdinalIgnoreCase)) { throw 'A source cannot overlap the backup mount folder.' }
        foreach ($controlPath in $controlPaths) {
            if (([IO.Path]::GetFullPath($controlPath).TrimEnd('\')+'\').StartsWith($full, [StringComparison]::OrdinalIgnoreCase)) { throw 'Keep configuration, host canary and diagnostics outside source folders.' }
        }
        if (-not (Test-Path -LiteralPath $source.SourcePath -PathType Container)) { throw "Source unavailable: $($source.Name)" }
        if ((Get-Item -LiteralPath $source.SourcePath).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Source roots must not be reparse points.' }
        Test-BackupSourceCanary -Source $source | Out-Null
    }
    Get-BackupAirDisk -DiskConfig $config.BackupDisk | Out-Null
    return ,$sources
}

$kind = if ($ValidateOnly) { 'validation' } else { 'backup' }
$run = New-GuardRun -ConfigPath $ConfigPath -Kind $kind
$mutex = [Threading.Mutex]::new($false, 'Global\OfflineBackupGuard')
$held = $false
$mountAttempted=$false
$validated=$false
$exitStatus=1
try {
    Write-GuardEvent $run 'Initialization' 'Runner started. No disk changes made.'
    try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { throw 'Another backup run is active.' }
    Write-GuardEvent $run 'Configuration' 'Reading private configuration.'
    $config = Import-PowerShellDataFile -LiteralPath $ConfigPath
    Write-GuardEvent $run 'Preflight' 'Checking configuration, canaries, sources and disk identity.'
    $sources = Assert-Configuration
    $validated=$true
    $start = [TimeSpan]::ParseExact($config.WindowStart, 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture)
    $end = [TimeSpan]::ParseExact($config.WindowEnd, 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture)
    if ($start -eq $end) { throw 'Start window must not be empty.' }
    if ($ValidateOnly) {
        $run.success=$true; $exitStatus=0
        Write-GuardEvent $run 'Validated' 'Preflight passed. No mount or copy performed.'
        Write-Output 'Preflight passed. No mount or copy performed.'
    } else {
    $time = (Get-Date).TimeOfDay
    $inside = if ($start -lt $end) { $time -ge $start -and $time -lt $end } else { $time -ge $start -or $time -lt $end }
    if (-not $inside -and -not $AllowManualRun) { throw 'Outside the permitted start window. No disk changes made.' }
    $id = $run.id
    New-Item -ItemType Directory -Path $config.LogRoot -Force | Out-Null
    $log = Join-Path $config.LogRoot "$id.log"
    $run.robocopy_log_path=$log
    # From this point every exit attempts to offline only the pinned dedicated disk.
    try {
        Write-GuardEvent $run 'Mount' 'Bringing only the configured USB disk online.'
        $mountAttempted=$true
        $mount = Mount-BackupAirDisk -DiskConfig $config.BackupDisk
        $root = Join-Path $mount 'OfflineBackupGuard'
        $quarantine = Join-Path $root 'Quarantine'
        foreach ($source in $sources) {
            $deferredContext=$null
            try {
                Write-GuardEvent $run 'Source preflight' 'Checking source canary.' 'Information' $source.Name
                Test-BackupSourceCanary -Source $source | Out-Null
                $dest = Get-BackupMirrorPath -DestinationRoot $root -Source $source
                $threshold=if($config.ContainsKey('DeferredWarningAfterRuns')){[int]$config.DeferredWarningAfterRuns}else{7}
                $deferredContext=New-GuardDeferredContext -StateRoot $config.StateRoot -RunId $id -Name $source.Name -SourcePath $source.SourcePath -DestinationPath $dest -WarningAfterRuns $threshold
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
                $copyArgs = Get-RobocopyArguments -SourcePath $source.SourcePath -DestinationPath $dest -LogPath $log -MirrorDeletes:$source.MirrorDeletes -ExtraArgs @('/COPY:DAT','/DCOPY:DAT','/FFT','/XJ','/NP','/R:0','/W:0',"/MT:$($config.Threads)",'/XF','backup-manifest.json')
                Write-GuardEvent $run 'Preview' 'Scanning changes and sharing locks.' 'Information' $source.Name
                $preview = Invoke-RobocopyPreview -Arguments $copyArgs -LogPath $log -DeferredContext $deferredContext
                Assert-RobocopyPreviewPolicy -Source $source -Summary $preview | Out-Null
                $archived = 0
                if ($preview.ChangedLines -gt 0) {
                    Write-GuardEvent $run 'Version capture' 'Retaining previous destination files before copy.' 'Information' $source.Name
                    $captureUpdates=($null -eq $source.PreviousVersions -or $source.PreviousVersions -gt 0)
                    $retained = Save-LastResortMirrorChanges -SourcePath $source.SourcePath -DestinationPath $dest -LastResortRunPath (Get-BackupQuarantineRunPath -QuarantineRoot $quarantine -Source $source -RunId $id) -ExcludeNames @('backup-manifest.json') -PreviewSummary $preview -LogPath $log -SourceName $source.Name -ArchiveReplacements $captureUpdates -ArchiveDeletions $source.MirrorDeletes
                    $archived = $retained.ArchivedFiles
                }
                Write-GuardEvent $run 'Copy' 'Robocopy is running; progress is in the Robocopy log.' 'Information' $source.Name
                $copyResult = Invoke-RobocopyChecked -Arguments $copyArgs -PreviewSummary $preview -PassThruResult -DeferredContext $deferredContext
                $pending=Save-GuardDeferredComponent $deferredContext $true
                $exitCode = $copyResult.ExitCode
                $locks=@($deferredContext.Items.Values | Where-Object {$_.ErrorCode -in @(32,33) -and $_.Stage -ne 'Copy'}).Count
                if ($pending.Count -gt 0) {
                    $level='Information'
                    if($pending.OverdueCount -gt 0){$run.warnings++;$level='Warning'}
                    Write-GuardEvent $run 'Deferred files' "$($pending.Count) individual files deferred; $($pending.OverdueCount) affected for at least $threshold runs. Retry next run." $level $source.Name
                }
                $expired=[pscustomobject]@{RemovedFiles=0;RemovedBytes=0}
                if ($pending.Count -eq 0 -and $copyResult.NormalizedExitCode -lt 8) {
                    Write-GuardEvent $run 'Retention' 'Applying this source retention policy after successful copy.' 'Information' $source.Name
                    $expired=Invoke-GuardRetention -QuarantineRoot $quarantine -Source $source -DestinationPath $dest -DefaultRetentionDays $config.RetentionDays -TrustedMountPath $mount
                    if ($expired.SkippedReason) {
                        $run.warnings++
                        Write-GuardEvent $run 'Retention deferred' $expired.SkippedReason 'Warning' $source.Name
                    }
                } else {
                    Write-GuardEvent $run 'Retention deferred' 'Recovery copies retained because this source has deferred files.' 'Information' $source.Name
                }
                $run.sources += [ordered]@{ name=$source.Name; success=$true; robocopy_exit=$exitCode; deferred_files=$pending.Count; deferred_overdue=$pending.OverdueCount; archived_files=$archived; locked_at_preflight=$locks; locked_at_copy=$copyResult.LockedAtCopy; retention_deleted_files=$expired.RemovedFiles; retention_deleted_bytes=$expired.RemovedBytes; previous_versions=$source.PreviousVersions }
            } catch {
                $sourceError=$_.Exception.Message
                if($deferredContext){Save-GuardDeferredComponent $deferredContext $false | Out-Null}
                Write-BackupAirLog -Path $log -Message $sourceError
                Write-GuardEvent $run $run.phase $sourceError 'Error' $source.Name
                $run.sources += [ordered]@{ name=$source.Name; success=$false; phase=$run.phase; error=$sourceError }
            }
        }
        $run.success = @($run.sources | Where-Object { -not $_.success }).Count -eq 0
        if (-not $run.success) { $run.error=(@($run.sources | Where-Object { -not $_.success } | ForEach-Object { "$($_.name): $($_.error)" }) -join '; ') }
        Write-GuardEvent $run 'Storage measurement' 'Reading capacity while the backup disk is already mounted.'
        $volume = Get-Volume -FilePath $mount
        $run.storage = [ordered]@{ measured_at=(Get-Date).ToString('o'); capacity_bytes=[long]$volume.Size; free_bytes=[long]$volume.SizeRemaining; used_bytes=[long]($volume.Size-$volume.SizeRemaining) }
        if ($volume.Size -gt 0 -and $volume.SizeRemaining / $volume.Size -lt 0.1) {
            $run.warnings++
            Write-GuardEvent $run 'Storage warning' 'Less than 10 percent free capacity remains.' 'Warning'
        }
    } catch {
        if (-not $run.failure_phase) { $run.failure_phase=$run.phase }
        throw
    } finally {
        # Log failures must never prevent the safety-critical offline attempt.
        try { Write-GuardEvent $run 'Offline' 'Attempting to offline the configured disk.' } catch { }
        try {
            Dismount-BackupAirDisk -DiskConfig $config.BackupDisk
            $run.offline=[bool](Get-BackupAirDisk -DiskConfig $config.BackupDisk).IsOffline
            if (-not $run.offline) { throw 'Disk is still online after offline attempt.' }
        } catch {
            $run.offline=$false; $run.success=$false
            $run.error="Disk offline transition failed: $($_.Exception.Message)"
            Write-GuardEvent $run 'Offline' $run.error 'Error'
        }
    }
    if ($run.success -and $run.offline) { $exitStatus=0 }
    }
} catch {
    $run.success=$false; $exitStatus=1
    $run.error=(@($run.error,$_.Exception.Message) | Where-Object {$_} | Select-Object -Unique) -join '; '
    Write-GuardEvent $run $run.phase $run.error 'Error'
    Write-Warning $run.error
} finally {
    try {
        Complete-GuardRun $run
        if ($validated -and -not $ValidateOnly) { Publish-BackupReport -ReportRoot $config.ReportRoot -Run $run }
        Write-Output "Status: $($run.status). Journal: $($run.event_path)"
    } catch {
        $exitStatus=1
        $run.success=$false
        $run.error="Report persistence failed: $($_.Exception.Message). $($run.error)"
        Write-Warning "$($run.error) Inspect console and journal: $($run.event_path)"
        try { Complete-GuardRun $run } catch { Write-Warning 'The fallback journal is also unavailable.' }
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
exit $exitStatus
