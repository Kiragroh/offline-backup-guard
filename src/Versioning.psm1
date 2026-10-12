Set-StrictMode -Version 2.0

function Assert-GuardRelativeName {
    param([string]$Name, [switch]$SingleComponent)
    if ([string]::IsNullOrWhiteSpace($Name) -or [IO.Path]::IsPathRooted($Name)) { throw 'Invalid relative archive path.' }
    $parts = @($Name -split '[\\/]')
    if ($SingleComponent -and $parts.Count -ne 1) { throw 'Source alias must be one directory name.' }
    foreach ($part in $parts) {
        if ($part -eq '' -or $part -eq '.' -or $part -eq '..' -or $part -match '[<>:"|?*\x00-\x1f]' -or
            $part -match '[. ]$' -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)') {
            throw 'Unsafe relative archive path.'
        }
    }
}

function Get-GuardFullPath {
    param([string]$Path)
    if (-not [IO.Path]::IsPathRooted($Path) -or $Path -match '^\\\\[?.]\\' -or $Path -match '^[A-Za-z]:($|[^\\/])') {
        throw 'Retention requires ordinary absolute filesystem paths.'
    }
    $full = [IO.Path]::GetFullPath($Path)
    $volume = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $volume.Length) { $full = $full.TrimEnd('\', '/') }
    return $full
}

function Test-GuardDescendant {
    param([string]$Path, [string]$Root)
    return $Path.StartsWith($Root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Get-GuardVolumeMountIdentity {
    param([string]$Path, $Item)
    $target = $null
    if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        # A volume mount is a junction whose target is a volume root, not a
        # directory junction or symbolic link. Keep this separate for test mocks.
        if ($Item.LinkType -ne 'Junction') { return $null }
        $targets = @($Item.Target)
        if ($targets.Count -ne 1) { return $null }
        $target = [string]$targets[0]
        if ($target.StartsWith('\??\', [StringComparison]::Ordinal)) { $target = '\\?\' + $target.Substring(4) }
        if ($target -notmatch '^\\\\\?\\Volume\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}\\$') { return $null }
    } elseif ($Path -ne [IO.Path]::GetPathRoot($Path)) { return $null }
    if (-not ('OfflineBackupGuard.RetentionVolumeNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
namespace OfflineBackupGuard {
    public static class RetentionVolumeNative {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true,
            ExactSpelling = true, EntryPoint = "GetVolumeNameForVolumeMountPointW")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetVolumeName(string mount, StringBuilder name, uint length);
    }
}
'@ -ErrorAction Stop
    }
    # Read-only mount metadata, never mounting, dismounting or enumerating disks.
    # https://learn.microsoft.com/windows/win32/api/fileapi/nf-fileapi-getvolumenameforvolumemountpointw
    $buffer = New-Object Text.StringBuilder 64
    if (-not [OfflineBackupGuard.RetentionVolumeNative]::GetVolumeName($Path.TrimEnd('\') + '\', $buffer, 64)) {
        throw 'Trusted mount volume metadata could not be verified.'
    }
    $volume = $buffer.ToString()
    if ($null -ne $target -and -not [string]::Equals($target, $volume, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Trusted mount target does not match native volume metadata.'
    }
    return $volume
}

function Get-GuardCheckedItem {
    param([string]$Path, [switch]$AllowMissing, $MountTrust = $null)
    $full = Get-GuardFullPath $Path
    $volume = [IO.Path]::GetPathRoot($full)
    $parts = @($full.Substring($volume.Length) -split '[\\/]' | Where-Object { $_ -ne '' })
    $chain = @($volume)
    $current = $volume
    foreach ($part in $parts) { $current = Join-Path $current $part; $chain += $current }
    # Inspect every ancestor before touching a child; Resolve-Path alone follows links.
    for ($i = 0; $i -lt $chain.Count; $i++) {
        $item = $null
        try { $item = Get-Item -LiteralPath $chain[$i] -Force -ErrorAction Stop }
        catch [System.Management.Automation.ItemNotFoundException] {
            if ($AllowMissing) { return $null }
            throw
        }
        if ($null -ne $MountTrust -and [string]::Equals($chain[$i], $MountTrust.Path, [StringComparison]::OrdinalIgnoreCase)) {
            if (-not $item.PSIsContainer) { throw 'Trusted mount must be a volume root directory.' }
            $volume = Get-GuardVolumeMountIdentity $chain[$i] $item
            if ($volume -notmatch '^\\\\\?\\Volume\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}\\$') {
                throw 'Trusted mount is not a verified Windows volume mount.'
            }
            if ($null -eq $MountTrust.VolumeName) { $MountTrust.VolumeName = $volume }
            elseif ($MountTrust.VolumeName -ne $volume) { throw 'Trusted mount volume identity changed during retention.' }
        } elseif ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Retention refuses reparse points and their descendants.' }
        if ($i -lt ($chain.Count - 1) -and -not $item.PSIsContainer) { throw 'A path ancestor is not a directory.' }
    }
    $resolved = (Resolve-Path -LiteralPath $full -ErrorAction Stop).ProviderPath
    if (-not [string]::Equals((Get-GuardFullPath $resolved), $full, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Resolved retention path changed identity.'
    }
    return $item
}

function Get-GuardTree {
    param([string]$Root, $MountTrust = $null)
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Root)
    while ($pending.Count) {
        $directory = $pending.Pop()
        $item = Get-GuardCheckedItem $directory -MountTrust $MountTrust
        if (-not $item.PSIsContainer) { throw 'Archive directory expected.' }
        foreach ($child in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
            if (-not (Test-GuardDescendant $child.FullName $Root)) { throw 'Archive tree escaped its root.' }
            $checked = Get-GuardCheckedItem $child.FullName -MountTrust $MountTrust
            $checked
            if ($checked.PSIsContainer) { $pending.Push($checked.FullName) }
        }
    }
}

function Get-GuardRunTime {
    param([string]$Name, [datetime]$Now)
    $format = 'yyyy-MM-dd_HHmmss'
    $stamp = $Name
    if ($Name -match '^\d{4}-\d{2}-\d{2}_\d{6}_\d{3}_[a-fA-F0-9]{8,32}$') {
        $format = 'yyyy-MM-dd_HHmmss_fff'
        $stamp = $Name.Substring(0, 21)
    } elseif ($Name -notmatch '^\d{4}-\d{2}-\d{2}_\d{6}$') { throw 'Unknown archive run date format.' }
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($stamp, $format, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None, [ref]$parsed)) { throw 'Invalid archive run date.' }
    # Existing run IDs use local wall time. Do not guess during a DST fold/gap.
    if ([TimeZoneInfo]::Local.IsAmbiguousTime($parsed) -or [TimeZoneInfo]::Local.IsInvalidTime($parsed)) {
        throw 'Ambiguous local archive timestamp.'
    }
    $utc = [datetime]::SpecifyKind($parsed, [DateTimeKind]::Local).ToUniversalTime()
    if ($utc -gt $Now.ToUniversalTime()) { throw 'Archive run timestamp is in the future.' }
    return $utc
}

function Get-GuardPolicyNumber {
    param($Value, [int]$Fallback)
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return $Fallback }
    $number = 0
    if ([string]$Value -notmatch '^\d+$' -or -not [int]::TryParse([string]$Value, [ref]$number)) {
        throw 'Retention policy must be a nonnegative integer or blank.'
    }
    return $number
}

function Invoke-GuardRetention {
    <#
    .SYNOPSIS
    Prunes indexed archives for one successfully mirrored source.
    .DESCRIPTION
    Caller must serialize capture/mirror/retention and call ONLY after a fully
    successful source copy, using the explicitly confirmed, persisted policy.
    In particular a count of zero is not permission to clean a failed run.
    This function cannot infer success or confirmation from a manifest.

    Run IDs are local yyyy-MM-dd_HHmmss (legacy) or
    yyyy-MM-dd_HHmmss_fff_GUIDprefix (8-32 hex characters). Manifest mtime is
    validated but NEVER used as archive age. Unknown/future/DST-ambiguous dates,
    malformed indexes, unindexed files and reparse points skip the entire source.

    TrustedMountPath optionally exempts ONLY the exact mounted volume root
    returned by the runner's Mount-BackupAirDisk AFTER disk identity validation.
    Never populate it from the source CSV or an arbitrary user-supplied folder.
    Both quarantine and mirror must be on that mount. For a folder mount, its
    reparse metadata must identify a junction directly to a volume GUID root,
    confirmed by GetVolumeNameForVolumeMountPointW. Drive-letter volume roots
    are also supported. The volume identity is pinned for this invocation.
    No other reparse points, including ancestors/children, are exempted.
    This metadata check does NOT replace the runner's disk identity validation.

    Deletions never consume version slots. When a file is absent, a recent
    deletion protects its entire history until the latest known event ages out;
    without a deletion event, replacement copies are retained indefinitely.
    A restored file's deletion archives still retain their own age protection.
    Boundary timestamp ties are retained even if this exceeds the version count.
    Blank PreviousVersions expires whole, fully indexed runs; deletion policy
    can extend a run's lifetime. Count mode leaves manifests/directories in place
    to preserve deletion history. RemovedBytes counts payload only.

    Preflight errors return SkippedReason without deleting anything. The runner
    must surface a source warning (e.g. 'Retention skipped: ' + SkippedReason),
    not silently report cleanup success or retry via the legacy bulk cleaner.
    RemovedFiles/RemovedBytes/RemovedRuns remain zero on skipped preflight.
    A later I/O
    error terminates; earlier individual removals may already have succeeded.
    Path checks are repeated before every delete, but callers must prevent
    concurrent mutation of the archive (including hostile directory swaps).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$QuarantineRoot,
        [Parameter(Mandatory = $true)][object]$Source,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][ValidateRange(0, 2147483647)][int]$DefaultRetentionDays,
        [datetime]$Now = (Get-Date),
        [string]$TrustedMountPath
    )
    $result = [pscustomobject]@{ RemovedFiles = 0L; RemovedBytes = 0L; RemovedRuns = 0; SkippedReason = $null }
    $remove = New-Object 'System.Collections.Generic.List[object]'
    $expiredRuns = New-Object 'System.Collections.Generic.List[object]'
    try {
        $alias = [string]$Source.DestinationSubfolder
        Assert-GuardRelativeName $alias -SingleComponent
        $versionsValue = $null
        $deletedValue = $null
        if ($Source -is [Collections.IDictionary]) {
            if ($Source.Contains('PreviousVersions')) { $versionsValue = $Source['PreviousVersions'] }
            if ($Source.Contains('DeletedRetentionDays')) { $deletedValue = $Source['DeletedRetentionDays'] }
        } else {
            if ($Source.PSObject.Properties['PreviousVersions']) { $versionsValue = $Source.PreviousVersions }
            if ($Source.PSObject.Properties['DeletedRetentionDays']) { $deletedValue = $Source.DeletedRetentionDays }
        }
        $versions = Get-GuardPolicyNumber $versionsValue -1
        $deletedDays = Get-GuardPolicyNumber $deletedValue $DefaultRetentionDays
        $nowUtc = $Now.ToUniversalTime()
        $versionCutoff = $nowUtc.AddDays(-[double]$DefaultRetentionDays)
        $deletedCutoff = $nowUtc.AddDays(-[double]$deletedDays)
        $root = Get-GuardFullPath $QuarantineRoot
        $sourceRoot = Get-GuardFullPath (Join-Path $root $alias)
        $mirror = Get-GuardFullPath $DestinationPath
        $checkOptions = @{}
        if (-not [string]::IsNullOrWhiteSpace($TrustedMountPath)) {
            $trusted = Get-GuardFullPath $TrustedMountPath
            if (($root -ne $trusted -and -not (Test-GuardDescendant $root $trusted)) -or
                ($mirror -ne $trusted -and -not (Test-GuardDescendant $mirror $trusted))) {
                throw 'Trusted mount must contain both quarantine and current mirror.'
            }
            $checkOptions.MountTrust = [pscustomobject]@{ Path = $trusted; VolumeName = $null }
        }
        if (-not (Test-GuardDescendant $sourceRoot $root)) { throw 'Source escaped quarantine.' }
        if ($root -eq $mirror -or (Test-GuardDescendant $mirror $root) -or (Test-GuardDescendant $root $mirror)) {
            throw 'Mirror and quarantine paths must not overlap.'
        }
        $mirrorItem = Get-GuardCheckedItem $mirror @checkOptions
        if (-not $mirrorItem.PSIsContainer) { throw 'Current mirror directory is required.' }
        $sourceItem = Get-GuardCheckedItem $sourceRoot -AllowMissing @checkOptions
        if ($null -eq $sourceItem) { return $result }
        if (-not $sourceItem.PSIsContainer) { throw 'Source archive must be a directory.' }
        $runs = New-Object 'System.Collections.Generic.List[object]'
        $records = New-Object 'System.Collections.Generic.List[object]'
        foreach ($runItem in @(Get-ChildItem -LiteralPath $sourceRoot -Force -ErrorAction Stop)) {
            $runItem = Get-GuardCheckedItem $runItem.FullName @checkOptions
            if (-not $runItem.PSIsContainer) { throw 'Unindexed item in source archive.' }
            $time = Get-GuardRunTime $runItem.Name $Now
            $tree = @(Get-GuardTree $runItem.FullName @checkOptions)
            $manifest = Join-Path $runItem.FullName 'lastresort-manifest.tsv'
            $manifestItem = Get-GuardCheckedItem $manifest @checkOptions
            if ($manifestItem.PSIsContainer) { throw 'Manifest must be a regular file.' }
            $indexed = @{}
            $runRecords = New-Object 'System.Collections.Generic.List[object]'
            foreach ($line in @(Get-Content -LiteralPath $manifest -Encoding UTF8 -ErrorAction Stop)) {
                $fields = @($line -split "`t")
                if ($fields.Count -ne 3) { throw 'Malformed archive manifest row.' }
                $reason = $fields[0]
                if ($reason -cnotin @('WillBeReplaced', 'DeletedFromSource')) { throw 'Unknown archive reason.' }
                Assert-GuardRelativeName $fields[1]
                $relative = $fields[1].Replace('/', '\')
                $path = Get-GuardFullPath (Join-Path $runItem.FullName $relative)
                if (-not (Test-GuardDescendant $path $runItem.FullName) -or $path -eq $manifest -or $indexed.ContainsKey($path)) {
                    throw 'Duplicate or unsafe indexed archive path.'
                }
                $mtime = [datetimeoffset]::MinValue
                if (-not [datetimeoffset]::TryParseExact($fields[2], 'o', [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::None, [ref]$mtime)) { throw 'Invalid manifest modification timestamp.' }
                $payload = Get-GuardCheckedItem $path -AllowMissing @checkOptions
                if ($null -ne $payload -and $payload.PSIsContainer) { throw 'Indexed payload is not a regular file.' }
                $record = [pscustomobject]@{ Path = $path; Relative = $relative; Reason = $reason; Time = $time; Item = $payload; Protected = $false }
                $indexed[$path] = $record
                $records.Add($record)
                $runRecords.Add($record)
            }
            foreach ($file in @($tree | Where-Object { -not $_.PSIsContainer })) {
                if ($file.FullName -ne $manifest -and -not $indexed.ContainsKey($file.FullName)) { throw 'Unindexed archive payload; refusing cleanup.' }
            }
            $runs.Add([pscustomobject]@{ Path = $runItem.FullName; Time = $time; Manifest = $manifest; Tree = $tree; Records = $runRecords })
        }
        foreach ($group in @($records | Group-Object Relative)) {
            $history = @($group.Group)
            $current = Get-GuardCheckedItem (Join-Path $mirror $history[0].Relative) -AllowMissing @checkOptions
            $present = $null -ne $current -and -not $current.PSIsContainer
            $deletions = @($history | Where-Object { $_.Reason -eq 'DeletedFromSource' })
            $latest = ($history | Sort-Object Time -Descending | Select-Object -First 1).Time
            foreach ($record in $history) {
                $record.Protected = ($record.Reason -eq 'DeletedFromSource' -and $record.Time -ge $deletedCutoff)
                if (-not $present -and $deletions.Count -gt 0 -and $latest -ge $deletedCutoff) { $record.Protected = $true }
            }
            if ($versions -lt 0) { continue }
            foreach ($record in $deletions) {
                if ($null -ne $record.Item -and -not $record.Protected) { $remove.Add($record) }
            }
            $previous = @($history | Where-Object { $_.Reason -eq 'WillBeReplaced' -and $null -ne $_.Item } | Sort-Object Time -Descending)
            if (-not $present) {
                if ($deletions.Count -gt 0) {
                    foreach ($record in $previous) { if (-not $record.Protected) { $remove.Add($record) } }
                }
            } else {
                for ($i = $versions; $i -lt $previous.Count; $i++) {
                    if ($versions -eq 0 -or $previous[$i].Time -lt $previous[$versions - 1].Time) { $remove.Add($previous[$i]) }
                }
            }
        }
        if ($versions -lt 0) {
            foreach ($run in $runs) {
                if ($run.Time -ge $versionCutoff -or @($run.Records | Where-Object { $_.Protected }).Count -gt 0) { continue }
                foreach ($record in $run.Records) { if ($null -ne $record.Item) { $remove.Add($record) } }
                $expiredRuns.Add($run)
            }
        }
    } catch {
        $result.SkippedReason = $_.Exception.Message
        return $result
    }

    foreach ($record in $remove) {
        if (-not (Test-GuardDescendant $record.Path $sourceRoot)) { throw 'Delete target escaped selected source.' }
        $item = Get-GuardCheckedItem $record.Path @checkOptions
        if ($item.PSIsContainer -or $item.Length -ne $record.Item.Length -or $item.LastWriteTimeUtc -ne $record.Item.LastWriteTimeUtc) {
            throw 'Archive payload changed after retention preflight.'
        }
        Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
        $result.RemovedFiles++
        $result.RemovedBytes += $item.Length
    }
    foreach ($run in $expiredRuns) {
        # Delete only indexed files, then empty directories. Never recursively delete.
        $remaining = @(Get-GuardTree $run.Path @checkOptions)
        if (@($remaining | Where-Object { -not $_.PSIsContainer -and $_.FullName -ne $run.Manifest }).Count -gt 0) { continue }
        if (-not (Test-GuardDescendant $run.Manifest $sourceRoot)) { throw 'Manifest escaped selected source.' }
        $manifestItem = Get-GuardCheckedItem $run.Manifest @checkOptions
        if ($manifestItem.PSIsContainer) { throw 'Manifest changed after preflight.' }
        Remove-Item -LiteralPath $manifestItem.FullName -Force -ErrorAction Stop
        $directories = @($remaining | Where-Object { $_.PSIsContainer } | Sort-Object { $_.FullName.Length } -Descending)
        $directoryPaths = @($directories | ForEach-Object { $_.FullName }) + @($run.Path)
        foreach ($path in $directoryPaths) {
            if (-not (Test-GuardDescendant $path $sourceRoot)) { throw 'Directory escaped selected source.' }
            $directory = Get-GuardCheckedItem $path @checkOptions
            if (-not $directory.PSIsContainer) { throw 'Directory changed after preflight.' }
            [IO.Directory]::Delete($directory.FullName, $false)
        }
        $result.RemovedRuns++
    }
    return $result
}

Export-ModuleMember -Function Invoke-GuardRetention
