@echo off
setlocal
set "EXMAIL_INSTALL_MODE=Install"
if /i "%~1"=="/startup" set "EXMAIL_INSTALL_MODE=Startup"
if /i "%~1"=="/launch" set "EXMAIL_INSTALL_MODE=Launch"
rem A copy inside shell:startup always runs as a recovery launcher, without a pause.
if /i "%~nx0"=="EXMail-Recover.bat" if "%~1"=="" set "EXMAIL_INSTALL_MODE=Startup"
set "EXMAIL_INSTALLER_FILE=%~f0"
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy RemoteSigned -Command "$ErrorActionPreference='Stop';try{$raw=[IO.File]::ReadAllText($env:EXMAIL_INSTALLER_FILE);$m=[regex]::Match($raw,'(?m)^::EXMAIL_SCRIPT:([A-Za-z0-9+/=]+)\r?$');if(-not $m.Success){throw 'Installer script missing'};& ([ScriptBlock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($m.Groups[1].Value))))}catch{Write-Host $_.Exception.Message -ForegroundColor Red;exit 1}"
set "EXMAIL_INSTALL_EXIT=%ERRORLEVEL%"
if "%EXMAIL_INSTALL_MODE%"=="Install" if not "%EXMAIL_INSTALL_EXIT%"=="0" pause
exit /b %EXMAIL_INSTALL_EXIT%
