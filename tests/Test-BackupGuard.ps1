$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$module = Import-Module (Join-Path $root 'src\BackupGuard.psm1') -Force -PassThru
Import-Module (Join-Path $root 'src\Reporting.psm1') -Force
$temp = Join-Path ([IO.Path]::GetTempPath()) ('backup-guard-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $temp | Out-Null
$script:passed = 0
function Check([bool]$condition, [string]$message) { if (-not $condition) { throw $message }; $script:passed++; Write-Output "PASS $message" }
function MustThrow([scriptblock]$action, [string]$message) { $threw=$false; try { & $action | Out-Null } catch { $threw=$true }; Check $threw $message }
try {
    foreach($file in Get-ChildItem (Join-Path $root 'src') -File) {
        $tokens=$null; $errors=$null
        [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors) | Out-Null
        Check ($errors.Count -eq 0) "PowerShell parses: $($file.Name)"
    }
    $cfg=Import-PowerShellDataFile (Join-Path $root 'config\backup.example.psd1')
    Check ($cfg.ReadyForUse -eq $false) 'Example cannot run accidentally'
    $exampleSources=Import-BackupSourceList (Join-Path $root 'config\sources.example.csv')
    Check ($exampleSources.Count -eq 0) 'Example sources are disabled'
    $canary=Join-Path $temp 'canary.txt'
    [IO.File]::WriteAllText($canary,'sentinel')
    $hash=(Get-FileHash $canary -Algorithm SHA256).Hash
    Check (Test-BackupCanary $canary 'sentinel' $hash) 'Trusted canary passes'
    [IO.File]::WriteAllText($canary,'changed')
    MustThrow { Test-BackupCanary $canary 'sentinel' $hash } 'Changed canary fails closed'
    MustThrow { Get-BackupAirDisk @{SerialNumber=''} } 'Disk selection requires explicit identity without enumerating disks'
    & $module {
        function script:Get-Disk { [pscustomobject]@{FriendlyName='Demo USB';SerialNumber='demo-serial';Size=100GB;IsBoot=$true;IsSystem=$false;BusType='USB'} }
    }
    MustThrow { Get-BackupAirDisk @{SerialNumber='demo-serial'} } 'Mocked system disk is rejected'
    $source=[pscustomobject]@{MirrorDeletes=$true;MaxDeleteCount=2}
    MustThrow { Assert-RobocopyPreviewPolicy $source ([pscustomobject]@{ExtraFiles=3}) } 'Large deletion preview is rejected'
    Check (Test-RobocopyExitCode 7) 'Robocopy informational code accepted'
    Check (-not (Test-RobocopyExitCode 8)) 'Robocopy failure code rejected by default'
    $lockCount=& $module { Get-RobocopyLockOnlyCount @('ERROR 32 (0x00000020) Copying File C:\Example\a') 11 }
    Check ($lockCount -eq 1) 'Recognized file lock can become warning'
    $mixed=& $module { Get-RobocopyLockOnlyCount @('ERROR 32 (0x00000020) Copying File C:\Example\a','ERROR 5 (0x00000005) Copying File C:\Example\b') 11 }
    Check ($mixed -eq 0) 'Access errors are not swallowed alongside locks'
    New-Item -ItemType Directory -Path "$temp\source","$temp\destination" | Out-Null
    [IO.File]::WriteAllText("$temp\source\data.txt", 'updated content')
    [IO.File]::WriteAllText("$temp\destination\data.txt", 'old content')
    [IO.File]::SetLastWriteTimeUtc("$temp\destination\data.txt",[DateTime]::UtcNow.AddDays(-2))
    [IO.File]::WriteAllText("$temp\destination\deleted.txt", 'recover me')
    $arguments=Get-RobocopyArguments -SourcePath "$temp\source" -DestinationPath "$temp\destination" -LogPath "$temp\copy.log" -ExtraArgs @('/MT:2','/XJ','/FP') -MirrorDeletes
    $preview=Invoke-RobocopyPreview $arguments "$temp\copy.log"
    $saved=Save-LastResortMirrorChanges -SourcePath "$temp\source" -DestinationPath "$temp\destination" -LastResortRunPath "$temp\quarantine\demo\run" -PreviewSummary $preview
    Check ($saved.ArchivedFiles -eq 2) 'Replacement and deletion are retained before mirror'
    Invoke-RobocopyChecked -Arguments $arguments -PreviewSummary $preview | Out-Null
    Check ([IO.File]::ReadAllText("$temp\destination\data.txt") -eq 'updated content') 'Incremental copy applies update'
    Check (-not (Test-Path "$temp\destination\deleted.txt")) 'Mirror removes deleted source file'
    Check ([IO.File]::ReadAllText("$temp\quarantine\demo\run\deleted.txt") -eq 'recover me') 'Deleted data remains recoverable in quarantine'
    [IO.File]::WriteAllText("$temp\source\data.txt", 'locked next revision')
    $handle=[IO.File]::Open("$temp\source\data.txt",'Open','ReadWrite','None')
    try {
        $preview=Invoke-RobocopyPreview $arguments "$temp\copy.log"
        Check ($preview.LockedPaths.Count -eq 2) 'Locked source and target excluded for this run'
        Invoke-RobocopyChecked -Arguments $arguments -PreviewSummary $preview | Out-Null
        Check ([IO.File]::ReadAllText("$temp\destination\data.txt") -eq 'updated content') 'Lock preserves previous destination'
    } finally { $handle.Dispose() }
    Invoke-RobocopyChecked -Arguments $arguments | Out-Null
    Check ([IO.File]::ReadAllText("$temp\destination\data.txt") -eq 'locked next revision') 'Next run catches up after unlock'
    $run=[ordered]@{success=$true;offline=$true;finished_at='2026-01-02T07:00:00+00:00';sources=@();storage=@{measured_at='2026-01-02T03:00:00+00:00';capacity_bytes=1000;free_bytes=600;used_bytes=400}}
    Publish-BackupReport -ReportRoot "$temp\reports" -Run $run
    Publish-BackupReport -ReportRoot "$temp\reports" -Run $run
    $history=@(Get-Content "$temp\reports\storage-history.json" -Raw | ConvertFrom-Json)
    Check ($history.Count -eq 1) 'Repeated reports do not duplicate daily measurements'
    $run.finished_at='2026-01-04T07:00:00+00:00';$run.storage=$null;$run.success=$false
    Publish-BackupReport -ReportRoot "$temp\reports" -Run $run
    $reportText=Get-Content "$temp\reports\latest.md" -Raw
    if ($reportText -notmatch 'stale.*True') { Write-Output $reportText }
    Check ($reportText -match 'stale.*True') 'Missing sample stays old and is marked stale'
    Check ((Get-Content "$temp\reports\latest.md" -Raw) -match 'FAILED') 'Failed job remains visible'
    Write-Output "All $script:passed checks passed. No real disk-management operation was performed."
} finally {
    $resolved=[IO.Path]::GetFullPath($temp)
    $allowed=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if (-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'backup-guard-test-*') { throw 'Unsafe test cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
