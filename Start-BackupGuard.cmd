@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -File "%~dp0Start-BackupGuard.ps1" %*
if errorlevel 1 (
    echo.
    echo Offline Backup Guard could not start or ended with an error.
    echo Review the message above and your organization's approved script policy.
    pause
    exit /b 1
)
endlocal
exit /b 0
