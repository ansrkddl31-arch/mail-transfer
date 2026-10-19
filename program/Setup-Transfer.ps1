#requires -Version 5.1
param([string]$Configuration,[string]$OutputFolder,[string]$StatusFile,[string]$RequestId,[int]$ControllerPid,[long]$ControllerStart)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Test-Send.ps1') -LibraryOnly
. (Join-Path $PSScriptRoot 'Transfer.External.ps1')
$script:OriginalSetupControlPoint=${function:Get-ControlPoint}
function Get-ControlPoint {
 param($Window,[string]$Instruction)
 for($attempt=1;$attempt-le3;$attempt++){
  try{return (& $script:OriginalSetupControlPoint $Window $Instruction)}catch{
   Assert-MailOperationContinue
   if($_.Exception.Message-notin@('CONTROL_POINT_OUTSIDE_WINDOW','CONTROL_POINT_OCCLUDED')-or$attempt-eq3){throw}
   Write-Host '자료교환 버튼 위의 위치가 아닙니다. 저장하지 않았습니다. 안내한 버튼 위에 다시 올려주세요.'
  }
 }
}

$outcome=$null;$mutex=$null;$owned=$false
try{
 Initialize-TransferDesktop
 Start-MailInputGuard $RequestId -Phase '자료교환 설정 준비' -ControllerPid $ControllerPid -ControllerStart $ControllerStart
 # Keep ordinary input allowed until we can identify the exact program window.
 $script:report=New-Object 'Collections.Generic.List[string]'
 $window=Ensure-TransferWindow (Get-TransferLaunchPath $Configuration)
 [MailTransfer.InputGuard]::SetScope([int[]]@($PID,[int]$window.Current.ProcessId))
 $mutex=New-Object Threading.Mutex($false,$TransferMutexName);$owned=$mutex.WaitOne(0)
 if(-not$owned){throw 'ANOTHER_TRANSFER_IS_RUNNING'}
 Write-Host '설정 전용 모드입니다. 자료교환 창과 이 안내창에서만 입력할 수 있습니다.'
 Write-Host 'F4: 즉시 제한 해제·중지. 다른 창 클릭과 창 전환 키는 막습니다.'
 Write-Host '테스트 TXT 하나를 실제로 전송합니다. 보내기 목록은 비워두세요.'
 $outcome=Invoke-TransferCalibration $Configuration $OutputFolder $RequestId
 if($outcome.result-ne'SUBMITTED_UI_CONFIRMED'){
  if($outcome.clicked){throw 'TRANSFER_SUBMITTED_UNCONFIRMED'}
  throw ([string]$outcome.error)
 }
 Write-BridgeJson $StatusFile @{ok=$true;status='버튼 설정과 테스트 전송을 마쳤습니다. 반대쪽 수신 폴더에서 테스트 TXT 도착을 확인하세요.';probeId=$RequestId}
}catch{
 $code=$_.Exception.Message;if($code-cnotmatch'^[A-Z][A-Z0-9_]+$'){$code='TRANSFER_SETUP_FAILED'}
 Write-BridgeJson $StatusFile @{ok=$false;error=$code;status=(Get-BridgeSendFailureMessage $code)}
}finally{
 Stop-MailInputGuard
 if($owned){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}
}
