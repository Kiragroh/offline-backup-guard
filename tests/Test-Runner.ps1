$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$temp=Join-Path ([IO.Path]::GetTempPath()) ('backup-guard-runner-'+[guid]::NewGuid())
New-Item -ItemType Directory -Path "$temp\src","$temp\source","$temp\mount" | Out-Null
$passed=0
function Check($condition,$message){if(-not $condition){throw $message};$script:passed++;Write-Output "PASS $message"}
$oldCase=$env:GUARD_TEST_CASE;$oldTrace=$env:GUARD_TEST_TRACE;$oldSource=$env:GUARD_TEST_SOURCE
try {
    foreach($name in 'Run-Backup.ps1','Operations.psm1','Reporting.psm1'){Copy-Item -LiteralPath (Join-Path $root "src\$name") -Destination "$temp\src\$name"}
    Copy-Item -LiteralPath "$PSScriptRoot\fixtures\BackupGuard.psm1","$PSScriptRoot\fixtures\Versioning.psm1" -Destination "$temp\src"
    Import-Module "$temp\src\Operations.psm1" -Force
    $env:GUARD_TEST_SOURCE="$temp\source"
    $engine=(Get-Process -Id $PID).Path
    foreach($case in 'success','canary','copy','offline','invalid','validation','mount','late-lock') {
        $private=Join-Path $temp ('case-'+$case)
        New-Item -ItemType Directory -Path $private | Out-Null
        $config=Join-Path $private 'backup.psd1'
        $escaped=$temp.Replace("'","''");$privateEscaped=$private.Replace("'","''")
        $text=@"
@{
ReadyForUse=`$true;SourceListPath='$privateEscaped\sources.csv';StateRoot='$privateEscaped\state';LogRoot='$privateEscaped\logs';ReportRoot='$privateEscaped\reports'
Threads=2;RetentionDays=30;WindowStart='00:00';WindowEnd='23:59'
Canary=@{Path='$privateEscaped\canary.txt';ExpectedText='test';ExpectedSha256='$('0'*64)'}
BackupDisk=@{SerialNumber='synthetic';VolumeLabel='TEST';PreferredAccessPath='$escaped\mount'}
}
"@
        if($case -eq 'invalid'){$text='@{ broken syntax'}
        [IO.File]::WriteAllText($config,$text)
        $env:GUARD_TEST_CASE=$case;$env:GUARD_TEST_TRACE=Join-Path $private 'trace.txt'
        $args=@('-NoProfile','-NonInteractive','-File',"$temp\src\Run-Backup.ps1",'-ConfigPath',$config)
        if($case -eq 'validation'){$args+='-ValidateOnly'}else{$args+='-AllowManualRun'}
        $output=& $engine @args 2>&1
        $code=$LASTEXITCODE
        $diag=Get-GuardDiagnosticsPath $config
        $files=@(Get-ChildItem -LiteralPath (Join-Path $diag 'runs') -Filter '*.json')
        Check ($files.Count -eq 1) "$case has durable run record"
        $run=Read-GuardJson $files[0].FullName
        $trace=if(Test-Path $env:GUARD_TEST_TRACE){[IO.File]::ReadAllText($env:GUARD_TEST_TRACE)}else{''}
        if($case -in 'success','validation','late-lock') {
            if($code -ne 0){Write-Output $output}
            Check ($code -eq 0 -and $run.success) "$case exits successfully"
        } else { Check ($code -eq 1 -and -not $run.success -and $run.error) "$case error reaches journal and exit status" }
        if($case -in 'canary','invalid','validation') { Check ($trace -eq '') "$case never touches disk lifecycle" }
        else { Check ($trace -match 'mount' -and $trace -match 'offline') "$case attempts offline after mount" }
        if($case -eq 'offline') { Check ($run.offline -eq $false -and $run.error -match 'offline') 'Offline failure cannot look successful' }
        if($case -eq 'copy') { Check ($run.offline -eq $true -and $run.sources[0].error -match 'read denied') 'Copy failure preserves source reason and offline confirmation' }
        if($case -eq 'mount') { Check ($run.failure_phase -eq 'Mount' -and $run.phase -eq 'Mount' -and $run.offline) 'Cleanup does not overwrite initiating mount failure phase' }
        if($case -eq 'late-lock') { Check ($run.status -eq 'Warning' -and $run.sources[0].locked_at_copy -eq 1 -and $trace -notmatch 'retention') 'Late sharing locks remain visible and defer retention' }
    }
    Write-Output "All $passed runner checks passed with test doubles only."
} finally {
    $env:GUARD_TEST_CASE=$oldCase;$env:GUARD_TEST_TRACE=$oldTrace;$env:GUARD_TEST_SOURCE=$oldSource
    $full=[IO.Path]::GetFullPath($temp);$allowed=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $full.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $full -Leaf) -notlike 'backup-guard-runner-*'){throw 'Unsafe cleanup path'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
exit 0
