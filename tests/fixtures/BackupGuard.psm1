# Test double only. No Storage cmdlets or real disk operations are used.
function Trace($message) { [IO.File]::AppendAllText($env:GUARD_TEST_TRACE, "$message`n") }
function Test-BackupCanary { param($Path,$ExpectedText,$ExpectedSha256) if($env:GUARD_TEST_CASE -eq 'canary'){throw 'Synthetic canary mismatch'}; $true }
function Import-BackupSourceList { param($Path) return ,@([pscustomobject]@{Name='Synthetic';SourcePath=$env:GUARD_TEST_SOURCE;DestinationSubfolder='demo';PreviousVersions=1;DeletedRetentionDays=30;MirrorDeletes=$true}) }
function Test-BackupSourceCanary { param($Source) $true }
function Get-BackupAirDisk { param($DiskConfig) [pscustomobject]@{IsOffline=($env:GUARD_TEST_CASE -ne 'offline')} }
function Mount-BackupAirDisk { param($DiskConfig) Trace 'mount'; if($env:GUARD_TEST_CASE -eq 'mount'){throw 'Synthetic mount failure'}; $DiskConfig.PreferredAccessPath }
function Dismount-BackupAirDisk { param($DiskConfig) Trace 'offline'; if($env:GUARD_TEST_CASE -eq 'offline'){throw 'Synthetic offline failure'} }
function Get-BackupMirrorPath { param($DestinationRoot,$Source) Join-Path $DestinationRoot "Current\$($Source.DestinationSubfolder)" }
function Get-RobocopyArguments { param($SourcePath,$DestinationPath,$LogPath,[switch]$MirrorDeletes,$ExtraArgs) @('/L') }
function Invoke-RobocopyPreview { param($Arguments,$LogPath) [pscustomobject]@{ChangedLines=0;LockedPaths=@()} }
function Assert-RobocopyPreviewPolicy { param($Source,$Summary) $true }
function Invoke-RobocopyChecked { param($Arguments,$PreviewSummary,[switch]$PassThruResult) Trace 'copy'; if($env:GUARD_TEST_CASE -eq 'copy'){throw 'Synthetic read denied'}; if($env:GUARD_TEST_CASE -eq 'late-lock'){[pscustomobject]@{ExitCode=8;NormalizedExitCode=0;LockedAtCopy=1}}else{[pscustomobject]@{ExitCode=1;NormalizedExitCode=1;LockedAtCopy=0}} }
function Get-Volume { param($FilePath) [pscustomobject]@{Size=1000;SizeRemaining=600} }
function Write-BackupAirLog { param($Path,$Message) [IO.File]::AppendAllText($Path,"$Message`n") }
Export-ModuleMember -Function *
