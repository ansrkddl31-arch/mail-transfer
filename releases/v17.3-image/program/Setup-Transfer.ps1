#requires -Version 5.1
param([string]$Configuration,[string]$OutputFolder,[string]$StatusFile,[string]$RequestId,[int]$ControllerPid,[long]$ControllerStart)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
try{
 Start-MailInputGuard $RequestId -Phase '자료교환 이미지 시험 준비' -ControllerPid $ControllerPid -ControllerStart $ControllerStart
 $probe=New-TransferProbe $OutputFolder $RequestId
 Write-Host '자료교환 이미지를 자동 인식해 시험 파일 1개를 전송합니다. 좌표를 지정하지 않습니다. F4로 중지할 수 있습니다.'
 $outcome=Send-ImageTransferFile $probe.path $Configuration
 if($outcome.result-ne'SUBMITTED_UI_CONFIRMED'){
  if($outcome.clicked){throw 'TRANSFER_SUBMITTED_UNCONFIRMED'}
  throw ([string]$outcome.error)
 }
 Write-BridgeJson $StatusFile @{ok=$true;status='이미지 인식 시험 전송을 마쳤습니다. 반대쪽 수신 폴더에서 시험 TXT 도착을 확인하세요.';probeId=$RequestId}
}catch{
 $code=$_.Exception.Message;if($code-cnotmatch'^[A-Z][A-Z0-9_]+$'){$code='IMAGE_TRANSFER_FAILED'}
 Write-BridgeJson $StatusFile @{ok=$false;error=$code;status=(Get-BridgeSendFailureMessage $code)}
}finally{Stop-MailInputGuard}
