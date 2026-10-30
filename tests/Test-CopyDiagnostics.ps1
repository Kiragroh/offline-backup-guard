$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src\CopyDiagnostics.psm1') -Force
Import-Module (Join-Path $root 'src\Operations.psm1') -Force
$engine=Import-Module (Join-Path $root 'src\BackupGuard.psm1') -Force -PassThru
$passed=0
function Check($value,$label){if(-not $value){throw $label};$script:passed++;Write-Output "PASS $label"}
function Summary($total=1000,$failed=1){@('Dirs : 2 0 2 0 0 0',"Files : $total 0 $($total-$failed) 0 $failed 0",'Bytes : 10000 0 9990 0 10 0')}
$errorLine='ERROR 5 (0x00000005) Copying File C:\ExampleData\item.txt'
$ctx=@{Items=@{};SourcePath='C:\ExampleData';DestinationPath='C:\ExampleBackup'}
$m=Get-GuardCopyMeasurement (Summary) @($errorLine) $ctx 8
Check ($m.InventoryComplete -and $m.NotUpdated -eq 1 -and $m.NotUpdatedPercent -eq 0.1) 'One of a thousand is measured as 0.1 percent'
Check ((Format-GuardCopyMeasurement $m) -match 'not updated' -and $m.Errors[0].Side -eq 'SourceOrDestination') 'Ambiguous access denied does not invent which endpoint denied access'
$g=Get-GuardCopyMeasurement @('Verzeich. : 2 0 2 0 0 0','Dateien : 1000 0 999 0 1 0') @('FEHLER 32 (0x00000020) Kopieren der Datei C:\ExampleData\item.txt') $ctx 8
Check ($g.InventoryComplete -and $g.NotUpdatedPercent -eq 0.1) 'German summary and operation are recognized'
$half=Get-GuardCopyMeasurement (Summary 1000 500) @($errorLine) $ctx 8
Check ($half.NotUpdatedPercent -eq 50) 'Widespread omissions measured separately'
$ctx.Items['preflight']=@{Stage='Preflight'}
$ctx.Items['copy']=@{Stage='Copy'}
$pre=Get-GuardCopyMeasurement (Summary) @($errorLine) $ctx 8
Check ($pre.NotUpdated -eq 2) 'Copy-stage errors are not counted twice with deferred ledger'
$ctx.Items=@{}
foreach($line in @('ERROR 5 (0x00000005) Accessing Source Directory C:\ExampleData\','ERROR 5 (0x00000005) Deleting Extra File C:\ExampleBackup\old.txt')){
    $unknown=Get-GuardCopyMeasurement (Summary) @($line) $ctx 8
    Check (-not $unknown.InventoryComplete -and $null -eq $unknown.NotUpdatedPercent) 'Directory and deletion failures never become a reassuring file percentage'
}
Check (-not (Get-GuardCopyMeasurement @() @($errorLine) $ctx 8).InventoryComplete) 'Missing summary remains unknown'
Check (-not (Get-GuardCopyMeasurement (Summary) @() $ctx 8).InventoryComplete) 'Unexplained failing exit remains unknown'
Check (-not (Get-GuardCopyMeasurement (Summary) @($errorLine) $ctx 16).InventoryComplete) 'Fatal result cannot claim complete inventory'
$empty=Get-GuardCopyMeasurement (Summary 0 0) @() $ctx 0
Check ($empty.InventoryComplete -and $null -eq $empty.NotUpdatedPercent -and (Format-GuardCopyMeasurement $empty) -eq '0 files enumerated') 'Empty inventory is not a fabricated zero percent'
Set-GuardCopyDiagnostics $ctx (Summary) (@($errorLine)*300) 8
Check ($ctx.Diagnostics.Truncated -and $ctx.Diagnostics.ErrorLines.Count -eq 256 -and $ctx.Diagnostics.ErrorCount -eq 300) 'Embedded native diagnostics are bounded with explicit truncation'
Check ($ctx.Diagnostics.Account -and $ctx.Diagnostics.SourcePath -eq 'C:\ExampleData') 'Execution identity and endpoints are retained in local diagnostics'
Check (($m | ConvertTo-Json -Depth 8) -notmatch 'ExampleData|item.txt') 'Aggregate measurement contains no file paths'
$run=@{kind='backup';status='Failed';offline=$true;success=$false;warnings=0;failure_phase='Copy';sources=@(@{success=$false;phase='Copy';measurement=$m},@{success=$true},@{success=$true})}
Check ((Get-GuardRunHealth $run) -eq 'Warning' -and -not $run.success -and $run.status -eq 'Failed') 'Measured localized copy failure is amber without rewriting raw outcome'
$run.sources[0].measurement=$half
Check ((Get-GuardRunHealth $run) -eq 'Failed') 'At least half of source files pending stays red'
$run.sources[0].measurement=$m;$run.offline=$false
Check ((Get-GuardRunHealth $run) -eq 'Failed') 'Failure to offline disk stays red'
$run.offline=$true;$run.fatal_failure=$true
Check ((Get-GuardRunHealth $run) -eq 'Failed') 'Global failure stays red'
$run.fatal_failure=$false;$run.sources[0].measurement=$null
Check ((Get-GuardRunHealth $run) -eq 'Failed') 'Unknown copy extent is not downgraded'
$run.sources[0].measurement=$m;$run.sources[1].success=$false
Check ((Get-GuardRunHealth $run) -eq 'Failed') 'At least half of source jobs failing stays red'
$run.success=$true;$run.sources=@(@{success=$true;measurement=$m})
Check ((Get-GuardRunHealth $run) -eq 'Succeeded') 'Small recognized deferral may remain green before warning threshold'
$run.sources[0].measurement=$half
Check ((Get-GuardRunHealth $run) -eq 'Failed') 'Normalized deferrals cannot conceal half a source missing'
foreach($code in @(23,39,112,1117,1392,1393)){
    $critical=Get-GuardCopyMeasurement (Summary) @("ERROR $code (0x00000001) Copying File C:\ExampleData\item.txt") $ctx 8
    $run.sources[0].measurement=$critical
    Check ((Get-GuardRunHealth $run) -eq 'Failed') "Disk integrity/capacity code $code stays red"
}
try{
    & $engine {
        function script:robocopy.exe {
            if($args -contains '/NJS' -or $args -notcontains '/BYTES'){throw 'Summary must be enabled in bytes'}
            $global:LASTEXITCODE=8
            'ERROR 112 (0x00000070) Copying File C:\ExampleData\item.txt'
            'Dirs : 2 0 2 0 0 0'
            'Files : 1000 0 999 0 1 0'
        }
    }
    $caught=$false
    try{Invoke-RobocopyChecked @('C:\ExampleData','C:\ExampleBackup','/NJS') -DeferredContext $ctx | Out-Null}catch{$caught=$true}
    Check ($caught -and $ctx.Measurement.Files.Total -eq 1000 -and $ctx.Diagnostics.ErrorLines[0] -match '112') 'Copy evidence survives a fatal copy exception'
}finally{& $engine {Remove-Item Function:script:robocopy.exe -ErrorAction SilentlyContinue}}
Write-Output "All $passed copy diagnostics checks passed."
exit 0
