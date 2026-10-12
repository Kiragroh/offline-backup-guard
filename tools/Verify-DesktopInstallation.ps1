#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z][A-Za-z0-9.-]{2,79}$')][string]$AppId = 'OfflineBackupGuard',
    [string]$Name = 'Offline Backup Guard',
    [string]$ExpectedVersion,
    [switch]$RequireRunning
)
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA ('Programs\' + $AppId)
$current = Get-Content -LiteralPath (Join-Path $root 'current.json') -Raw | ConvertFrom-Json
if ($current.AppId -ne $AppId -or $current.Name -ne $Name) { throw 'Installed identity mismatch.' }
if ($ExpectedVersion -and $current.Version -ne $ExpectedVersion) { throw 'Installed version mismatch.' }
$version = [version]::Parse($current.Version)
$directory = Join-Path $root ('versions\' + $version)
$exe = Join-Path $directory 'Desktop.exe'
$setup = Join-Path $directory 'Setup.exe'
if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $current.PayloadHash) { throw 'Installed executable hash mismatch.' }
if (-not (Test-Path -LiteralPath $setup -PathType Leaf)) { throw 'Installed uninstaller is missing.' }
$shell = New-Object -ComObject WScript.Shell
try {
    $shortcutPaths = @(
        (Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) ($Name + '.lnk')),
        (Join-Path ([Environment]::GetFolderPath('Programs')) ($Name + '\' + $Name + '.lnk'))
    )
    foreach ($path in $shortcutPaths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Shortcut is missing: $path" }
        $link = $shell.CreateShortcut($path)
        try {
            if ($link.TargetPath -ne $exe -or $link.Arguments) { throw "Shortcut target mismatch: $path" }
            if ($link.IconLocation -ne ($exe + ',0')) { throw "Shortcut icon mismatch: $path" }
        } finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link) }
    }
} finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
$run = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$startup = $run.PSObject.Properties[$AppId]
if ($startup -and $startup.Value -ne ('"' + $exe + '" --tray')) { throw 'Startup command does not match this installed application.' }
$uninstall = Get-ItemProperty -LiteralPath ('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $AppId)
if ($uninstall.DisplayVersion -ne $current.Version -or $uninstall.InstallLocation -ne $root) { throw 'Uninstall registration mismatch.' }
$processes = @(Get-CimInstance Win32_Process -Filter "Name='Desktop.exe'" | Where-Object { $_.ExecutablePath -eq $exe })
if ($RequireRunning -and $processes.Count -ne 1) { throw "Expected exactly one application host; found $($processes.Count)." }
$children = @(foreach ($process in $processes) {
    Get-CimInstance Win32_Process -Filter "ParentProcessId=$($process.ProcessId)" | Where-Object { $_.Name -eq 'powershell.exe' }
})
if ($RequireRunning -and $children.Count -ne 1) { throw "Expected exactly one editor process; found $($children.Count)." }
[pscustomobject]@{
    AppId = $AppId
    Version = $current.Version
    ExecutableHash = $current.PayloadHash
    DesktopShortcut = $shortcutPaths[0]
    StartMenuShortcut = $shortcutPaths[1]
    LoginStartup = [bool]$startup
    HostPids = @($processes.ProcessId)
    EditorPids = @($children.ProcessId)
    CheckedAt = (Get-Date).ToString('o')
}
