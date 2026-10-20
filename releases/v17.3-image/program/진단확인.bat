@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0Diagnose-MailTransfer.ps1"
echo.
pause
