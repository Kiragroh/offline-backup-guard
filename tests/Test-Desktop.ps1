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
$failure=$null
try{
    $builder=Join-Path $root 'Build-Desktop.ps1'
    Check ((Get-Command $builder).Parameters.ContainsKey('TestBuild')) 'Builder exposes an explicit isolated test-build switch'
    foreach($bad in @(
        @{AppId='OfflineBackupGuard';Name=$name;EntryScript='tests\fixtures\DesktopProbe.ps1'},
        @{AppId='BackupGuardTest.invalid';Name=$name;EntryScript='tests\fixtures\DesktopProbe.ps1'},
        @{AppId=$id;Name=$name;EntryScript='Start-BackupGuard.ps1'},
        @{AppId=$id;Name='Offline Backup Guard';EntryScript='tests\fixtures\DesktopProbe.ps1'}
    )){
        $rejected=$false
        try{& $builder @bad -TestBuild -Version '8.0.0' -OutputDirectory (Join-Path $temp 'rejected')}catch{$rejected=$_.Exception.Message -like 'TestBuild requires*'}
        Check $rejected 'Test build rejects a non-isolated identity, name or entry script'
        Check (-not (Test-Path (Join-Path $temp 'rejected'))) 'Rejected test profile creates no output'
    }
    & $builder -TestBuild -OutputDirectory (Join-Path $temp "build space's") -AppId $id -Name $name -Version '8.0.0' -EntryScript 'tests\fixtures\DesktopProbe.ps1'
    $setup=Join-Path $temp "build space's\Setup.exe"
    Check (Test-Path $setup) 'Native installer was compiled'
    $unit=Join-Path $temp 'DesktopCommonTests.exe'
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler /nologo /target:exe /r:System.Windows.Forms.dll /r:System.Web.Extensions.dll "/resource:$(Join-Path $temp "build space's\brand.json"),brand.json" "/out:$unit" (Join-Path $root 'desktop\Common.cs') (Join-Path $root 'tests\fixtures\DesktopCommonTests.cs')
    Check ($LASTEXITCODE -eq 0) 'Native common regression tests compile'
    & $unit
    Check ($LASTEXITCODE -eq 0) 'Native literal quoting and path boundary regressions pass'
    $gateSource=Join-Path $temp 'GateTests.cs'
    [IO.File]::WriteAllText($gateSource,@'
using System;
using BackupDesktop;
static class GateTests {
    static void Expect(bool setup,bool allowed) {
        bool passed=true;try{Common.Validate(setup);}catch(Exception){passed=false;}
        if(passed!=allowed)throw new Exception("Unexpected elevation gate result; setup="+setup+"; elevated="+Common.IsElevated);
    }
    static int Main() {
        try {
#if DESKTOP_TESTS
            Expect(true,true);Expect(false,true);
            string id=Common.Brand.AppId,entry=Common.Brand.EntryScript,name=Common.Brand.Name;
            Common.Brand.AppId="OfflineBackupGuard";Expect(true,false);Expect(false,false);Common.Brand.AppId=id;
            Common.Brand.EntryScript="Start-BackupGuard.ps1";Expect(true,false);Expect(false,false);Common.Brand.EntryScript=entry;
            Common.Brand.Name="Offline Backup Guard";Expect(true,false);Expect(false,false);Common.Brand.Name=name;
            Console.WriteLine("PASS DESKTOP_TESTS runtime identity/name/probe gates; elevated="+Common.IsElevated);
#else
            // Production restriction applies even to a synthetic-looking identity.
            Expect(true,!Common.IsElevated);Expect(false,!Common.IsElevated);
            Common.Brand.AllowAdministrativeLaunch=true;Expect(true,!Common.IsElevated);Expect(false,true);
            Console.WriteLine("PASS production setup/app elevation gates; elevated="+Common.IsElevated);
#endif
            return 0;
        }catch(Exception e){Console.Error.WriteLine(e);return 1;}
    }
}
'@)
    foreach($testMode in @($false,$true)){
        $gate=Join-Path $temp ("GateTests-$testMode.exe")
        $defines=@();if($testMode){$defines=@('/define:DESKTOP_TESTS')}
        & $compiler /nologo /target:exe /r:System.Windows.Forms.dll /r:System.Web.Extensions.dll @defines "/resource:$(Join-Path $temp "build space's\brand.json"),brand.json" "/out:$gate" (Join-Path $root 'desktop\Common.cs') $gateSource
        Check ($LASTEXITCODE -eq 0) "Elevation gate regression compiles: TestBuild=$testMode"
        & $gate
        Check ($LASTEXITCODE -eq 0) "Elevation gate regression passes: TestBuild=$testMode"
    }
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
    $nativeFailure=$null
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
    }catch{$nativeFailure=$_;throw}finally{
        try{
            [IO.File]::WriteAllText($stopPath,'stop synthetic editor')
            Check ($native.WaitForExit(10000)) 'Native host ends after its editor exits'
            $native.Dispose()
        }catch{
            if($nativeFailure){Write-Warning ('Synthetic editor cleanup also failed: '+$_.Exception.Message) -WarningAction Continue}else{throw}
        }
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
    & $builder -TestBuild -OutputDirectory (Join-Path $temp 'older') -AppId $id -Name $name -Version '7.0.0' -EntryScript 'tests\fixtures\DesktopProbe.ps1'
    Run-Setup (Join-Path $temp 'older\Setup.exe') '--install --no-startup' 1
    Check ((Get-Content (Join-Path $install 'current.json') -Raw | ConvertFrom-Json).Version -eq '8.0.0') 'Downgrade cannot replace activated version'
    Run-Setup $setup '--uninstall --quiet'
    Check (-not (Test-Path (Join-Path ([Environment]::GetFolderPath('Desktop')) ($name+'.lnk')))) 'Uninstall removes desktop shortcut'
    Check (-not (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run').PSObject.Properties[$id]) 'Uninstall removes only isolated startup identity'
    Check ([IO.File]::ReadAllText($config) -eq 'PRESERVE') 'Uninstall preserves configuration'
    Check (Test-Path (Join-Path $install 'versions\8.0.0\src\Run-Backup.ps1')) 'Uninstall preserves runners potentially referenced by scheduled tasks'
    Write-Output "All $passed desktop installation checks passed. Isolated identity: $id"
}catch{$failure=$_;throw}finally{
    try{
    if(Test-Path (Join-Path $temp "build space's\Setup.exe")){Run-Setup (Join-Path $temp "build space's\Setup.exe") '--uninstall --quiet'}
    if(-not $KeepArtifacts){
        foreach($path in @($temp,$install,(Join-Path $env:LOCALAPPDATA $id))){
            $full=[IO.Path]::GetFullPath($path)
            if($full -ne [IO.Path]::GetFullPath($temp) -and (Split-Path $full -Leaf) -ne $id){throw 'Unsafe isolated cleanup'}
            if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
        }
    }
    }catch{
        if($failure){Write-Warning ('Isolated installation cleanup also failed: '+$_.Exception.Message) -WarningAction Continue}else{throw}
    }
}
