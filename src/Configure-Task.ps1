#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ConfigPath,
    [switch]$Install,
    [switch]$AcknowledgeIdentityAcceptancePending,
    [switch]$ReplaceExisting,
    [string]$ResultPath
)
$ErrorActionPreference = 'Stop'
$result = @{ Success = $false; Output = ''; Message = '' }
$code = 1
$resultStream = $null
try {
    if (-not $Install -or -not $AcknowledgeIdentityAcceptancePending) { throw 'Explicit -Install and -AcknowledgeIdentityAcceptancePending are required. No task changed.' }
    Import-Module (Join-Path $PSScriptRoot 'Setup.psm1') -Force
    if ($ResultPath) {
        $parent = Split-Path ([IO.Path]::GetFullPath($ResultPath)) -Parent
        if (-not (Test-Path -LiteralPath $parent -PathType Container) -or
            (Split-Path $parent -Leaf) -notmatch '^backup-guard-ui-[a-f0-9]{32}$' -or
            (Split-Path $ResultPath -Leaf) -notmatch '^result-[a-f0-9]{32}\.clixml$') { throw 'ResultPath must be a new GUI session result file.' }
        Assert-GuardNoReparseAncestor $ResultPath
        $resultStream = [IO.File]::Open($ResultPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Invoke this helper explicitly through an approved elevated Windows PowerShell session.' }
    $ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
    $loaded = Read-GuardSetupConfiguration $ConfigPath
    $config = $loaded.Config
    Test-GuardSetupConfiguration $config $loaded.Sources $ConfigPath | Out-Null
    if (-not $config.ReadyForUse) { throw 'Review and save ReadyForUse before registration.' }
    $definition = Get-GuardSetupTaskDefinition $config $ConfigPath
    if (-not (Test-Path -LiteralPath $definition.Execute -PathType Leaf)) { throw 'Configured PowerShell executable is unavailable.' }
    $runner = Join-Path $PSScriptRoot 'Run-Backup.ps1'
    $configHash = (Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256).Hash
    $sourceHash = (Get-FileHash -LiteralPath $config.SourceListPath -Algorithm SHA256).Hash
    $runnerHash = (Get-FileHash -LiteralPath $runner -Algorithm SHA256).Hash
    $result.Output = (& $definition.Execute -NoProfile -NonInteractive -File $runner -ConfigPath $ConfigPath -ValidateOnly 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'ValidateOnly failed. No task registered. Review preflight output.' }
    Import-Module ScheduledTasks -ErrorAction Stop
    $existing = @(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop | Where-Object { $_.TaskName -eq $config.TaskName })
    if ($existing.Count -and -not $ReplaceExisting) { throw 'A task with this name already exists. Explicit replacement confirmation is required.' }
    function Resolve-AccountSid([string]$Account) {
        if ($Account.StartsWith('.\')) { $Account = $env:COMPUTERNAME + $Account.Substring(1) }
        if ($Account -match '^S-1-') { return ([Security.Principal.SecurityIdentifier]$Account).Value }
        return ([Security.Principal.NTAccount]$Account).Translate([Security.Principal.SecurityIdentifier]).Value
    }
    $expectedSid = Resolve-AccountSid $config.TaskUser
    if ($expectedSid -in @('S-1-5-18','S-1-5-19','S-1-5-20')) { throw 'Use an approved named Windows account, not a built-in service identity.' }
    $credential = $null; $password = $null
    try {
        if ($config.TaskLogonType -eq 'Password') {
            if ($PSVersionTable.PSEdition -eq 'Core') { throw 'For the approved Windows credential dialog, invoke this helper with Windows PowerShell 5.1.' }
            $promptPolicy = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\PowerShell\1\ShellIds' -Name ConsolePrompting -ErrorAction SilentlyContinue
            if ($promptPolicy.ConsolePrompting -eq $true) { throw 'Windows credential dialog is disabled by local policy. Ask the administrator; no console/file credential fallback is allowed.' }
            $credential = Get-Credential -UserName $config.TaskUser -Message 'Offline Backup Guard scheduled account. Credentials go only to Windows Task Scheduler.'
            if ($null -eq $credential) { throw 'Credential dialog cancelled.' }
            if ((Resolve-AccountSid $credential.UserName) -ne $expectedSid) { throw 'Credential account does not match the configured task account. No task changed.' }
        }
        if ((Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256).Hash -ne $configHash -or
            (Get-FileHash -LiteralPath $config.SourceListPath -Algorithm SHA256).Hash -ne $sourceHash -or
            (Get-FileHash -LiteralPath $runner -Algorithm SHA256).Hash -ne $runnerHash) { throw 'Configuration, sources or runner changed after preflight. Run setup again.' }
        $action = New-ScheduledTaskAction -Execute $definition.Execute -Argument $definition.Arguments -WorkingDirectory $definition.WorkingDirectory
        $trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.Add([TimeSpan]::Parse($config.ScheduleTime)))
        $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
        $taskPrincipal = New-ScheduledTaskPrincipal -UserId $config.TaskUser -LogonType $config.TaskLogonType -RunLevel Highest
        $task = New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -Principal $taskPrincipal -Description 'Offline Backup Guard. Scheduled-identity access and separate restore acceptance are operator responsibilities.'
        $args = @{ TaskName = $config.TaskName; TaskPath = '\'; InputObject = $task; Force = [bool]$ReplaceExisting; ErrorAction = 'Stop' }
        if ($credential) {
            $password = $credential.GetNetworkCredential().Password
            $args.User = $config.TaskUser; $args.Password = $password
        }
        Register-ScheduledTask @args | Out-Null
        $result.Success = $true
        $result.Message = 'Task registered, not started. ValidateOnly passed in the elevated helper identity, NOT necessarily the scheduled identity. Unattended readiness and recoverability remain unverified.'
        if ($config.TaskLogonType -eq 'Interactive') { $result.Message += ' Interactive mode: the configured user must stay logged in at run time.' }
        $code = 0
    } finally {
        if ($args -is [hashtable]) { $args.Remove('Password') }
        $password = $null; $credential = $null
    }
} catch { $result.Message = $_.Exception.Message }
if ($resultStream) {
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes([Management.Automation.PSSerializer]::Serialize($result))
        $resultStream.Write($bytes, 0, $bytes.Length)
    } finally { $resultStream.Dispose() }
} else {
    Write-Output $result.Output
    Write-Output $result.Message
}
exit $code
