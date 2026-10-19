# Guided settings lease pauses automatic request dispatch while this browser edits settings.
function Enter-BridgeSetup {
 param($App)
 if(-not$App.setupActive){
  $s=Get-BridgePublicState $App
  if($s.busy-or$s.connecting){throw 'REQUEST_ALREADY_PENDING'}
  $App.setupActive=$true;$App.setupJob=$null;$App.setupResult=$null
 }
 $App.setupTouched=[DateTime]::UtcNow
}
function Exit-BridgeSetup {
 param($App)
 if($App.setupJob-and-not$App.setupJob.process.HasExited){throw 'SETUP_TEST_RUNNING'}
 $App.setupActive=$false
}
function Start-BridgeSetupTest {
 param($App)
 if(-not$App.setupActive-or$App.role-notin@('Internal','External')){throw 'SETUP_NOT_ACTIVE'}
 if($App.setupJob-and-not$App.setupJob.process.HasExited){throw 'SETUP_TEST_RUNNING'}
 $id=[Guid]::NewGuid().ToString('N');$statusFile=Join-Path $App.stateDir ('setup-'+$id+'.json')
 $configuration=Get-BridgeTransferConfiguration $App.role
 $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
 $arguments='-NoProfile -STA -ExecutionPolicy RemoteSigned -File "{0}" -Configuration "{1}" -OutputFolder "{2}" -StatusFile "{3}" -RequestId {4} -ControllerPid {5} -ControllerStart {6}' -f (Join-Path $PSScriptRoot 'Setup-Transfer.ps1'),$configuration,$App.stateDir,$statusFile,$id,$PID,([Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks)
 $process=Start-Process -FilePath $ps -ArgumentList $arguments -PassThru
 $App.setupJob=@{process=$process;requestId=$id;statusFile=$statusFile};$App.setupResult=@{ok=$false;running=$true;status='설정 안내창을 확인하세요. F4로 즉시 중지할 수 있습니다.'}
}
function Update-BridgeSetup {
 param($App)
 if(-not$App.setupActive){return}
 if($App.setupJob){
  if(-not$App.setupJob.process.HasExited){return}
  try{$App.setupResult=Read-BridgeJson $App.setupJob.statusFile -MaximumBytes 16384}catch{$App.setupResult=@{ok=$false;status='설정이 중단되었습니다. 다시 시작할 수 있습니다.';error='SETUP_INTERRUPTED'}}
  if($App.role-eq'Internal'){$App.internal.transferReady=Test-BridgeTransferReady $App.internal.transferConfiguration}
  elseif($App.role-eq'External'){$App.external.transferReady=Test-BridgeTransferReady $App.external.config}
  $App.setupJob=$null;$App.setupTouched=[DateTime]::UtcNow
 }
 if(([DateTime]::UtcNow-$App.setupTouched).TotalSeconds-gt45){$App.setupActive=$false}
}
function Get-BridgeSetupPublicState {
 param($App,$State)
 $State.setupActive=[bool]$App.setupActive;$State.setupRunning=($null-ne$App.setupJob-and-not$App.setupJob.process.HasExited);$State.setupResult=$App.setupResult
 return $State
}
