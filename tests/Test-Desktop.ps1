#Requires -Version 5.1
param([switch]$KeepArtifacts)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$temp=Join-Path ([IO.Path]::GetTempPath()) ('backup-guard-desktop-test-'+[guid]::NewGuid().ToString('N'))
$id='BackupGuardTest.'+[guid]::NewGuid().ToString('N')
$name='Backup Guard Test '+[guid]::NewGuid().ToString('N')
$passed=0
function Check($value,$label){if(-not $value){throw $label};$script:passed++;Write-Output "PASS $label"}
function Run-Setup($exe,$arguments,$expected=0){
    $p=Start-Process -FilePath $exe -ArgumentList $arguments -PassThru -Wait
    Check ($p.ExitCode -eq $expected) "Setup $arguments returns $expected"
}
Check (Test-Path (Join-Path $root 'Build-Desktop.ps1')) 'Reusable native desktop builder exists'
New-Item -ItemType Directory -Path $temp | Out-Null
$install=Join-Path $env:LOCALAPPDATA ('Programs\'+$id)
$config=Join-Path $env:LOCALAPPDATA ($id+'\config\sentinel.txt')
try{
    & (Join-Path $root 'Build-Desktop.ps1') -OutputDirectory (Join-Path $temp "build space's") -AppId $id -Name $name -Version '8.0.0' -EntryScript 'tests\fixtures\DesktopProbe.ps1'
    $setup=Join-Path $temp "build space's\Setup.exe"
    Check (Test-Path $setup) 'Native installer was compiled'
    $unit=Join-Path $temp 'DesktopCommonTests.exe'
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler /nologo /target:exe /r:System.Windows.Forms.dll /r:System.Web.Extensions.dll "/resource:$(Join-Path $temp "build space's\brand.json"),brand.json" "/out:$unit" (Join-Path $root 'desktop\Common.cs') (Join-Path $root 'tests\fixtures\DesktopCommonTests.cs')
    Check ($LASTEXITCODE -eq 0) 'Native common regression tests compile'
    & $unit
    Check ($LASTEXITCODE -eq 0) 'Native literal quoting and path boundary regressions pass'
    $desktopLink=Join-Path ([Environment]::GetFolderPath('Desktop')) ($name+'.lnk')
    [IO.File]::WriteAllText($desktopLink,'FOREIGN')
    Run-Setup $setup '--install --no-startup' 1
    Check ([IO.File]::ReadAllText($desktopLink) -eq 'FOREIGN') 'Unowned shortcut collision remains untouched'
    Remove-Item -LiteralPath $desktopLink
    $versionDir=Join-Path $install 'versions\8.0.0'
    New-Item -ItemType Directory -Path $versionDir -Force|Out-Null
    $expectedHash=(Get-FileHash -LiteralPath (Join-Path $temp "build space's\package\Desktop.exe")).Hash
    [IO.File]::WriteAllText((Join-Path $versionDir 'installing.txt'),$expectedHash)
    [IO.File]::WriteAllText((Join-Path $versionDir 'Desktop.exe'),'INTERRUPTED COPY')
    New-Item -ItemType Directory -Path (Split-Path $config -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($config,'PRESERVE')
    Run-Setup $setup '--install --no-startup'
    Check (-not (Test-Path (Join-Path $versionDir 'installing.txt')) -and (Test-Path (Join-Path $versionDir 'complete.txt'))) 'Installer-owned interrupted version is recovered and marked complete'
    $current=Get-Content (Join-Path $install 'current.json') -Raw | ConvertFrom-Json
    Check ($current.Version -eq '8.0.0') 'Versioned install is activated'
    $shell=New-Object -ComObject WScript.Shell
    $link=$shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) ($name+'.lnk')))
    Check ($link.TargetPath -eq (Join-Path $install 'versions\8.0.0\Desktop.exe')) 'Desktop shortcut targets installed native application'
    Check (-not (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run').PSObject.Properties[$id]) 'Login startup is off when declined'
    $native=Start-Process -FilePath (Join-Path $versionDir 'Desktop.exe') -ArgumentList '--tray' -PassThru
    $probePath=Join-Path $versionDir 'tests\fixtures\probe.json'
    $stopPath=Join-Path $versionDir 'tests\fixtures\stop-probe'
    try{
        $deadline=[datetime]::UtcNow.AddSeconds(15)
        while(-not (Test-Path $probePath) -and [datetime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
        Check (Test-Path $probePath) 'Native host launches its exact packaged script'
        $probe=Get-Content $probePath -Raw|ConvertFrom-Json
        Check $probe.Tray 'Native --tray reaches the editor'
        $second=Start-Process -FilePath (Join-Path $versionDir 'Desktop.exe') -PassThru -Wait
        Check ($second.ExitCode -eq 0) 'Repeat native launch completes without another editor'
        $deadline=[datetime]::UtcNow.AddSeconds(5)
        do{Start-Sleep -Milliseconds 100;$focused=Get-Content $probePath -Raw|ConvertFrom-Json}while($focused.FocusCount -lt 1 -and [datetime]::UtcNow -lt $deadline)
        Check ($focused.Pid -eq $probe.Pid -and $focused.FocusCount -eq 1) 'Repeat native launch focuses the same PID through SID-scoped IPC'
        Run-Setup $setup '--install --startup' 1
        Check (-not $native.HasExited) 'Setup refuses an active app without terminating it'
    }finally{
        [IO.File]::WriteAllText($stopPath,'stop synthetic editor')
        Check ($native.WaitForExit(10000)) 'Native host ends after its editor exits'
        $native.Dispose()
    }
    Run-Setup $setup '--install --startup'
    Check ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run').$id -like '*Desktop.exe" --tray') 'Opted-in login startup targets native executable'
    $originalLink=[IO.File]::ReadAllBytes($desktopLink)
    [IO.File]::WriteAllText($desktopLink,'USER CHANGED')
    Run-Setup $setup '--uninstall --quiet' 1
    Check ([IO.File]::ReadAllText($desktopLink) -eq 'USER CHANGED') 'Uninstall refuses a user-modified shortcut'
    [IO.File]::WriteAllBytes($desktopLink,$originalLink)
    $installedSetup=Join-Path $versionDir 'Setup.exe'
    $savedSetup=Join-Path $temp 'saved-setup.exe'
    Copy-Item -LiteralPath $installedSetup -Destination $savedSetup
    Remove-Item -LiteralPath $installedSetup
    Run-Setup $setup '--install --startup' 1
    Check ((Get-Content (Join-Path $install 'current.json') -Raw|ConvertFrom-Json).Version -eq '8.0.0') 'Missing installed setup cannot activate an incomplete version'
    Copy-Item -LiteralPath $savedSetup -Destination $installedSetup
    & (Join-Path $root 'Build-Desktop.ps1') -OutputDirectory (Join-Path $temp 'older') -AppId $id -Name $name -Version '7.0.0'
    Run-Setup (Join-Path $temp 'older\Setup.exe') '--install --no-startup' 1
    Check ((Get-Content (Join-Path $install 'current.json') -Raw | ConvertFrom-Json).Version -eq '8.0.0') 'Downgrade cannot replace activated version'
    Run-Setup $setup '--uninstall --quiet'
    Check (-not (Test-Path (Join-Path ([Environment]::GetFolderPath('Desktop')) ($name+'.lnk')))) 'Uninstall removes desktop shortcut'
    Check (-not (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run').PSObject.Properties[$id]) 'Uninstall removes only isolated startup identity'
    Check ([IO.File]::ReadAllText($config) -eq 'PRESERVE') 'Uninstall preserves configuration'
    Check (Test-Path (Join-Path $install 'versions\8.0.0\src\Run-Backup.ps1')) 'Uninstall preserves runners potentially referenced by scheduled tasks'
    Write-Output "All $passed desktop installation checks passed. Isolated identity: $id"
}finally{
    if(Test-Path (Join-Path $temp "build space's\Setup.exe")){Run-Setup (Join-Path $temp "build space's\Setup.exe") '--uninstall --quiet'}
    if(-not $KeepArtifacts){
        foreach($path in @($temp,$install,(Join-Path $env:LOCALAPPDATA $id))){
            $full=[IO.Path]::GetFullPath($path)
            if($full -ne [IO.Path]::GetFullPath($temp) -and (Split-Path $full -Leaf) -ne $id){throw 'Unsafe isolated cleanup'}
            if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
        }
    }
}
