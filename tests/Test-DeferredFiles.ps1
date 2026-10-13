$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src\DeferredFiles.psm1') -Force
$engine=Import-Module (Join-Path $root 'src\BackupGuard.psm1') -Force -PassThru
Import-Module (Join-Path $root 'src\Operations.psm1') -Force
$temp=Join-Path ([IO.Path]::GetTempPath()) ('backup-guard-deferred-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$temp\source","$temp\target" | Out-Null
$passed=0
function Check($value,$message){if(-not $value){throw $message};$script:passed++;Write-Output "PASS $message"}
function Context($id){New-GuardDeferredContext -StateRoot "$temp\state" -RunId $id -Name Example -SourcePath "$temp\source" -DestinationPath "$temp\target"}
try{
    foreach($n in 1..7){
        $ctx=Context "run-$n"
        Add-GuardDeferredFile $ctx "$temp\source\file.txt" 32 Preflight
        $result=Save-GuardDeferredComponent $ctx $true
        $state=Get-GuardDeferredStatus "$temp\state"
        Check ($state.Count -eq 1 -and $state.Entries[0].ConsecutiveRuns -eq $n -and $state.OverdueCount -eq [int]($n -ge 7)) "Persistent file warns exactly at run seven: $n"
        Save-GuardDeferredComponent $ctx $true | Out-Null
        Check ((Get-GuardDeferredStatus "$temp\state").Entries[0].ConsecutiveRuns -eq $n) "Same run does not increment twice: $n"
    }
    Save-GuardDeferredComponent (Context 'failed') $false | Out-Null
    Check ((Get-GuardDeferredStatus "$temp\state").Count -eq 1) 'Failed component retains unresolved entries'
    Save-GuardDeferredComponent (Context 'recovered') $true | Out-Null
    Check ((Get-GuardDeferredStatus "$temp\state").Count -eq 0) 'Successful catch-up clears unresolved entries'
    foreach($code in 2,3,5,32,33){
        $ctx=Context "code-$code"
        Check (Test-GuardDeferredErrors @("ERROR $code (0x00000001) Copying File $temp\source\example.txt") 11 $ctx Copy) "Individual file code $code is eligible"
    }
    foreach($line in @("ERROR 1392 (0x00000570) Copying File $temp\source\bad.txt","ERROR 112 (0x00000070) Copying File $temp\source\full.txt","ERROR 5 (0x00000005) Accessing Source Directory $temp\source\","ERROR 5 (0x00000005) Copying File $temp\outside.txt")){
        Check (-not (Test-GuardDeferredErrors @($line) 11 (Context 'fatal') Copy)) 'Hard, directory or outside-root error stays fatal'
    }
    $ctx=Context 'mixed'
    Check (-not (Test-GuardDeferredErrors @("ERROR 32 (0x00000020) Copying File $temp\source\file.txt","ERROR 112 (0x00000070) Copying File $temp\source\full.txt") 11 $ctx Copy) -and $ctx.Items.Count -eq 0) 'Mixed error batch is not partially accepted'
    Check (-not (Test-GuardDeferredErrors @("ERROR 32 (0x00000020) Copying File $temp\source\file.txt") 16 $ctx Copy)) 'Fatal Robocopy result never normalizes'
    [IO.File]::WriteAllText("$temp\source\file.txt",'new contents')
    [IO.File]::WriteAllText("$temp\target\file.txt",'previous backup')
    [IO.File]::SetLastWriteTimeUtc("$temp\target\file.txt",[datetime]::UtcNow.AddDays(-2))
    $argsCopy=Get-RobocopyArguments "$temp\source" "$temp\target" "$temp\copy.log" -MirrorDeletes -ExtraArgs @('/MT:2','/FP')
    $handle=[IO.File]::Open("$temp\source\file.txt",'Open','ReadWrite','None')
    try{
        $ctx=Context 'real-lock'
        $preview=Invoke-RobocopyPreview $argsCopy "$temp\copy.log" -DeferredContext $ctx
        Invoke-RobocopyChecked $argsCopy -PreviewSummary $preview -DeferredContext $ctx | Out-Null
        Save-GuardDeferredComponent $ctx $true | Out-Null
        Check ((Get-GuardDeferredStatus "$temp\state").Count -eq 1 -and [IO.File]::ReadAllText("$temp\target\file.txt") -eq 'previous backup') 'Real locked source preserves old destination and records pending file'
    }finally{$handle.Dispose()}
    $ctx=Context 'real-catchup'
    Invoke-RobocopyChecked $argsCopy -DeferredContext $ctx | Out-Null
    Save-GuardDeferredComponent $ctx $true | Out-Null
    Check ((Get-GuardDeferredStatus "$temp\state").Count -eq 0 -and [IO.File]::ReadAllText("$temp\target\file.txt") -eq 'new contents') 'Real next run catches up and clears pending file'
    $cfg=Join-Path $temp 'backup.psd1'
    [IO.File]::WriteAllText($cfg,"@{ StateRoot='$($temp.Replace("'","''"))\state'; ReportRoot='$($temp.Replace("'","''"))\reports' }")
    $run=New-GuardRun $cfg;$run.success=$true;Complete-GuardRun $run
    $task=[pscustomobject]@{Drift=@();State='Ready';LastResult=0;NextRun=$null}
    foreach($n in 1..7){
        $ctx=Context "health-$n";Add-GuardDeferredFile $ctx "$temp\source\file.txt" 5 Copy;Save-GuardDeferredComponent $ctx $true | Out-Null
        Check ((Get-GuardStatus $cfg -TaskSnapshot $task).State -eq $(if($n -ge 7){'Warning'}else{'Succeeded'})) "Offline status threshold at run $n"
    }
    Check ((Get-GuardStatus $cfg -TaskSnapshot $task).State -eq 'Warning') 'Seventh pending run warns in offline-readable status'
    [IO.File]::WriteAllText("$temp\state\deferred-files.json",'{broken')
    $state=Get-GuardDeferredStatus "$temp\state"
    Check (-not $state.Valid -and $null -eq $state.Count) 'Unreadable ledger is unknown, not empty'
    Check ((Get-GuardStatus $cfg -TaskSnapshot $task).State -eq 'Unknown') 'Unreadable ledger cannot appear healthy'
    Write-Output "All $passed deferred checks passed; synthetic files only."
}finally{
    $full=[IO.Path]::GetFullPath($temp);$allowed=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $full.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $full -Leaf) -notlike 'backup-guard-deferred-*'){throw 'Unsafe test cleanup'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
exit 0
