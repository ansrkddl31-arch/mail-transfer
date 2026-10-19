#requires -Version 5.1
# Processes exactly one external request (key or mail) in its own process and reports progress as JSON,
# so the shared loopback UI stays responsive while Edge/biometric and the screen send run (10s-minutes).
param([Parameter(Mandatory=$true)][string]$RequestPath,[Parameter(Mandatory=$true)][string]$StateDirectory,[Parameter(Mandatory=$true)][string]$Inbox,[Parameter(Mandatory=$true)][string]$Configuration,[Parameter(Mandatory=$true)][string]$StatusFile,[int]$ControllerPid=0,[long]$ControllerStart=0)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
. (Join-Path $root 'OperationTrace.ps1')
$traceRequestId=[IO.Path]::GetFileNameWithoutExtension($RequestPath) -replace '^MailTransfer-Request-',''
if($traceRequestId-cmatch'^[a-f0-9]{32}$'){Initialize-OperationTrace $StateDirectory $traceRequestId}
Set-OperationStep 'WORKER_IMPORT' 45
. (Join-Path $root 'Common.ps1')
$workerStateDirectory=$StateDirectory;$workerInbox=$Inbox
. (Join-Path $root 'Start-External.ps1') -LibraryOnly
$StateDirectory=$workerStateDirectory;$Inbox=$workerInbox
$script:workerAiInfo=$null;$script:workerCollectionStatus='not-started';$script:workerCollectedCount=0;$script:workerCollectionError='';$script:workerCollectionDetails=@{};$script:workerFailedCount=0;$script:workerCollectionFailures=@();$script:workerResultPath='';$script:workerSendStatus='not-started'
function Write-WorkerStatus { param([string]$Phase,[string]$Status,[string]$Code='') try{ Write-BridgeJson $StatusFile @{aiInfo=$script:workerAiInfo;phase=$Phase;status=$Status;code=$Code;collectionStatus=$script:workerCollectionStatus;collectedCount=$script:workerCollectedCount;failedCount=$script:workerFailedCount;collectionFailures=$script:workerCollectionFailures;collectionError=$script:workerCollectionError;collectionDetails=$script:workerCollectionDetails;resultFile=$script:workerResultPath;sendStatus=$script:workerSendStatus;inputLocked=$(if(('MailTransfer.InputGuard'-as[type])){[MailTransfer.InputGuard]::Locked}else{$false});operationPhase=$(if(('MailTransfer.InputGuard'-as[type])){[MailTransfer.InputGuard]::Phase}else{''});at=[DateTime]::UtcNow.ToString('o')} }catch{} }
try{
 Set-OperationStep 'REQUEST_READ' 15
 $packet=Read-BridgeJson $RequestPath
 if(-not(Test-BridgeId ([string]$packet.requestId))){throw 'REQUEST_ID_INVALID'}
 Set-OperationStep 'GUARD_START' 15
 Start-MailInputGuard ([string]$packet.requestId) -Phase '요청 준비' -ControllerPid $ControllerPid -ControllerStart $ControllerStart
 Write-WorkerStatus 'working' '내부 요청을 처리합니다.'
 $packet=Read-BridgeJson $RequestPath
 $id=[string]$packet.requestId
 if(-not (Test-BridgeId $id)){throw 'REQUEST_ID_INVALID'}
 $outbox=Join-Path $StateDirectory 'outbox';[void][IO.Directory]::CreateDirectory($outbox)
 $resultPath=Join-Path $outbox ('MailTransfer-Result-'+$id+'.txt');$script:workerResultPath=$resultPath
 if(Test-Path -LiteralPath $resultPath){$result=Read-BridgeJson $resultPath}
 else{
  Set-OperationStep 'KEY_PREPARE' 30
  $key=if($packet.kind-eq'attachment-request'){$null}else{Get-ExternalBridgeKey $StateDirectory}
  try{
   if($packet.kind -eq 'key-request'){
    $result=@{schemaVersion=4;kind='public-key';release='bridge-v18.2';capabilities=@('ai-web-v1');requestId=$id;createdAt=[DateTime]::UtcNow.ToString('o');publicXml=$key.ToXmlString($false)}
   }elseif($packet.kind -eq 'attachment-request'){
    $result=Read-ExternalAttachmentRequest $packet $StateDirectory
   }elseif($packet.kind-eq'chat-request'){
    Write-WorkerStatus 'chatting' '선택한 AI 웹을 처리합니다. 로그인 요청은 외부 전용 Edge에서 진행하세요.'
    $result=Read-ExternalChatRequest $packet $StateDirectory $key
   }elseif($packet.kind -eq 'mail-request'){
    Write-WorkerStatus 'authenticating' '외부 웹메일 로그인 상태를 확인합니다. 로그인 요청이면 Edge 창에서 생체 인증을 완료하세요. 인증이 끝나야 메일을 수집합니다.'
    $profile=Join-Path $StateDirectory 'EdgeProfile'
    $result=Read-ExternalMailRequest $packet $profile $key
   }else{throw 'REQUEST_KIND_INVALID'}
  }finally{if($key){$key.Dispose()}}
  if($result.kind-eq'mail-result'){
   $script:workerCollectionStatus=[string]$result.status;$script:workerCollectedCount=@($result.mails).Count
   Set-MailOperationPhase 'AI 요약 중'
   Add-MailAiAnalysis $result $StateDirectory $packet.ai
   $script:workerAiInfo=$result.aiInfo
  }
  if($result.kind-eq'mail-result'){Set-OperationStep 'ATTACHMENT_CATALOG' 60;Register-ExternalAttachments $result.mails $StateDirectory}
  Set-OperationStep 'RESULT_WRITE' 30
  Write-BridgeJson $resultPath $result
 }
 if($result.kind-eq'attachment-result'){
  $script:workerCollectionStatus=if($result.status-eq'success'){'attachment-downloaded'}else{'failed'}
  if($result.status-eq'failed'){$script:workerCollectionError=[string]$result.error.code}
 }
 if($result.kind -eq 'public-key'){$script:workerCollectionStatus='connection-only'}
 if($result.kind -eq 'mail-result'){
  $script:workerCollectionStatus=[string]$result.status;$script:workerCollectedCount=@($result.mails).Count;$script:workerCollectionFailures=@($result.failedMails|Where-Object{$null-ne$_});$script:workerFailedCount=$script:workerCollectionFailures.Count
  if($result.status -eq 'failed'){$script:workerCollectionError=[string]$result.error.code;$script:workerCollectionDetails=$result.error.details}
 }
 $summary=if($result.kind-eq'chat-result'){'AI 웹 처리 결과 생성 완료 (암호화)'}elseif($result.kind-eq'attachment-result'){if($result.status-eq'success'){'첨부파일 다운로드 완료'}else{Get-AttachmentErrorText ([string]$result.error.code)}}elseif($result.kind -eq 'public-key'){'연결 응답 파일 생성 완료'}elseif($script:workerCollectionStatus -eq 'partial'){'메일 '+$script:workerCollectedCount+'건 수집 · '+$script:workerFailedCount+'건 실패'}elseif($script:workerCollectionStatus -eq 'success'){'메일 '+$script:workerCollectedCount+'건 수집 완료'}else{'메일 수집 실패 ('+$script:workerCollectionError+')'}
 if($result.aiInfo-and$result.aiInfo.status-ne'disabled'){$summary+=' · AI 요약 '+$result.aiInfo.count+'건'+$(if($result.aiInfo.failed){' / AI 실패 '+$result.aiInfo.failed+'건'}else{''})}
 Assert-MailOperationContinue
 Set-OperationStep 'TRANSFER' 180
 Set-MailOperationPhase '자료교환 전송 중' -Locked
 $script:workerSendStatus='working'
 Write-WorkerStatus 'sending' ($summary+' · 자료교환으로 응답을 보내는 중입니다.')
 if($result.kind-eq'attachment-result'-and$result.status-eq'success'){
  $attachmentPath=Join-Path $outbox ([string]$result.file.transportName)
  Send-AttachmentBridgeOnce $attachmentPath $Configuration
 }
 if($result.kind-eq'attachment-result'){Send-AttachmentBridgeOnce $resultPath $Configuration}else{Send-BridgePacket $resultPath $Configuration -Role External}
 if($result.kind-eq'attachment-result'-and$result.status-eq'success'){
  try{
   $native=Get-Item -LiteralPath $attachmentPath
   if(-not($native.Attributes-band[IO.FileAttributes]::ReparsePoint)-and(Get-TransferBytesHash ([IO.File]::ReadAllBytes($attachmentPath)))-ceq$result.file.hash){
    [IO.File]::Delete($attachmentPath)
    foreach($suffix in @('.send.json','.send.progress.json')){$sidecar=[IO.Path]::ChangeExtension($attachmentPath,$suffix);if(Test-Path -LiteralPath $sidecar){$info=Get-Item -LiteralPath $sidecar;if(-not($info.Attributes-band[IO.FileAttributes]::ReparsePoint)){[IO.File]::Delete($sidecar)}}}
   }
  }catch{}
 }
 Set-OperationStep 'FINISH' 20
 $script:workerSendStatus='submitted'
 Add-BridgeExchangeCleanup $StateDirectory $Inbox 'External' $id $RequestPath
 Invoke-BridgeExchangeCleanup $StateDirectory $Inbox 'External'
 $status=if($result.status){[string]$result.status}else{'success'}
 Complete-OperationTrace $(if($result.status-eq'failed'){[string]$result.error.code}else{''})
 Write-WorkerStatus 'done' ($summary+' · 자료교환 전송 제출 완료') $status
}catch{
 $code=$_.Exception.Message;if($code -cnotmatch '^[A-Z][A-Z0-9_]+$'){$code=$_.Exception.GetType().Name}
 Complete-OperationTrace $code
 $script:workerSendStatus=if($code -eq 'TRANSFER_SUBMITTED_UNCONFIRMED'){'uncertain'}else{'failed'}
 $message=if(Get-Command Get-BridgeSendFailureMessage -ErrorAction SilentlyContinue){Get-BridgeSendFailureMessage $code}else{$code}
 $summary=if($script:workerCollectionStatus -eq 'partial'){'메일 '+$script:workerCollectedCount+'건 수집 · '+$script:workerFailedCount+'건 실패 · '}elseif($script:workerCollectionStatus -eq 'success'){'메일 '+$script:workerCollectedCount+'건 수집 완료 · ' }elseif($script:workerCollectionStatus -eq 'failed'){'메일 수집 실패 ('+$script:workerCollectionError+') · '}else{''}
 Write-WorkerStatus 'done' ($summary+'처리 실패: '+$message) $code
}
finally{Stop-MailInputGuard}
