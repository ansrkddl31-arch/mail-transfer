@echo off
cd /d "%~dp0"
powershell -NoProfile -Command "@('Attachments.ps1','MailAssistant.ps1','Calendar.ps1','CollectionFilter.ps1','Collector.ps1','Common.ps1','Diagnose-MailTransfer.ps1','External-Worker.ps1','InputGuard.ps1','OperationTrace.ps1','KeepAwake.ps1','Send-Packet.ps1','Setup-Transfer.ps1','Setup.ps1','Start-Bridge.ps1','Start-External.ps1','Start-Internal.ps1','Start-Webmail.ps1','Test-InputGuard.ps1','Test-Send.ps1','Transfer.External.ps1','Transfer.Helpers.ps1','Transfer.Startup.ps1','Transfer.TestCore.ps1') | ForEach-Object { $p=Join-Path (Get-Location) $_; if(Test-Path -LiteralPath $p){Unblock-File -LiteralPath $p -ErrorAction Stop} }"
if errorlevel 1 goto failed
powershell -NoProfile -STA -ExecutionPolicy RemoteSigned -File "Start-Bridge.ps1"
if errorlevel 1 goto failed
goto end
:failed
echo Program could not run. Read the message above.
:end
pause
