@echo off
setlocal
set "EXMAIL_INSTALLER_FILE=%~f0"
powershell.exe -NoLogo -NoProfile -Command "$ErrorActionPreference='Stop';try{$raw=[IO.File]::ReadAllText($env:EXMAIL_INSTALLER_FILE);$m=[regex]::Match($raw,'(?m)^::EXMAIL_SCRIPT:([A-Za-z0-9+/=]+)\r?$');if(-not $m.Success){throw 'Installer script missing'};& ([ScriptBlock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($m.Groups[1].Value))))}catch{Write-Host $_.Exception.Message -ForegroundColor Red;exit 1}"
set "EXMAIL_INSTALL_EXIT=%ERRORLEVEL%"
echo.
if not "%EXMAIL_INSTALL_EXIT%"=="0" echo Installation failed. Read the message above.
pause
exit /b %EXMAIL_INSTALL_EXIT%
