#Requires -Version 5.1
param([string]$ScreenshotDirectory=(Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\smoke'))
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
function Check($value,$label){if(-not $value){throw $label};Write-Output "PASS $label"}
Check (Test-Path (Join-Path $root 'src\Desktop.psm1')) 'Desktop lifecycle module exists'
Import-Module (Join-Path $root 'src\Desktop.psm1') -Force
Check ((Get-GuardCloseAction 'UserClosing' $false $false) -eq 'Hide') 'Window close hides'
Check ((Get-GuardCloseAction 'WindowsShutDown' $false $true) -eq 'Close') 'Windows shutdown is not cancelled by busy work'
Check ((Get-GuardCloseAction 'UserClosing' $true $true) -eq 'Wait') 'Explicit exit never terminates a busy worker'
Check ((Get-GuardCloseAction 'UserClosing' $true $false) -eq 'Close') 'Explicit idle exit closes'
foreach($state in @('Succeeded','Running','Warning','Failed','Interrupted','Unknown','Missed','Needs attention')){
    Check ((Get-GuardHealthIcon $state) -in @('success','running','warning','error','unknown')) "Health mapping: $state"
}
$id='BackupGuardTest.'+[guid]::NewGuid().ToString('N')
$session=New-GuardDesktopSession -AppId $id
try{
    Check (-not $session.FocusOnly) 'First isolated launch owns session'
    $name=$session.EventName
    Check ($name -eq ('Local\'+$id+'.'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value+'.Focus')) 'IPC identity contains app ID and current SID'
    $second=New-GuardDesktopSession -EventName $name
    try{$second.Event.Set()|Out-Null;Check ($session.Event.WaitOne(0)) 'Hosted editor and owner share auto-reset focus signal';Check (-not $session.Event.WaitOne(0)) 'Focus signal is consumed once'}finally{$second.Event.Dispose()}
}finally{$session.Event.Dispose();$session.Mutex.ReleaseMutex();$session.Mutex.Dispose()}
[void][IO.Directory]::CreateDirectory($ScreenshotDirectory)
& (Join-Path $root 'desktop\New-DesktopIcon.ps1') -OutputDirectory (Join-Path $root 'assets\desktop')
foreach($name in @('app','unknown','success','running','warning','error')){
    $bytes=[IO.File]::ReadAllBytes((Join-Path $root ('assets\desktop\'+$name+'.ico')))
    $sizes=@(0..6|ForEach-Object{$width=[int]$bytes[6+16*$_];if($width -eq 0){256}else{$width}})
    Check ([BitConverter]::ToUInt16($bytes,4) -eq 7 -and ($sizes -join ',') -eq '16,24,32,48,64,128,256') "Seven native icon resolutions: $name"
}
& powershell.exe -NoProfile -STA -File (Join-Path $root 'Start-BackupGuard.ps1') -SmokeTest -ScreenshotPath (Join-Path $ScreenshotDirectory 'desktop.png')
Check ($LASTEXITCODE -eq 0) 'Real Windows Forms synthetic lifecycle and five screenshots pass'
Check (@(Get-ChildItem -LiteralPath $ScreenshotDirectory -Filter '*.png').Count -ge 5) 'All editor/status screenshots exist'
