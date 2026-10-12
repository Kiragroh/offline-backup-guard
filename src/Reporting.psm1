$ErrorActionPreference = 'Stop'

function Write-AtomicReport {
    param([string]$Path, [string]$Content)
    $directory = Split-Path $Path -Parent
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temp = Join-Path $directory ([guid]::NewGuid().ToString() + '.tmp')
    try {
        [IO.File]::WriteAllText($temp, $Content, [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp } }
}

function Publish-BackupReport {
    param([Parameter(Mandatory=$true)][string]$ReportRoot, [Parameter(Mandatory=$true)][System.Collections.IDictionary]$Run)
    $historyPath = Join-Path $ReportRoot 'storage-history.json'
    $history = @()
    if (Test-Path -LiteralPath $historyPath) {
        $jsonOptions = @{}
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $jsonOptions.DateKind = 'String' }
        $loaded = Get-Content -LiteralPath $historyPath -Raw | ConvertFrom-Json @jsonOptions
        $history = @($loaded | Where-Object { $null -ne $_ })
        foreach ($item in $history) {
            if ($item.measured_at -is [DateTime] -or $item.measured_at -is [DateTimeOffset]) {
                $item.measured_at = $item.measured_at.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            }
        }
    }
    if ($Run.storage -and $Run.storage.capacity_bytes -gt 0) {
        $day = ([DateTimeOffset]::Parse($Run.storage.measured_at)).ToString('yyyy-MM-dd')
        if (-not ($history | Where-Object day -eq $day)) {
            $history += [pscustomobject]@{ day=$day; measured_at=$Run.storage.measured_at; capacity_bytes=$Run.storage.capacity_bytes; used_bytes=$Run.storage.used_bytes; free_bytes=$Run.storage.free_bytes }
        }
    }
    $history = @($history | Sort-Object day | Select-Object -Last 366)
    Write-AtomicReport -Path $historyPath -Content (ConvertTo-Json -InputObject $history -Depth 6)
    $payload = $Run | ConvertTo-Json -Depth 8
    Write-AtomicReport -Path (Join-Path $ReportRoot 'latest.json') -Content $payload
    $day = ([DateTimeOffset]::Parse($Run.finished_at)).ToString('yyyy-MM-dd')
    Write-AtomicReport -Path (Join-Path $ReportRoot "daily\$day.json") -Content $payload
    $latestStorage = $history | Select-Object -Last 1
    $status = if ($Run.success) { 'Completed (review warnings and restore-test results)' } else { 'FAILED - operator review required' }
    $lines = @('# Offline Backup Guard - daily report', '', "Finished: $($Run.finished_at)", "Status: $status", "Disk confirmed offline: $($Run.offline)", '')
    if ($latestStorage) {
        $lines += "Storage measured: $($latestStorage.measured_at)"
        $lines += ('Capacity: {0:N2} GB; used: {1:N2} GB; free: {2:N2} GB' -f ($latestStorage.capacity_bytes/1e9), ($latestStorage.used_bytes/1e9), ($latestStorage.free_bytes/1e9))
        $age = ([DateTimeOffset]::Parse($Run.finished_at) - [DateTimeOffset]::Parse($latestStorage.measured_at)).TotalHours
        $lines += "Storage sample stale (over 36 hours): $($age -gt 36)"
    } else { $lines += 'Storage: not measured. No estimate available.' }
    $lines += @('', '| Source | Completed | Previous files retained | Locked at preflight |', '| --- | --- | ---: | ---: |')
    foreach ($source in $Run.sources) {
        $label = ([string]$source.name).Replace('|','/').Replace("`n",' ').Replace("`r",' ')
        $lines += "| $label | $($source.success) | $($source.archived_files) | $($source.locked_at_preflight) |"
    }
    $lines += @('', 'Unknown counters are blank. Robocopy diagnostics remain in private local logs.', 'A successful copy is not proof of application-consistent recovery.', 'No refresh or mount is performed when reading this report.', '')
    Write-AtomicReport -Path (Join-Path $ReportRoot 'latest.md') -Content ($lines -join "`n")
    Write-AtomicReport -Path (Join-Path $ReportRoot "daily\$day.md") -Content ($lines -join "`n")
}
Export-ModuleMember -Function Publish-BackupReport
