$ErrorActionPreference='Stop'

function New-GuardDeferredContext {
    param([string]$StateRoot,[string]$RunId,[string]$Name,[string]$SourcePath,[string]$DestinationPath,[int]$WarningAfterRuns=7)
    if($WarningAfterRuns -lt 1 -or $WarningAfterRuns -gt 365){throw 'Deferred warning threshold must be between 1 and 365 runs.'}
    @{StateRoot=$StateRoot;RunId=$RunId;Name=$Name;SourcePath=$SourcePath.TrimEnd('\');DestinationPath=$DestinationPath.TrimEnd('\');WarningAfterRuns=$WarningAfterRuns;Items=@{}}
}

function Add-GuardDeferredFile {
    param([hashtable]$Context,[string]$Path,[int]$ErrorCode,[string]$Stage)
    if(-not $Context -or $ErrorCode -notin @(2,3,5,32,33)){throw 'File error is not eligible for deferral.'}
    $full=[IO.Path]::GetFullPath($Path.Trim().Trim('"'));$relative=$null
    foreach($root in @($Context.SourcePath,$Context.DestinationPath)){
        $prefix=[IO.Path]::GetFullPath($root).TrimEnd('\')+'\'
        if($full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){$relative=$full.Substring($prefix.Length);break}
    }
    if([string]::IsNullOrWhiteSpace($relative) -or $relative.EndsWith('\')){throw 'Deferred file must be below the exact source or destination root.'}
    $reason=switch($ErrorCode){2 {'File disappeared during the run'} 3 {'File path disappeared during the run'} 5 {'File access denied'} default {'File is locked by another process'}}
    $Context.Items[$relative.ToLowerInvariant()]=@{RelativePath=$relative;ErrorCode=$ErrorCode;Reason=$reason;Stage=$Stage}
}

function Test-GuardDeferredErrors {
    param([string[]]$Lines,[int]$ExitCode,[hashtable]$Context,[string]$Stage)
    if(-not $Context -or $ExitCode -lt 8 -or $ExitCode -ge 16 -or @($Lines).Count -eq 0){return $false}
    $candidate=@{}
    foreach($line in $Lines){
        if($line -notmatch '(?i)\b(?:ERROR|FEHLER)\s+(2|3|5|32|33)\s+\(0x[0-9a-f]+\)\s+(?:Copying File|Folgende Datei wird kopiert|Kopieren der Datei)\s+(.+)$'){return $false}
        $code=[int]$Matches[1];$path=$Matches[2];$probe=$Context.Clone();$probe.Items=@{}
        try{Add-GuardDeferredFile $probe $path $code $Stage}catch{return $false}
        foreach($key in $probe.Items.Keys){$candidate[$key]=$probe.Items[$key]}
    }
    foreach($key in $candidate.Keys){$Context.Items[$key]=$candidate[$key]}
    return $true
}

function Get-GuardDeferredExclusions {
    param([hashtable]$Context)
    if($Context){foreach($item in $Context.Items.Values){Join-Path $Context.SourcePath $item.RelativePath;Join-Path $Context.DestinationPath $item.RelativePath}}
}

function Get-GuardDeferredStatus {
    param([string]$StateRoot)
    try{
        if(-not $StateRoot -or -not (Test-Path -LiteralPath (Join-Path $StateRoot 'deferred-files.json'))){return [pscustomobject]@{Valid=$true;Count=0;OverdueCount=0;WarningAfterRuns=7;Entries=@();Error=''}}
        $data=Get-Content -LiteralPath (Join-Path $StateRoot 'deferred-files.json') -Raw | ConvertFrom-Json
        if($data.Schema -ne 1 -or $data.Entries -isnot [array] -or $data.WarningAfterRuns -lt 1 -or $data.WarningAfterRuns -gt 365){throw 'Invalid ledger schema.'}
        foreach($entry in $data.Entries){if(-not $entry.RelativePath -or -not $entry.SourceName -or [int]$entry.ConsecutiveRuns -lt 1){throw 'Invalid deferred entry.'}}
        [pscustomobject]@{Valid=$true;Count=@($data.Entries).Count;OverdueCount=@($data.Entries|Where-Object {$_.ConsecutiveRuns -ge $data.WarningAfterRuns}).Count;WarningAfterRuns=[int]$data.WarningAfterRuns;Entries=@($data.Entries);Error=''}
    }catch{[pscustomobject]@{Valid=$false;Count=$null;OverdueCount=$null;WarningAfterRuns=7;Entries=@();Error='Deferred-file ledger is unreadable. Inspect local diagnostics.'}}
}

function Save-GuardDeferredComponent {
    param([hashtable]$Context,[bool]$Completed)
    $status=Get-GuardDeferredStatus $Context.StateRoot
    if(-not $status.Valid){throw $status.Error}
    $previous=@{};$retained=[Collections.Generic.List[object]]::new()
    foreach($entry in $status.Entries){
        if($entry.SourceName -eq $Context.Name -and $entry.SourcePath -eq $Context.SourcePath -and $entry.DestinationPath -eq $Context.DestinationPath){$previous[$entry.RelativePath.ToLowerInvariant()]=$entry}
        else{$retained.Add($entry)}
    }
    $now=(Get-Date).ToString('o');$overdue=0
    foreach($key in $Context.Items.Keys){
        $item=$Context.Items[$key];$old=$previous[$key];$count=1;$first=$now
        if($old){$first=$old.FirstSeen;$count=[int]$old.ConsecutiveRuns;if($old.LastRunId -ne $Context.RunId){$count++}}
        if($count -ge $Context.WarningAfterRuns){$overdue++}
        $retained.Add([ordered]@{SourceName=$Context.Name;SourcePath=$Context.SourcePath;DestinationPath=$Context.DestinationPath;RelativePath=$item.RelativePath;ErrorCode=$item.ErrorCode;Reason=$item.Reason;Stage=$item.Stage;FirstSeen=$first;LastSeen=$now;LastRunId=$Context.RunId;ConsecutiveRuns=$count})
    }
    if(-not $Completed){foreach($key in $previous.Keys){if(-not $Context.Items.ContainsKey($key)){$retained.Add($previous[$key])}}}
    New-Item -ItemType Directory -Path $Context.StateRoot -Force | Out-Null
    $path=Join-Path $Context.StateRoot 'deferred-files.json';$temporary=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        $data=[ordered]@{Schema=1;UpdatedAt=$now;WarningAfterRuns=$Context.WarningAfterRuns;Entries=@($retained.ToArray())}
        [IO.File]::WriteAllText($temporary,($data|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
        if(Test-Path -LiteralPath $path){[IO.File]::Replace($temporary,$path,[NullString]::Value)}else{[IO.File]::Move($temporary,$path)}
    }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary}}
    [pscustomobject]@{Count=$Context.Items.Count;OverdueCount=$overdue}
}

Export-ModuleMember -Function New-GuardDeferredContext,Add-GuardDeferredFile,Test-GuardDeferredErrors,Get-GuardDeferredExclusions,Get-GuardDeferredStatus,Save-GuardDeferredComponent
