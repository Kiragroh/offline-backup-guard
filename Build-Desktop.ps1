#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PackageRoot,
    [string]$EntryScript='Start-BackupGuard.ps1',
    [string[]]$PackagePaths=@('src'),
    [string]$Name='Offline Backup Guard',
    [ValidatePattern('^[A-Za-z][A-Za-z0-9.-]{2,79}$')][string]$AppId='OfflineBackupGuard',
    [string]$Version,
    [switch]$AllowAdministrativeLaunch,
    [switch]$TestBuild,
    [string]$OutputDirectory
)
$ErrorActionPreference='Stop'
if($TestBuild -and ($AppId -cnotmatch '^BackupGuardTest\.[a-f0-9]{32}$' -or
    $Name -cnotmatch '^Backup Guard Test [a-f0-9]{32}$' -or
    $EntryScript -cne 'tests\fixtures\DesktopProbe.ps1')){
    throw 'TestBuild requires an isolated BackupGuardTest.<32 lowercase hex> AppId, Backup Guard Test <32 lowercase hex> name, and tests\fixtures\DesktopProbe.ps1 entry script.'
}
if(-not $PackageRoot){$PackageRoot=$PSScriptRoot}
if(-not $OutputDirectory){$OutputDirectory=Join-Path $PSScriptRoot 'dist\desktop'}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
if(-not $Version){$Version=(Get-Content -LiteralPath (Join-Path $PackageRoot 'VERSION') -Raw).Trim()}
if($Version -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$'){throw 'Version must have three or four numeric components.'}
[void][version]::Parse($Version)
if([string]::IsNullOrWhiteSpace($Name) -or $Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0){throw 'Invalid application name.'}
if(Test-Path -LiteralPath $OutputDirectory){if(@(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count){throw 'OutputDirectory must be empty; builds never overwrite artifacts.'}}
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$stage=Join-Path $OutputDirectory 'package'
[void][IO.Directory]::CreateDirectory($stage)
function Copy-PackagePath([string]$Relative){
    if([IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)' -or $Relative.Contains(':')){throw 'PackagePaths must stay within PackageRoot.'}
    $source=Join-Path $PackageRoot $Relative
    $item=Get-Item -LiteralPath $source -ErrorAction Stop
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse points are not allowed in a desktop package.'}
    if($item.PSIsContainer -and ($OutputDirectory+'\').StartsWith(($item.FullName.TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)){throw 'PackagePaths must not contain the output directory.'}
    $items=if($item.PSIsContainer){@(Get-ChildItem -LiteralPath $source -Recurse -Force)}else{@($item)}
    foreach($file in $items){
        if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse points are not allowed in a desktop package.'}
        if($file.PSIsContainer){continue}
        $relativePath=$file.FullName.Substring($PackageRoot.TrimEnd('\').Length+1)
        $destination=Join-Path $stage $relativePath
        [void][IO.Directory]::CreateDirectory((Split-Path $destination -Parent))
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
    }
}
foreach($relative in @($EntryScript)+$PackagePaths){Copy-PackagePath $relative}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'LICENSE') -Destination (Join-Path $stage 'LICENSE')
& (Join-Path $PSScriptRoot 'desktop\New-DesktopIcon.ps1') -OutputDirectory (Join-Path $stage 'assets\desktop')
$files=[ordered]@{}
foreach($file in Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object FullName){$files[$file.FullName.Substring($stage.Length+1)]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash}
$profile=[ordered]@{Name=$Name;AppId=$AppId;EntryScript=$EntryScript;Version=$Version;AllowAdministrativeLaunch=[bool]$AllowAdministrativeLaunch;Files=$files}
$brand=Join-Path $OutputDirectory 'brand.json'
[IO.File]::WriteAllText($brand,($profile|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
$metadata=Join-Path $OutputDirectory 'AssemblyInfo.cs'
$escapedName=$Name.Replace('\','\\').Replace('"','\"')
$attributes='using System.Reflection;'+"`r`n"+'[assembly: AssemblyTitle("'+$escapedName+'")]'+"`r`n"+'[assembly: AssemblyProduct("'+$escapedName+'")]'+"`r`n"+'[assembly: AssemblyVersion("'+$Version+'")]'+"`r`n"+'[assembly: AssemblyFileVersion("'+$Version+'")]'
[IO.File]::WriteAllText($metadata,$attributes,[Text.UTF8Encoding]::new($false))
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not (Test-Path $compiler)){$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'}
$common=Join-Path $PSScriptRoot 'desktop\Common.cs'
$icon=Join-Path $stage 'assets\desktop\app.ico'
$references=@('/r:System.Windows.Forms.dll','/r:System.Drawing.dll','/r:System.Web.Extensions.dll','/r:System.IO.Compression.dll','/r:System.IO.Compression.FileSystem.dll','/r:Microsoft.CSharp.dll')
$app=Join-Path $stage 'Desktop.exe'
$defines=@()
if($TestBuild){$defines=@('/define:DESKTOP_TESTS')}
& $compiler /nologo /target:winexe /optimize+ /platform:anycpu "/win32icon:$icon" "/resource:$brand,brand.json" "/out:$app" @defines @references $metadata $common (Join-Path $PSScriptRoot 'desktop\Launcher.cs')
if($LASTEXITCODE -ne 0){throw 'Native application compilation failed.'}
$zip=Join-Path $OutputDirectory 'payload.zip'
[IO.Compression.ZipFile]::CreateFromDirectory($stage,$zip)
$setup=Join-Path $OutputDirectory 'Setup.exe'
& $compiler /nologo /target:winexe /optimize+ /platform:anycpu "/win32icon:$icon" "/resource:$brand,brand.json" "/resource:$zip,payload.zip" "/out:$setup" @defines @references $metadata $common (Join-Path $PSScriptRoot 'desktop\Setup.cs')
if($LASTEXITCODE -ne 0){throw 'Native installer compilation failed.'}
foreach($file in Get-ChildItem -LiteralPath $stage -File -Recurse){
    $destination=Join-Path $OutputDirectory $file.FullName.Substring($stage.Length+1)
    [void][IO.Directory]::CreateDirectory((Split-Path $destination -Parent))
    Copy-Item -LiteralPath $file.FullName -Destination $destination
}
Get-FileHash -LiteralPath $app,$setup -Algorithm SHA256 | Select-Object Path,Hash
Write-Output 'Run Desktop.exe (keep its adjacent files) for portable use, or Setup.exe for per-user installation. Setup.exe embeds the complete payload.'
