param([string]$ProgramPath,[string]$QaRoot,[int]$QaPort)
$ErrorActionPreference='Stop'
. (Join-Path $ProgramPath 'Start-Bridge.ps1') -LibraryOnly
$state=New-InternalBridgeState;$state.inbox=$QaRoot;$state.attachmentDataDirectory=$QaRoot;$state.transferReady=$false;$state.configured=$true;$state.configurationFile=Join-Path $QaRoot 'bridge-settings.json'
$app=@{role='Internal';internal=$state;external=$null;stateDir=$QaRoot;stateRoot=$QaRoot;port=$QaPort;configurationFile=$state.configurationFile;setupActive=$false;setupJob=$null;setupResult=$null}
# Only the Windows native calibration process is simulated. The page, HTTP handler and setup lease are real.
function Start-BridgeSetupTest {param($App) if(-not$App.setupActive){throw 'SETUP_NOT_ACTIVE'};[IO.File]::WriteAllText((Join-Path $App.stateDir 'native-calibration-requested'),'yes');$App.setupResult=@{status='QA: native process launch simulated';running=$false}}
$page=[IO.File]::ReadAllText((Join-Path $ProgramPath 'app.html')).Replace('__TOKEN__','packaged-test-token').Replace('__MAIL_RENDERER__',(Get-MailFormatScript))
$listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,$QaPort)
try{$listener.Start();[Console]::WriteLine('READY');[Console]::Out.Flush();while(-not(Test-Path (Join-Path $QaRoot 'stop'))){if($listener.Pending()){Handle-BridgeRequest ($listener.AcceptTcpClient()) $app $page 'packaged-test-token' $QaPort}else{Start-Sleep -Milliseconds 10}}}finally{$listener.Stop()}
