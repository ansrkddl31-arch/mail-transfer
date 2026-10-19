#requires -Version 5.1
[CmdletBinding()]
param([string]$Inbox='C:\FTC_downloads',[string]$StateDirectory=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'MailTransferBridge\External'),[string]$TransferConfiguration='',[switch]$LibraryOnly)
. (Join-Path $PSScriptRoot 'Common.ps1')
$bridgeLibraryMode=$LibraryOnly
. (Join-Path $PSScriptRoot 'Collector.ps1') -LibraryOnly
$LibraryOnly=$bridgeLibraryMode
function Get-ReadyExternalWebmailTab {
 param([string]$Profile)
 $tabs=@(Get-EdgeProfilePages $Profile|Where-Object{
  $uri=$null; $_.type-eq'page'-and[Uri]::TryCreate($_.url,[UriKind]::Absolute,[ref]$uri)-and$uri.Scheme-eq'https'-and$uri.Host-eq'mail.ex.co.kr'-and$uri.AbsolutePath-in@('/login','/mail/mainframe')
 })
 foreach($tab in @($tabs|Where-Object{([Uri]$_.url).AbsolutePath-eq'/mail/mainframe'})){
  Assert-MailOperationContinue
  try{
   $ready=Invoke-EdgeCdp $tab.webSocketDebuggerUrl 'Runtime.evaluate' @{expression=(Get-MailLoginStatusExpression);returnByValue=$true}
   if($ready.result.value.ready-eq$true){return $tab}
   if([string]$ready.result.value.errorCode-in@('LOGIN_INVALID_CREDENTIALS','LOGIN_ACCOUNT_LOCKED','LOGIN_FAILED','WEBMAIL_SESSION_EXPIRED')){throw [string]$ready.result.value.errorCode}
  }catch{Assert-MailOperationContinue;throw}
 }
}
function Wait-ExternalLoginOrSession {
 param([string]$Profile,[int]$TimeoutSeconds=30)
 $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
 do{
  Assert-MailOperationContinue
  $ready=@(Get-ReadyExternalWebmailTab $Profile)
  if($ready.Count-eq1){return @{authenticated=$true;tab=$ready[0]}}
  $forms=@(Get-EdgeProfilePages $Profile|Where-Object{$uri=$null;$_.type-eq'page'-and[Uri]::TryCreate($_.url,[UriKind]::Absolute,[ref]$uri)-and$uri.Scheme-eq'https'-and$uri.Host-eq'mail.ex.co.kr'-and$uri.AbsolutePath-eq'/login'})
  if($forms.Count-gt1){throw 'EXACTLY_ONE_LOGIN_TAB_REQUIRED'}
  if($forms.Count-eq1){
   try{$state=Invoke-EdgeCdp $forms[0].webSocketDebuggerUrl 'Runtime.evaluate' @{expression='document.readyState === "complete" && !!document.querySelector("input[type=password]")';returnByValue=$true};if($state.result.value-eq$true){return @{authenticated=$false;tab=$forms[0]}}}catch{}
  }
  Start-Sleep -Milliseconds 300
 }while([DateTime]::UtcNow-lt$deadline)
 throw 'LOGIN_PAGE_NOT_READY'
}
function Read-ExternalMailRequest {
 param($Request,[string]$Profile,$Key)
 $credential=$null;$browserUsed=$false;$authConfirmed=$false;$operationStage='SESSION_CHECK'
 try {
  $filter=ConvertTo-MailCollectionFilter $Request.collection
  $count=[int]$Request.count
  if($count -lt 1 -or $count -gt 1000){throw 'MAIL_COUNT_INVALID'}
  if($null -ne $Request.sealedCredential){$credential=Unprotect-BridgeCredential $Key $Request.sealedCredential $Request.requestId}
  Set-MailOperationPhase '로그인·생체 인증 대기'
  $browserUsed=$true
  Set-OperationStep 'SESSION_CHECK' 45
  $pages=@(Get-EdgeProfilePages $Profile)
  if($pages.Count -eq 0){Set-OperationStep 'BROWSER_START' 45;Start-MailAutomationEdge $Profile}
  # Reuse a completed session even when this request carries login credentials.
  # /login may redirect back to /mail/mainframe; that is success, not a missing form.
  $tabs=@(Get-ReadyExternalWebmailTab $Profile)
  if($tabs.Count-eq1){$credential=$null}
  elseif($null-ne$credential){
   Set-OperationStep 'LOGIN_NAVIGATION' 45
   Reset-MailLoginPage $Profile
   $entry=Wait-ExternalLoginOrSession $Profile
   if($entry.authenticated){$tabs=@($entry.tab);$credential=$null}
   else{
    $tab=$entry.tab
    Set-OperationStep 'LOGIN_SUBMIT' 45
    $state=Invoke-MailLoginUntilBiometric $tab $credential
    $credential=$null
    if($state-ne'AWAITING_BIOMETRIC'){throw 'LOGIN_FAILED'}
    [void](Invoke-EdgeCdp $tab.webSocketDebuggerUrl 'Page.bringToFront' @{})
    Set-OperationStep 'BIOMETRIC_WAIT' 300
    $tabs=@(Get-LoggedInWebmailTab $Profile)
   }
  }else{throw 'LOGIN_REQUIRED'}
  Set-OperationStep 'INBOX_SELECT' 45
  $operationStage='INBOX_SELECT'
  $authConfirmed=$true
  Set-MailOperationPhase '메일 수집 중'
  if(Get-Command Write-WorkerStatus -ErrorAction SilentlyContinue){Write-WorkerStatus 'collecting' '메일을 수집합니다. 마우스·키보드 사용 가능 · F4 중지'}
  # Keep the session alive before reading: click a "시간연장"(extend session) prompt if present.
  # If we are (back) on the login page, the session is gone — ask the internal side to log in again.
  $keep=Invoke-EdgeCdp $tabs[0].webSocketDebuggerUrl 'Runtime.evaluate' @{expression=(Get-MailSessionKeepAliveExpression);returnByValue=$true}
  if($null -ne $keep.result.value -and [string]$keep.result.value.code -cmatch '^[A-Z][A-Z0-9_]+$'){throw [string]$keep.result.value.code}
  [void](Select-ReceivedInbox $tabs[0])
  $operationStage='MAIL_READ'
  $collection=Read-PagedInboxMails $tabs[0] $count $filter
  $mails=@($collection.mails);$failures=@($collection.failures)
  if($mails.Count-eq0-and$failures.Count-eq0-and$filter.mode-eq'range'){return @{schemaVersion=4;kind='mail-result';authenticated=$true;requestId=$Request.requestId;createdAt=[DateTime]::UtcNow.ToString('o');status='success';mails=@();failedMails=@();emptyRange=$true;collection=$filter;attemptedCount=0}}
  if($mails.Count -lt 1){
   $first=if($failures.Count){$failures[0].code}else{'NOT_ENOUGH_MAIL_ROWS'}
   return @{schemaVersion=4;kind='mail-result';authenticated=$authConfirmed;requestId=$Request.requestId;createdAt=[DateTime]::UtcNow.ToString('o');status='failed';mails=@();failedMails=$failures;attemptedCount=$collection.attempted;error=@{code=$first;message=(Get-MailFailureMessage $first);stage=$first;details=@{operationStage=$operationStage}}}
  }
  $status=if($failures.Count){'partial'}else{'success'}
  return @{schemaVersion=4;kind='mail-result';authenticated=$authConfirmed;requestId=$Request.requestId;createdAt=[DateTime]::UtcNow.ToString('o');status=$status;mails=$mails;failedMails=$failures;attemptedCount=$collection.attempted;collection=$filter;dateLimitReached=($collection.dateLimitReached-eq$true)}

 }catch{
  Assert-MailOperationContinue
  if($_.Exception.Message-eq'USER_ABORTED'){throw}
  $code='MAIL_COLLECTION_FAILED';if($_.Exception.Message -cmatch '^[A-Z][A-Z0-9_]+$'){$code=$_.Exception.Message}
  Record-OperationFailure $code
  $message=Get-MailFailureMessage $code
  if(-not(Test-BridgeLoginRequiredCode $code)){$label=switch($operationStage){'SESSION_CHECK'{'웹메일 연결 확인'};'INBOX_SELECT'{'받은메일함 선택'};'MAIL_READ'{'목록·본문 수집'};default{'메일 처리'}};$message+=' (실패 단계: '+$label+')'}
  if($code -eq 'LOGIN_REQUIRED'){$message='외부 웹메일 로그인이 필요합니다. 아이디와 비밀번호를 입력하세요.'}
  # The failure's stage is the error code itself; the internal UI shows it so the user sees where it stopped.
  $details=@{operationStage=$operationStage;exceptionType=$_.Exception.GetBaseException().GetType().Name}
  foreach($key in @('mailIndex','collectedBeforeFailure','headerLine','mimeDepth')){
   $value=$_.Exception.Data[$key];if($value -is [int] -and $value -ge 0 -and $value -le 10000){$details[$key]=$value}
  }
  $reason=[string]$_.Exception.Data['headerReason']
  if($reason -in @('ORPHAN_CONTINUATION','NON_ASCII_HEADER_LINE','HEADER_COLON_MISSING','INVALID_FIELD_NAME')){$details.headerReason=$reason}
  return @{schemaVersion=4;kind='mail-result';authenticated=$authConfirmed;requestId=$Request.requestId;createdAt=[DateTime]::UtcNow.ToString('o');status='failed';error=@{code=$code;message=$message;stage=$code;details=$details};mails=@()}
 }finally{
  # Keep the logged-in Edge window open so the session is reused for the next request (do NOT close it).
  # Only the short-lived CDP control sockets are released here.
  $credential=$null;Close-MailCdpSessions
 }
}
if($LibraryOnly){return}
. (Join-Path $PSScriptRoot 'KeepAwake.ps1')
$awake=$null
try{
$awake=Start-MailKeepAwake
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'WINDOWS_REQUIRED'}
if([string]::IsNullOrEmpty($TransferConfiguration)){$TransferConfiguration=Get-BridgeTransferConfiguration 'External'}
if(-not (Test-BridgeTransferReady $TransferConfiguration)){throw 'TRANSFER_CALIBRATION_REQUIRED'}
[void][IO.Directory]::CreateDirectory($StateDirectory);[void][IO.Directory]::CreateDirectory($Inbox)
$outbox=Join-Path $StateDirectory 'outbox';[void][IO.Directory]::CreateDirectory($outbox)
$profile=Join-Path $StateDirectory 'EdgeProfile';$key=Get-ExternalBridgeKey $StateDirectory
Write-Host '외부 수신 감시를 시작했습니다. 내부 요청이 오면 로그인·생체 인증 대기·메일 수집·TXT 반환을 진행합니다.'
$seen=@{};$pending=@{}
# Each request uses only the worker's dedicated EdgeProfile, closed after collection.
try{
 while($true){
  foreach($entry in @(Read-BridgeInbox $Inbox)){
   $packet=$entry.Packet;$id=[string]$packet.requestId
   if($seen.ContainsKey($id) -or $pending.ContainsKey($id)){continue}
   if($packet.kind -notin @('key-request','mail-request','chat-request')){continue}
   $created=[DateTime]::MinValue
   if(-not [DateTime]::TryParse([string]$packet.createdAt,[ref]$created) -or [Math]::Abs(([DateTime]::UtcNow-$created.ToUniversalTime()).TotalMinutes) -gt 10){$seen[$id]=$true;continue}
   $resultPath=Join-Path $outbox ('MailTransfer-Result-'+$id+'.txt')
   if(Test-Path -LiteralPath $resultPath){$result=Read-BridgeJson $resultPath}
   elseif($packet.kind-eq'chat-request'){$result=Read-ExternalChatRequest $packet $StateDirectory $key}
   elseif($packet.kind -eq 'key-request'){$result=@{schemaVersion=4;kind='public-key';release='bridge-v18.2';capabilities=@('ai-web-v1');requestId=$id;createdAt=[DateTime]::UtcNow.ToString('o');publicXml=$key.ToXmlString($false)}}
   else{
    Write-Host '메일 요청을 처리합니다. 로그인이 필요한 경우 생체 인증을 직접 완료하세요.'
    $result=Read-ExternalMailRequest $packet $profile $key
   }
   Write-BridgeJson $resultPath $result
   $pending[$id]=@{path=$resultPath;attempted=$false}
  }
  foreach($id in @($pending.Keys)){
   $job=$pending[$id]
   if($job.attempted){continue}
   $job.attempted=$true
   try{Send-BridgePacket $job.path $TransferConfiguration;$seen[$id]=$true;$pending.Remove($id);Write-Host '응답 TXT 전송을 제출했습니다.'}
   catch{
    $code=$_.Exception.Message;if($code -cnotmatch '^[A-Z][A-Z0-9_]+$'){$code=$_.Exception.GetType().Name}
    if($code -eq 'TRANSFER_SUBMITTED_UNCONFIRMED'){$seen[$id]=$true;$pending.Remove($id);Write-Host '보내기는 실행했으나 완료 확인에 실패했습니다. 재전송하지 않습니다. 내부 수신을 확인하세요.'}
    else{Write-Host ('응답 전송 중단: '+(Get-BridgeSendFailureMessage $code)+' 자료교환 창과 보내기 목록을 확인한 뒤 이 창을 닫고 외부_메일수집을 다시 실행하세요.')}
   }
  }
  Start-Sleep -Milliseconds 500
 }
}finally{$key.Dispose();Close-MailCdpSessions}

}finally{Stop-MailKeepAwake $awake}
