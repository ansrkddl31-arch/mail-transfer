@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -Command "Get-ChildItem -LiteralPath . -File | Where-Object { $_.Extension -in '.ps1','.cs' } | Unblock-File"
powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File "%~dp0Test-ImageSend.ps1"
pause
endlocal
