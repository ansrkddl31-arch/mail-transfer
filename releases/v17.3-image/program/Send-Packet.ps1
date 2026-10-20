#requires -Version 5.1
# Sends one bridge TXT through the calibrated i-oneNet screen and writes the outcome as JSON.
# Started by Start-BridgePacketSend in its own hidden process; always leaves a result file.
param([string]$Path,[string]$Configuration,[string]$ResultFile,[int]$MaxBytes=67108864,[switch]$ExternalRole,[string]$GuardName="",[int]$GuardOwnerPid=0,[long]$GuardOwnerStart=0,[int]$ControllerPid=0,[long]$ControllerStart=0)
$ErrorActionPreference='Stop'
$sendRoot=$PSScriptRoot
. (Join-Path $sendRoot 'Common.ps1')
$outcome=$null
try{
try{
 if($GuardName){Initialize-MailInputGuard;[MailTransfer.InputGuard]::Attach($GuardName,$GuardOwnerPid,$GuardOwnerStart)}
 else{$match=[regex]::Match([IO.Path]::GetFileName($Path),'^MailTransfer-(?:(?:Request|Result|Probe)-([a-f0-9]{32})\.txt|Attachment-([a-f0-9]{32})(?:\.[^\\/:*?"<>|\x00-\x1f]{1,20})?)$');if(-not$match.Success){throw 'TRANSFER_FILENAME_INVALID'};Start-MailInputGuard $(if($match.Groups[1].Success){$match.Groups[1].Value}else{$match.Groups[2].Value}) -Locked -Phase '자료교환 전송 중' -ControllerPid $ControllerPid -ControllerStart $ControllerStart}
 Assert-MailOperationContinue
 $script:ExternalSenderProgressFile=[IO.Path]::ChangeExtension($ResultFile,'.progress.json')
 function Write-ExternalTransferProgress {param([string]$Stage,[string]$ErrorCode='',[string]$Result='WORKING') try{Write-BridgeJson $script:ExternalSenderProgressFile @{stage=$Stage;error=$ErrorCode;result=$Result;at=[DateTime]::UtcNow.ToString('o')}}catch{}}
 $outcome=Send-ImageTransferFile $Path $Configuration -MaxBytes $MaxBytes
 try{$reportFolder=Join-Path $sendRoot 'logs';[void](Save-TransferReport $outcome.report $reportFolder 'MailTransfer-Send')}catch{}
 $result=@{result=$outcome.result;clicked=[bool]$outcome.clicked;error=$outcome.error;stage=$outcome.stage;name=$outcome.name;hash=$outcome.hash}
}catch{
 $code='SEND_PROCESS_FAILED';if($_.Exception.Message -cmatch '^[A-Z][A-Z0-9_]+$'){$code=$_.Exception.Message}
 $result=@{result='FAILED';clicked=$false;error=$code;stage='SEND_PROCESS'}
}
if(('MailTransfer.InputGuard'-as[type])-and[MailTransfer.InputGuard]::Cancelled){$result.error='USER_ABORTED';$result.stage='STOPPED';$result.result=if($result.clicked){'SUBMITTED_UI_UNCONFIRMED'}else{'CANCELLED'}}
if(Get-Command Write-ExternalTransferProgress -ErrorAction SilentlyContinue){Write-ExternalTransferProgress $result.stage $result.error $result.result}
Write-BridgeJson $ResultFile $result
}finally{Stop-MailInputGuard}
