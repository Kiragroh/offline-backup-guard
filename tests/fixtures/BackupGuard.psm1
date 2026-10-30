# Test double only. No Storage cmdlets or real disk operations are used.
Import-Module (Join-Path $PSScriptRoot 'CopyDiagnostics.psm1')
function Trace($message) { [IO.File]::AppendAllText($env:GUARD_TEST_TRACE, "$message`n") }
function Test-BackupCanary { param($Path,$ExpectedText,$ExpectedSha256) if($env:GUARD_TEST_CASE -eq 'canary'){throw 'Synthetic canary mismatch'}; $true }
function Import-BackupSourceList { param($Path) return ,@([pscustomobject]@{Name='Synthetic';SourcePath=$env:GUARD_TEST_SOURCE;DestinationSubfolder='demo';PreviousVersions=1;DeletedRetentionDays=30;MirrorDeletes=$true}) }
function Test-BackupSourceCanary { param($Source) $true }
function Get-BackupAirDisk { param($DiskConfig) [pscustomobject]@{IsOffline=($env:GUARD_TEST_CASE -ne 'offline')} }
function Mount-BackupAirDisk { param($DiskConfig) Trace 'mount'; if($env:GUARD_TEST_CASE -eq 'mount'){throw 'Synthetic mount failure'}; $DiskConfig.PreferredAccessPath }
function Dismount-BackupAirDisk { param($DiskConfig) Trace 'offline'; if($env:GUARD_TEST_CASE -eq 'offline'){throw 'Synthetic offline failure'} }
function Get-BackupMirrorPath { param($DestinationRoot,$Source) Join-Path $DestinationRoot "Current\$($Source.DestinationSubfolder)" }
function Get-RobocopyArguments { param($SourcePath,$DestinationPath,$LogPath,[switch]$MirrorDeletes,$ExtraArgs) @('/L') }
function Invoke-RobocopyPreview { param($Arguments,$LogPath,$DeferredContext) [pscustomobject]@{ChangedLines=0;LockedPaths=@()} }
function Assert-RobocopyPreviewPolicy { param($Source,$Summary) $true }
function Invoke-RobocopyChecked {
    param($Arguments,$PreviewSummary,[switch]$PassThruResult,$DeferredContext)
    Trace 'copy'
    $pending=$env:GUARD_TEST_CASE -in @('copy','late-lock','large-deferral')
    $total=if($env:GUARD_TEST_CASE -eq 'large-deferral'){1}else{1000}
    $errors=if($pending){@("ERROR 32 (0x00000020) Copying File $env:GUARD_TEST_SOURCE\example.txt")}else{@()}
    Set-GuardCopyDiagnostics $DeferredContext @('Dirs : 1 0 1 0 0 0',"Files : $total 0 $($total-[int]$pending) 0 $([int]$pending) 0") $errors $(if($pending){8}else{0})
    if($env:GUARD_TEST_CASE -eq 'copy'){throw 'Synthetic read denied'}
    if($pending){Add-GuardDeferredFile $DeferredContext (Join-Path $env:GUARD_TEST_SOURCE 'example.txt') 32 Copy;[pscustomobject]@{ExitCode=8;NormalizedExitCode=0;LockedAtCopy=1}}
    else{[pscustomobject]@{ExitCode=1;NormalizedExitCode=1;LockedAtCopy=0}}
}
function Get-Volume { param($FilePath) [pscustomobject]@{Size=1000;SizeRemaining=600} }
function Write-BackupAirLog { param($Path,$Message) [IO.File]::AppendAllText($Path,"$Message`n") }
Export-ModuleMember -Function *
