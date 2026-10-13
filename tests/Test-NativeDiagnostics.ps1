$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\BackupGuard.psm1') -Force -PassThru
$log=Join-Path ([IO.Path]::GetTempPath()) ('backup-guard-diagnostic-'+[guid]::NewGuid().ToString('N')+'.log')
try{
    & $module {
        $script:calls=0
        function script:robocopy.exe {
            $script:calls++
            if($script:calls -eq 1){$global:LASTEXITCODE=11;return}
            if($args -notcontains '/L' -or @($args|Where-Object {$_ -like '/MT*'}).Count){throw 'Diagnostic must remain serial and read-only'}
            $global:LASTEXITCODE=11
            'ERROR 1392 (0x00000570) Accessing Source Directory C:\SYNTHETIC_PRIVATE\'
        }
    }
    $caught=$false
    try{Invoke-RobocopyPreview @('C:\ExampleSource','C:\ExampleTarget','/MT:8') $log | Out-Null}catch{
        $caught=$true
        if($_.Exception.Message -notmatch 'NativeErrorCodes=1392' -or $_.Exception.Message -match 'SYNTHETIC_PRIVATE'){throw 'Native preview diagnostic missing or private path leaked'}
    }
    if(-not $caught -or (& $module {$script:calls}) -ne 2){throw 'Opaque failure did not remain fatal with serial diagnostic'}
    & $module {function script:robocopy.exe {$global:LASTEXITCODE=11;'ERROR 112 (0x00000070) Copying File C:\SYNTHETIC_PRIVATE\example.bin'}}
    $caught=$false
    try{Invoke-RobocopyChecked @('C:\ExampleSource','C:\ExampleTarget') | Out-Null}catch{
        $caught=$true
        if($_.Exception.Message -notmatch 'NativeErrorCodes=112' -or $_.Exception.Message -match 'SYNTHETIC_PRIVATE'){throw 'Native copy diagnostic missing or private path leaked'}
    }
    if(-not $caught){throw 'Disk-full copy must fail'}
    Write-Output 'PASS native preview/copy diagnostics, serial read-only fallback, privacy and fatal outcomes'
}finally{
    & $module {Remove-Item Function:script:robocopy.exe -ErrorAction SilentlyContinue}
    if(Test-Path -LiteralPath $log){Remove-Item -LiteralPath $log}
}
exit 0
