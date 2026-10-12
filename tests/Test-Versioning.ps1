$ErrorActionPreference = 'Stop'
$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Versioning.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw 'Versioning module is not implemented.' }
$module = Import-Module $modulePath -Force -PassThru
$temp = Join-Path ([IO.Path]::GetTempPath()) ('guard-versioning-test-' + [guid]::NewGuid())
$script:passed = 0
$script:links = @()
$now = [datetime]'2026-06-01T12:00:00'
function Check([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
    $script:passed++
    Write-Output "PASS $message"
}
function Put([string]$path, [string]$text = 'data') {
    [IO.Directory]::CreateDirectory((Split-Path $path -Parent)) | Out-Null
    [IO.File]::WriteAllText($path, $text)
}
function Fixture([string]$name, $count = 1, $days = $null) {
    $base = Join-Path $temp $name
    [IO.Directory]::CreateDirectory("$base\mirror") | Out-Null
    [pscustomobject]@{
        Root = "$base\quarantine"; Mirror = "$base\mirror"
        Source = [pscustomobject]@{ DestinationSubfolder = 'demo'; PreviousVersions = $count; DeletedRetentionDays = $days }
    }
}
function Capture($f, [string]$run, [string]$relative = 'a.txt', [string]$reason = 'WillBeReplaced', [string]$alias = 'demo') {
    $dir = "$($f.Root)\$alias\$run"
    Put "$dir\$relative"
    [IO.File]::AppendAllText("$dir\lastresort-manifest.tsv", "$reason`t$relative`t2001-01-01T00:00:00.0000000Z`r`n")
    return "$dir\$relative"
}
function Retain($f, [datetime]$at = $now) {
    Invoke-GuardRetention -QuarantineRoot $f.Root -Source $f.Source -DestinationPath $f.Mirror -DefaultRetentionDays 30 -Now $at
}
function Kept([string]$path) { Test-Path -LiteralPath $path -PathType Leaf }
try {
    foreach ($count in @(0, 1, 2, 5)) {
        $f = Fixture "count$count" $count
        Put "$($f.Mirror)\nested\a.txt"
        Put "$($f.Mirror)\b.txt"
        $paths = @(1..3 | ForEach-Object { Capture $f "2026-05-0$($_)_010000" 'nested\a.txt' })
        $single = Capture $f '2026-05-01_010000' 'b.txt'
        $foreign = Capture $f '2020-01-01_000000' 'untouched.txt' 'WillBeReplaced' 'other'
        [IO.File]::SetLastWriteTime($paths[0], $now.AddYears(1))
        $r = Retain $f
        $expected = [Math]::Max(0, 3 - $count) + [int]($count -eq 0)
        Check ($r.RemovedFiles -eq $expected -and $r.RemovedBytes -eq (4 * $expected)) "Count $count reports exact files and bytes"
        Check ((@( $paths | Where-Object { Kept $_ } )).Count -eq [Math]::Min(3, $count)) "Count $count is per relative file"
        Check ((Kept $single) -eq ($count -gt 0)) "Count $count handles a separate sparse history"
        Check (Kept $foreign) "Count $count never cleans another source"
        if ($count -gt 0) { Check (Kept $paths[2]) 'Newest archive run wins regardless of file mtime' }
        Check ((Retain $f).RemovedFiles -eq 0) 'Repeated retention is idempotent'
    }

    $f = Fixture 'precise' 1
    Put "$($f.Mirror)\a.txt"
    $old = Capture $f '2026-05-01_010000_001_abcdef12'
    $new = Capture $f '2026-05-01_010000_002_01234567'
    Check ((Retain $f).RemovedFiles -eq 1 -and (Kept $new) -and -not (Kept $old)) 'Millisecond GUID run IDs sort chronologically'
    $f = Fixture 'ties' 1
    Put "$($f.Mirror)\a.txt"
    $a = Capture $f '2026-05-01_010000_001_abcdef12'
    $b = Capture $f '2026-05-01_010000_001_01234567'
    Check ((Retain $f).RemovedFiles -eq 0 -and (Kept $a) -and (Kept $b)) 'Equal timestamps retain boundary ties conservatively'

    foreach ($count in @(0, 1, 3)) {
        $f = Fixture "deleted$count" $count 10
        $old = Capture $f '2026-05-01_120000' 'old.txt' 'DeletedFromSource'
        $young = Capture $f '2026-05-25_120000' 'young.txt' 'DeletedFromSource'
        $boundary = Capture $f '2026-05-22_120000' 'boundary.txt' 'DeletedFromSource'
        Put "$($f.Mirror)\young.txt" 'restored'
        $r = Retain $f
        Check ($r.RemovedFiles -eq 1 -and -not (Kept $old) -and (Kept $young) -and (Kept $boundary)) "Deletion age is independent of count $count and restored state"
    }
    $f = Fixture 'inherited' 0
    $a = Capture $f '2026-05-15_120000' 'a.txt' 'DeletedFromSource'
    Check ((Retain $f).RemovedFiles -eq 0 -and (Kept $a)) 'Null deleted retention inherits the default'
    $f = Fixture 'absent-no-event' 0
    $a = Capture $f '2020-01-01_000000'
    Check ((Retain $f).RemovedFiles -eq 0 -and (Kept $a)) 'Absent mirror without a deletion event preserves recovery copy'
    $f = Fixture 'redelete' 0 10
    $a = Capture $f '2026-01-01_000000'
    $b = Capture $f '2026-01-02_000000' 'a.txt' 'DeletedFromSource'
    $c = Capture $f '2026-05-25_000000'
    $d = Capture $f '2026-05-26_000000' 'a.txt' 'DeletedFromSource'
    Check ((Retain $f).RemovedFiles -eq 0 -and (Kept $a) -and (Kept $b)) 'Recent re-deletion protects earlier recovery history'
    Check ((Retain $f $now.AddDays(10)).RemovedFiles -eq 4) 'Absent history expires after latest known event retention'

    foreach ($blank in @($null, '')) {
        $f = Fixture ('legacy-' + [guid]::NewGuid()) $blank
        $old = Capture $f '2026-04-01_000000'
        $young = Capture $f '2026-05-25_000000'
        Put "$($f.Mirror)\a.txt"
        $r = Retain $f
        Check ($r.RemovedFiles -eq 1 -and $r.RemovedRuns -eq 1 -and -not (Kept $old) -and (Kept $young)) 'Blank policy expires entire indexed legacy runs by archive date'
        Check (-not (Test-Path -LiteralPath (Split-Path $old -Parent))) 'Expired legacy run directory is removed'
    }
    $f = Fixture 'legacy-deleted-override' $null 90
    $a = Capture $f '2026-04-01_000000'
    $b = Capture $f '2026-04-01_000000' 'deleted.txt' 'DeletedFromSource'
    Check ((Retain $f).RemovedFiles -eq 0 -and (Kept $a) -and (Kept $b)) 'Legacy whole-run expiry respects longer deletion retention'

    foreach ($bad in @('unknown-file', 'missing-manifest', 'bad-line', 'bad-mtime', 'unknown-reason', 'duplicate', 'escape', 'rooted', 'ads', 'trailing-dot', 'bad-date', 'future-date')) {
        $f = Fixture $bad 0
        Put "$($f.Mirror)\a.txt"
        $run = '2026-04-01_000000'
        if ($bad -eq 'bad-date') { $run = '2026-02-30_000000' }
        if ($bad -eq 'future-date') { $run = '2099-01-01_000000' }
        $a = Capture $f $run
        $manifest = Join-Path (Split-Path $a -Parent) 'lastresort-manifest.tsv'
        switch ($bad) {
            'unknown-file' { Put (Join-Path (Split-Path $a -Parent) 'unindexed.txt') }
            'missing-manifest' { [IO.File]::Delete($manifest) }
            'bad-line' { [IO.File]::AppendAllText($manifest, "garbage`n") }
            'bad-mtime' { Put $manifest "WillBeReplaced`ta.txt`tnot-a-date" }
            'unknown-reason' { Put $manifest "Unknown`ta.txt`t2001-01-01T00:00:00.0000000Z" }
            'duplicate' { [IO.File]::AppendAllText($manifest, [IO.File]::ReadAllText($manifest)) }
            'escape' { Put $manifest "WillBeReplaced`t..\outside.txt`t2001-01-01T00:00:00.0000000Z" }
            'rooted' { Put $manifest "WillBeReplaced`tC:\outside.txt`t2001-01-01T00:00:00.0000000Z" }
            'ads' { Put $manifest "WillBeReplaced`ta.txt:stream`t2001-01-01T00:00:00.0000000Z" }
            'trailing-dot' { Put $manifest "WillBeReplaced`ta.txt.`t2001-01-01T00:00:00.0000000Z" }
        }
        $r = Retain $f
        Check ($r.RemovedFiles -eq 0 -and $r.SkippedReason -and (Kept $a)) "Ambiguity preserves source: $bad"
    }

    $f = Fixture 'alias-escape' 0
    $a = Capture $f '2026-04-01_000000'
    $f.Source.DestinationSubfolder = '..\demo'
    Check ((Retain $f).SkippedReason -and (Kept $a)) 'Source alias cannot escape quarantine'

    $f = Fixture 'dictionary-policy' 0
    $f.Source = @{ DestinationSubfolder = 'demo'; PreviousVersions = 0; DeletedRetentionDays = 30 }
    Put "$($f.Mirror)\a.txt"
    $a = Capture $f '2026-05-25_000000'
    Check ((Retain $f).RemovedFiles -eq 1 -and -not (Kept $a)) 'Dictionary source policy is not mistaken for legacy'
    $f = Fixture 'legacy-unindexed' $null
    $a = Capture $f '2020-01-01_000000'
    $unknown = Join-Path (Split-Path $a -Parent) 'unindexed.txt'
    Put $unknown 'recovery copy'
    Check ((Retain $f).SkippedReason -and (Kept $a) -and (Kept $unknown)) 'Legacy cleanup never discards unindexed recovery data'
    $f = Fixture 'preflight-all-runs' 0
    Put "$($f.Mirror)\a.txt"
    $a = Capture $f '2020-01-01_000000'
    $b = Capture $f '2026-05-25_000000'
    Put (Join-Path (Split-Path $b -Parent) 'unindexed.txt')
    Check ((Retain $f).SkippedReason -and (Kept $a) -and (Kept $b)) 'All source runs are preflighted before the first removal'
    $f = Fixture 'foreign-ambiguity' 0
    Put "$($f.Mirror)\a.txt"
    $a = Capture $f '2026-05-25_000000'
    $b = Capture $f 'unknown-date' 'foreign.txt' 'UnknownReason' 'other'
    Check ((Retain $f).RemovedFiles -eq 1 -and -not (Kept $a) -and (Kept $b)) 'Unrelated source ambiguity does not participate in retention'
    $f = Fixture 'missing-mirror' 0
    $a = Capture $f '2020-01-01_000000'
    $f.Mirror = "$($f.Mirror)\missing"
    Check ((Retain $f).SkippedReason -and (Kept $a)) 'Missing mirror never licenses pruning'
    $f = Fixture 'overlap' 0
    $a = Capture $f '2020-01-01_000000'
    $f.Mirror = Split-Path $a -Parent
    Check ((Retain $f).SkippedReason -and (Kept $a)) 'Overlapping mirror and quarantine are rejected'
    $f = Fixture 'zero-deletion-days' 4 0
    $a = Capture $f '2026-05-31_120000' 'a.txt' 'DeletedFromSource'
    Check ((Retain $f).RemovedFiles -eq 1 -and -not (Kept $a)) 'Explicit zero deletion retention is not replaced by default'
    foreach ($invalid in @(-1, 'oops', 1.5, $false)) {
        $f = Fixture ('invalid-policy-' + [guid]::NewGuid()) $invalid
        $a = Capture $f '2020-01-01_000000'
        Check ((Retain $f).SkippedReason -and (Kept $a)) "Invalid version policy fails closed: $invalid"
    }
    $f = Fixture 'manifest-directory' 0
    Put "$($f.Mirror)\a.txt"
    $a = Capture $f '2020-01-01_000000'
    $manifest = Join-Path (Split-Path $a -Parent) 'lastresort-manifest.tsv'
    [IO.File]::Delete($manifest)
    [IO.Directory]::CreateDirectory($manifest) | Out-Null
    Check ((Retain $f).SkippedReason -and (Kept $a)) 'A directory cannot masquerade as a manifest'

    # Junctions need no symlink privilege and exercise the same reparse guard on Windows.
    foreach ($location in @('root', 'ancestor', 'source', 'run', 'nested', 'mirror', 'mirror-nested')) {
        $f = Fixture "link-$location" 0
        Put "$($f.Mirror)\a.txt"
        $a = Capture $f '2026-04-01_000000'
        $outside = Join-Path $temp "outside-$location"
        Put "$outside\sentinel.txt" 'untouched'
        switch ($location) {
            'root' { $link = "$temp\link-root\linked"; $target = $f.Root; $f.Root = $link }
            'ancestor' { $link = "$temp\linked-ancestor"; $target = "$temp\link-ancestor"; $f.Root = "$link\quarantine" }
            'source' { $link = "$($f.Root)\linked"; $target = "$($f.Root)\demo"; $f.Source.DestinationSubfolder = 'linked' }
            'run' { $link = "$($f.Root)\demo\2026-01-01_000000"; $target = $outside }
            'nested' { $link = "$(Split-Path $a -Parent)\nested"; $target = $outside }
            'mirror' { $link = "$temp\linked-mirror"; $target = $f.Mirror; $f.Mirror = $link }
            'mirror-nested' { $link = "$($f.Mirror)\nested"; $target = $outside; $a = Capture $f '2026-04-02_000000' 'nested\sentinel.txt' }
        }
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        $script:links += $link
        $r = Retain $f
        Check ($r.RemovedFiles -eq 0 -and $r.SkippedReason -and (Kept $a) -and (Kept "$outside\sentinel.txt")) "Rejects reparse point before traversal: $location"
    }

    $f = Fixture 'mount-metadata' 0
    Put "$($f.Mirror)\a.txt"
    $a = Capture $f '2026-05-25_000000'
    $mount = "$temp\trusted-mount"
    New-Item -ItemType Junction -Path $mount -Target "$temp\mount-metadata" | Out-Null
    $script:links += $mount
    $f.Root = "$mount\quarantine"
    $f.Mirror = "$mount\mirror"
    $args = @{ QuarantineRoot = $f.Root; Source = $f.Source; DestinationPath = $f.Mirror; DefaultRetentionDays = 30; Now = $now; TrustedMountPath = $mount }
    $r = Invoke-GuardRetention @args
    Check ($r.SkippedReason -and (Kept $a)) 'Supplying a trusted path does not bless an ordinary directory junction'
    $originalMountReader = & $module { (Get-Command Get-GuardVolumeMountIdentity).ScriptBlock }
    try {
        & $module {
            function script:Get-GuardVolumeMountIdentity { param($Path, $Item) return '\\?\Volume{11111111-2222-3333-4444-555555555555}\' }
        }
        $r = Invoke-GuardRetention @args
        Check (-not $r.SkippedReason -and $r.RemovedFiles -eq 1 -and -not (Kept $a)) 'Exact validated volume mount is allowed with mocked native metadata'
        $a = Capture $f '2026-05-26_000000'
        $childLink = "$mount\quarantine\demo\2026-05-26_000000\child"
        New-Item -ItemType Junction -Path $childLink -Target "$temp\outside-nested" | Out-Null
        $script:links += $childLink
        $r = Invoke-GuardRetention @args
        Check ($r.SkippedReason -and (Kept $a)) 'Trusted volume exemption does not allow child junctions'
        [IO.Directory]::Delete($childLink)
        $script:links = @($script:links | Where-Object { $_ -ne $childLink })
        $ancestorLink = "$temp\trusted-ancestor"
        New-Item -ItemType Junction -Path $ancestorLink -Target $temp | Out-Null
        $script:links += $ancestorLink
        $args.TrustedMountPath = "$ancestorLink\trusted-mount"
        $args.QuarantineRoot = "$ancestorLink\trusted-mount\quarantine"
        $args.DestinationPath = "$ancestorLink\trusted-mount\mirror"
        $r = Invoke-GuardRetention @args
        Check ($r.SkippedReason -and (Kept $a)) 'Trusted volume exemption does not allow a reparse ancestor'
        $args.TrustedMountPath = "$mount\quarantine"
        $args.QuarantineRoot = $f.Root
        $args.DestinationPath = $f.Mirror
        $r = Invoke-GuardRetention @args
        Check ($r.SkippedReason -and (Kept $a)) 'Trust is exact and does not bless a parent mount'
    } finally {
        & $module { param($reader) Set-Item Function:script:Get-GuardVolumeMountIdentity -Value $reader } $originalMountReader
    }
    Write-Output "All $script:passed versioning checks passed on PowerShell $($PSVersionTable.PSVersion). No disk-management operations."
} finally {
    $resolved = [IO.Path]::GetFullPath($temp)
    $allowed = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'guard-versioning-test-*') { throw 'Unsafe test cleanup path' }
    foreach ($link in @($script:links | Sort-Object Length -Descending)) {
        if (-not [IO.Path]::GetFullPath($link).StartsWith($resolved + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe link cleanup' }
        [IO.Directory]::Delete($link)
    }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
