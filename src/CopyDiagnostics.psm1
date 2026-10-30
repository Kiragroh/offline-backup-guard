$ErrorActionPreference='Stop'

function Get-GuardCopyMeasurement {
    param([string[]]$SummaryLines,[string[]]$ErrorLines,[hashtable]$Context,[int]$ExitCode)
    $rows=@{}
    foreach($line in $SummaryLines){
        if($line -match '^\s*(Files|Dateien|Dirs|Verzeich\.|Bytes)\s*:\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$'){
            $counts=$Matches.Clone()
            $kind=switch -Regex ($counts[1]) {'^(Files|Dateien)$' {'Files'} '^Bytes$' {'Bytes'} default {'Directories'}}
            $rows[$kind]=@{Total=[long]$counts[2];Copied=[long]$counts[3];Skipped=[long]$counts[4];Mismatch=[long]$counts[5];Failed=[long]$counts[6];Extras=[long]$counts[7]}
        }
    }
    $groups=@{};$onlyFileCopy=$true
    foreach($line in $ErrorLines){
        if($line -notmatch '(?i)\b(?:ERROR|FEHLER)\s+(\d+)\s+\(0x[0-9a-f]+\)\s+(.+)$'){$onlyFileCopy=$false;continue}
        $code=[int]$Matches[1];$action=$Matches[2];$operation='Unknown';$side='Unknown'
        switch -Regex ($action){
            '^(Copying File|Folgende Datei wird kopiert|Kopieren der Datei)\s' {$operation='CopyFile';$side='SourceOrDestination';break}
            '(Deleting|Loeschen|L\u00f6schen)' {$operation='Delete';$side='Destination';break}
            '(Accessing Source Directory|Zugriff auf Quellverzeichnis)' {$operation='ReadDirectory';$side='Source';break}
            '(Creating Destination Directory|Erstellen des Zielverzeichnisses)' {$operation='CreateDirectory';$side='Destination';break}
            '(Accessing Destination Directory|Zugriff auf Zielverzeichnis)' {$operation='ReadDirectory';$side='Destination';break}
            '(Time|Zeit|Attribut)' {$operation='Metadata';break}
        }
        if($operation -ne 'CopyFile'){$onlyFileCopy=$false}
        $key="$code|$operation|$side"
        if(-not $groups.ContainsKey($key)){$groups[$key]=@{Code=$code;Operation=$operation;Side=$side;Events=0}}
        $groups[$key].Events++
    }
    $preexcluded=0
    if($Context){$preexcluded=@($Context.Items.Values | Where-Object {$_.Stage -in @('Preflight','Preview')}).Count}
    $known=$rows.ContainsKey('Files') -and $rows.ContainsKey('Directories') -and $rows.Directories.Failed -eq 0 -and $onlyFileCopy -and $ExitCode -lt 16
    if($ExitCode -ge 8 -and @($ErrorLines).Count -eq 0){$known=$false}
    $pending=$null;$percent=$null
    if($known){
        $pending=[long]$rows.Files.Failed+$preexcluded
        if($pending -gt $rows.Files.Total){$known=$false;$pending=$null}
        elseif($rows.Files.Total -gt 0){$percent=[math]::Round(100.0*$pending/$rows.Files.Total,4)}
    }
    [pscustomobject]@{Basis='RobocopySummary';Files=$rows.Files;Bytes=$rows.Bytes;Directories=$rows.Directories;InventoryComplete=[bool]$known;PreflightDeferred=$preexcluded;NotUpdated=$pending;NotUpdatedPercent=$percent;Errors=@($groups.Values);ExitCode=$ExitCode}
}

function Set-GuardCopyDiagnostics {
    param([hashtable]$Context,[string[]]$SummaryLines,[string[]]$ErrorLines,[int]$ExitCode,[string]$Stage='Copy')
    if(-not $Context){return}
    $measurement=Get-GuardCopyMeasurement $SummaryLines $ErrorLines $Context $ExitCode
    $Context.Measurement=$measurement
    $Context.Diagnostics=[pscustomobject]@{Stage=$Stage;Account=[Security.Principal.WindowsIdentity]::GetCurrent().Name;SourcePath=$Context.SourcePath;DestinationPath=$Context.DestinationPath;ObservedAt=(Get-Date).ToString('o');ExitCode=$ExitCode;ErrorCount=@($ErrorLines).Count;Truncated=(@($ErrorLines).Count -gt 256);ErrorLines=@($ErrorLines | Select-Object -First 256 | ForEach-Object {$_.Substring(0,[math]::Min(4096,$_.Length))})}
}

function Format-GuardCopyMeasurement {
    param($Measurement)
    if(-not $Measurement -or -not $Measurement.InventoryComplete -or $null -eq $Measurement.NotUpdated){return 'Extent unknown (no complete copy inventory)'}
    $total=$Measurement.Files.Total
    if($total -eq 0){return '0 files enumerated'}
    $percent=if($Measurement.NotUpdatedPercent -gt 0 -and $Measurement.NotUpdatedPercent -lt 0.01){'<0.01'}else{'{0:0.##}' -f $Measurement.NotUpdatedPercent}
    '{0:N0} / {1:N0} not updated ({2}%)' -f $Measurement.NotUpdated,$total,$percent
}

Export-ModuleMember -Function Get-GuardCopyMeasurement,Set-GuardCopyDiagnostics,Format-GuardCopyMeasurement
