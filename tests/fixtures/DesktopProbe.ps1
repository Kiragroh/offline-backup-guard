param([switch]$Tray,[string]$DesktopEventName)
$ErrorActionPreference='Stop'
$event=[Threading.EventWaitHandle]::OpenExisting($DesktopEventName)
$record=@{Pid=$PID;Tray=[bool]$Tray;FocusCount=0;EventName=$DesktopEventName}
$path=Join-Path $PSScriptRoot 'probe.json'
$stop=Join-Path $PSScriptRoot 'stop-probe'
try{
    [IO.File]::WriteAllText($path,($record|ConvertTo-Json))
    while(-not (Test-Path -LiteralPath $stop)){
        if($event.WaitOne(100)){$record.FocusCount++;[IO.File]::WriteAllText($path,($record|ConvertTo-Json))}
    }
}finally{$event.Dispose()}
