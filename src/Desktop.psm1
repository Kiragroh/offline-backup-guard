#Requires -Version 5.1
function Get-GuardCloseAction([string]$Reason,[bool]$ExplicitExit,[bool]$Busy){
    if($Reason -ne 'UserClosing'){return 'Close'}
    if(-not $ExplicitExit){return 'Hide'}
    if($Busy){return 'Wait'}
    return 'Close'
}
function Get-GuardHealthIcon([string]$State){
    switch($State){
        'Succeeded'{return 'success'}
        'Running'{return 'running'}
        'Failed'{return 'error'}
        'Interrupted'{return 'error'}
        {$_ -in @('Warning','Missed','Needs attention')}{return 'warning'}
        default{return 'unknown'}
    }
}
function New-GuardDesktopSession {
    param([string]$AppId='OfflineBackupGuard',[string]$EventName)
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if($EventName){
        if($EventName -notmatch ('^Local\\[A-Za-z][A-Za-z0-9.-]{2,79}\.'+[regex]::Escape($sid)+'\.Focus$')){throw 'Invalid desktop focus identity.'}
        return [pscustomobject]@{Mutex=$null;Event=[Threading.EventWaitHandle]::OpenExisting($EventName);EventName=$EventName;FocusOnly=$false}
    }
    if($AppId -notmatch '^[A-Za-z][A-Za-z0-9.-]{2,79}$'){throw 'Invalid desktop app identity.'}
    $prefix='Local\'+$AppId+'.'+$sid
    $event=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::AutoReset,($prefix+'.Focus'))
    $mutex=New-Object Threading.Mutex($false,($prefix+'.Instance'))
    try{$owned=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
    if(-not $owned){[void]$event.Set();$mutex.Dispose();$mutex=$null}
    [pscustomobject]@{Mutex=$mutex;Event=$event;EventName=($prefix+'.Focus');FocusOnly=(-not $owned)}
}
Export-ModuleMember -Function Get-GuardCloseAction,Get-GuardHealthIcon,New-GuardDesktopSession
