@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -Command "Get-ChildItem -LiteralPath . -File | Where-Object { $_.Extension -in '.ps1','.cs' } | Unblock-File"
powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File "%~dp0Test-ImageRecognition.ps1"
if errorlevel 1 pause
endlocal
