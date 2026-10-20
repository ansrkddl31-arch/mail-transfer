#requires -Version 5.1
[CmdletBinding()]
param([ValidateRange(1024,65535)][int]$Port=8765,[string]$ConfigurationFile='',[string]$StateRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'MailTransferBridge'),[switch]$NoBrowser,[switch]$LibraryOnly)
$ErrorActionPreference='Stop'
# Preserve our own parameters under unique names BEFORE dot-sourcing child scripts: their param()
# blocks run in this shared scope and would overwrite $Port, $ConfigurationFile, $LibraryOnly, etc.
$bridgePort=$Port
$bridgeConfigurationFile=$ConfigurationFile
$bridgeStateRoot=$StateRoot
$bridgeNoBrowser=[bool]$NoBrowser
$bridgeLibrary=[bool]$LibraryOnly
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Setup.ps1')
# Internal role logic (state machine, request queue, mail rendering) is reused as a library.
. (Join-Path $PSScriptRoot 'Start-Internal.ps1') -LibraryOnly
. (Join-Path $PSScriptRoot 'Diagnose-MailTransfer.ps1') -LibraryOnly

function Get-DefaultInbox { param([string]$Role) if($Role -eq 'External'){'C:\FTC_downloads'}else{'D:\FTC_downloads'} }

# ---- External role: one worker process per request; UI reflects its JSON status ----
function New-ExternalBridgeState {
 return @{role='External';inbox='';stateDir='';config='';seen=@{};active=$null;status='외부 수집 대기 중입니다. 내부 PC에서 요청이 오면 자동으로 처리합니다.';phase='idle';lastResult='';lastAt=$null;transferReady=$false;configured=$true;monitorStatus='waiting';operationTrace=$null;release='bridge-v17.3';inputLocked=$false;operationPhase='';collectionStatus='not-started';collectedCount=0;failedCount=0;collectionError='';sendStage='';sendError='';browserStartupPending=$false;browserStatus='waiting';browserCode='';browserStartupProcess=$null;browserStartedAt=[DateTime]::MinValue}
}
function Start-ExternalWebmailWindow {
 param($State)
 $statusFile=Join-Path $State.stateDir 'browser-startup.json'
 Write-BridgeJson $statusFile @{status='opening';code=''}
 $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
 $arguments='-NoProfile -STA -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "{0}" -Profile "{1}" -StatusFile "{2}"' -f (Join-Path $PSScriptRoot 'Start-Webmail.ps1'),(Join-Path $State.stateDir 'EdgeProfile'),$statusFile
 $State.browserStartedAt=[DateTime]::UtcNow
 $State.browserStartupProcess=Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden -PassThru
}
function Get-ExternalPhaseText {
 param([string]$Phase,[string]$Status)
 if(-not [string]::IsNullOrWhiteSpace($Status)){return $Status}
 switch($Phase){
  'working' {'내부 요청을 처리합니다.'}
  'collecting' {'외부 웹메일 로그인·수집 중입니다.'}
  'sending' {'자료교환으로 응답을 보내는 중입니다.'}
  'done' {'처리 완료.'}
  default {'외부 수집 대기 중입니다.'}
 }
}
function Start-ExternalWorker {
 param([string]$RequestPath,[string]$StateDirectory,[string]$Inbox,[string]$Configuration,[string]$RequestId)
 $statusFile=Join-Path $StateDirectory ('worker-'+$RequestId+'.status.json')
 if(Test-Path -LiteralPath $statusFile){[IO.File]::Delete($statusFile)}
 $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
 $args='-NoProfile -STA -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "{0}" -RequestPath "{1}" -StateDirectory "{2}" -Inbox "{3}" -Configuration "{4}" -StatusFile "{5}"' -f (Join-Path $PSScriptRoot 'External-Worker.ps1'),$RequestPath,$StateDirectory,$Inbox,$Configuration,$statusFile
 $args+=(' -ControllerPid {0} -ControllerStart {1}' -f $PID,([Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks))
 $process=Start-Process -FilePath $ps -ArgumentList $args -WindowStyle Hidden -PassThru
 return @{process=$process;statusFile=$statusFile;requestId=$RequestId;startedAt=[DateTime]::UtcNow;watchdogAt=[DateTime]::MinValue}
}
function Update-ExternalBridge {
 param($State)
 if(-not (Test-Path -LiteralPath $State.inbox -PathType Container)){$State.monitorStatus='folder-missing'}
 else{try{Get-Item -LiteralPath $State.inbox -ErrorAction Stop|Out-Null;$State.monitorStatus='watching'}catch{$State.monitorStatus='folder-unreadable'}}
 if($State.browserStatus -eq 'opening' -and $null -eq $State.active){$State.status='외부 웹메일 창을 여는 중입니다. 요청 처리는 창이 준비되면 시작합니다.';return}
 if($null -ne $State.active){
  Initialize-MailInputGuard
  if([MailTransfer.InputGuard]::IsStopRequested('Local\MailTransferCancel-'+$State.active.requestId)){$State.active.stopRequested=$true}
  $trace=$null;try{$trace=Read-BridgeJson (Join-Path $State.stateDir ('worker-'+$State.active.requestId+'.trace.json'))}catch{}
  if($trace){$State.operationTrace=$trace}
  Update-ExternalOperationWatchdog $State $trace
  $status=$null;try{$status=Read-BridgeJson $State.active.statusFile}catch{}
  if($null -ne $status){
   $State.phase=[string]$status.phase;$State.status=Get-ExternalPhaseText ([string]$status.phase) ([string]$status.status)
   if($status.phase-in@('authenticating','collecting','summarizing')){$State.browserStatus='in-use';$State.browserCode=''}
   if($status.collectionStatus-in@('success','partial')){$State.browserStatus='ready';$State.browserCode=''}
   if($status.collectionStatus-eq'failed'-and$status.collectionError-match'^(LOGIN_|WEBMAIL_LOGIN_|WEBMAIL_SESSION_)'){$State.browserStatus='failed';$State.browserCode=[string]$status.collectionError}
   $State.inputLocked=[bool]$status.inputLocked;$State.operationPhase=[string]$status.operationPhase;
   $State.collectionStatus=[string]$status.collectionStatus;$State.collectedCount=[int]$status.collectedCount;$State.failedCount=[int]$status.failedCount;$State.collectionError=[string]$status.collectionError
   $progressFile=Join-Path (Join-Path $State.stateDir 'outbox') ('MailTransfer-Result-'+$State.active.requestId+'.send.progress.json')
   try{$progress=Read-BridgeJson $progressFile;$State.sendStage=[string]$progress.stage;$State.sendError=[string]$progress.error}catch{}
   if($status.sendStatus -eq 'submitted'){$State.sendStage='TRANSFER_SUBMITTED';$State.sendError=''}
   if($State.phase -eq 'sending' -and $State.sendStage){$State.status+=' · 전송 단계: '+$State.sendStage}
  }
  if($State.active.watchdogAt-ne[DateTime]::MinValue-and-not$State.active.process.HasExited){$State.status='응답 시간 초과: '+(Get-OperationStageLabel $State.active.timeoutStage)+' · 중지 중입니다.'}
  if($State.active.process.HasExited){
   if($State.operationTrace-and$State.operationTrace.state-eq'running'){
    $State.operationTrace.state='failed';$State.operationTrace.code='WORKER_EXITED_NO_RESULT';$State.operationTrace.failedStage=$State.operationTrace.stage;$State.operationTrace.deadlineAt='';$State.operationTrace.callDeadlineAt=''
    Write-BridgeJson (Join-Path $State.stateDir ('worker-'+$State.active.requestId+'.trace.json')) $State.operationTrace
   }

   if($null -ne $status -and $status.phase -eq 'done'){$State.lastResult=[string]$status.status;$State.lastAt=(Get-Date).ToString('yyyy-MM-dd HH:mm')}
   elseif($State.active.stopRequested){$State.lastResult='작업을 중지하고 입력 제한을 해제했습니다. 전송 여부를 확인한 뒤 다시 요청하세요.';$State.lastAt=(Get-Date).ToString('yyyy-MM-dd HH:mm')}
   else{$State.lastResult='처리가 끝나기 전에 작업이 종료됐습니다.';$State.lastAt=(Get-Date).ToString('yyyy-MM-dd HH:mm')}
   $State.inputLocked=$false;$State.operationPhase='';$State.seen[$State.active.requestId]=$true;$State.active=$null;$State.phase='idle';$State.status='외부 수집 대기 중입니다. 내부 PC에서 요청이 오면 자동으로 처리합니다.'
  }
  return
 }
 foreach($entry in @(Read-BridgeInbox $State.inbox)){
  $packet=$entry.Packet;$id=[string]$packet.requestId
  if($State.seen.ContainsKey($id)){continue}
  if(Test-Path -LiteralPath (Join-Path $State.stateDir ('cleanup-'+$id+'.json'))){continue}
  if($packet.kind -notin @('key-request','mail-request','attachment-request')){continue}
  $created=[DateTime]::MinValue
  if(-not [DateTime]::TryParse([string]$packet.createdAt,[ref]$created) -or [Math]::Abs(([DateTime]::UtcNow-$created.ToUniversalTime()).TotalMinutes) -gt 10){$State.seen[$id]=$true;continue}
  if(-not (Test-BridgeTransferReady $State.config)){$State.status='자료교환 이미지 모듈을 확인하지 못했습니다. 새 설치 파일을 다시 실행하세요.';break}
  $State.operationTrace=$null
  $State.active=Start-ExternalWorker $entry.File.FullName $State.stateDir $State.inbox $State.config $id
  $State.collectionStatus='not-started';$State.collectedCount=0;$State.failedCount=0;$State.collectionError='';$State.sendStage='';$State.sendError=''
  $State.phase='working';$State.status='내부 요청을 받았습니다. 처리 중입니다.'
  break
 }
}
function Get-ExternalPublicState {
 param($State)
 return @{operationTrace=$State.operationTrace;role='External';application='mail-transfer-bridge';release=$State.release;status=$State.status;phase=$State.phase;busy=($State.phase -ne 'idle');inbox=$State.inbox;configured=$State.configured;transferReady=$State.transferReady;monitorStatus=$State.monitorStatus;lastResult=$State.lastResult;lastAt=$State.lastAt;collectionStatus=$State.collectionStatus;collectedCount=$State.collectedCount;failedCount=$State.failedCount;collectionError=$State.collectionError;sendStage=$State.sendStage;sendError=$State.sendError;inputLocked=$State.inputLocked;operationPhase=$State.operationPhase;browserStatus=$State.browserStatus;browserCode=$State.browserCode;mails=@()}
}

# ---- Shared settings ----
function Save-BridgeRoleAndInbox {
 param($App,[string]$Role,[string]$Inbox)
 if($Role -notin @('Internal','External')){throw 'ROLE_INVALID'}
 $Inbox=$Inbox.Trim().Trim('"')
 if([string]::IsNullOrWhiteSpace($Inbox)){$Inbox=Get-DefaultInbox $Role}
 if($Inbox -match '^[A-Za-z]\\'){$Inbox=$Inbox.Insert(1,':')}
 if(-not [IO.Path]::IsPathRooted($Inbox) -or $Inbox.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0){throw 'RECEIVE_FOLDER_MUST_BE_ABSOLUTE'}
 if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and $Inbox -notmatch '^(?:[A-Za-z]:\\|\\\\[^\\]+\\[^\\]+)'){throw 'RECEIVE_FOLDER_MUST_BE_ABSOLUTE'}
 $full=[IO.Path]::GetFullPath($Inbox)
 try{[void][IO.Directory]::CreateDirectory($full)}catch{throw 'RECEIVE_FOLDER_ACCESS_DENIED'}
 Write-BridgeJson $App.configurationFile @{role=$Role;inbox=$full;port=$App.port;folderConfirmed=$true}
 Set-BridgeRole $App $Role $full
}
function Set-BridgeRole {
 param($App,[string]$Role,[string]$Inbox)
 $wasExternal=($App.role -eq 'External')
 $App.role=$Role
 $stateDir=Join-Path $App.stateRoot $Role
 [void][IO.Directory]::CreateDirectory($stateDir)
 if($Role -eq 'Internal'){
  $state=New-InternalBridgeState
  $state.aiPreferences=Get-MailAiPreferences $stateDir
  $state.collectionFilter=Get-MailCollectionFilter $stateDir
  $state.attachmentDataDirectory=$stateDir
  try{foreach($entry in @(Read-BridgeJson (Join-Path $stateDir 'attachment-state.json'))){if((Test-BridgeId ([string]$entry.attachmentId))-and(Test-BridgeId ([string]$entry.requestId))){if($entry.status-in@('requesting','receiving')){$entry.status='failed';$entry.error='ATTACHMENT_REQUEST_INTERRUPTED'};$state.attachments[[string]$entry.attachmentId]=$entry}}}catch{}
  $state.inbox=$Inbox;$state.configurationFile=$App.configurationFile;$state.configured=$true
  try{$saved=Read-BridgeJson $App.configurationFile;if($saved.role-eq'Internal'){$state.lastCount=Get-BridgeCountSetting $saved 100}}catch{}
  $state.transferConfiguration=Get-BridgeTransferConfiguration 'Internal'
  $state.transferReady=Test-BridgeTransferReady $state.transferConfiguration
  if(-not $state.transferReady){$state.status='자료교환 이미지 모듈을 확인하지 못했습니다. 새 설치 파일을 다시 실행하세요.'}
  $cache=Join-Path $stateDir 'last-mail-result.json'
  if(Test-Path -LiteralPath $cache){try{$cached=Read-BridgeJson $cache;$state.mails=@($cached.mails);$state.failedMails=@($cached.failedMails|Where-Object{$null-ne$_});$state.updatedAt=(Get-Item -LiteralPath $cache).LastWriteTime.ToString('yyyy-MM-dd HH:mm')}catch{}}
  $App.internal=$state;$App.external=$null;$App.stateDir=$stateDir
 }else{
  $state=New-ExternalBridgeState
  $state.browserStartupPending=$false
  $state.inbox=$Inbox;$state.stateDir=$stateDir;$state.config=Get-BridgeTransferConfiguration 'External'
  $state.transferReady=Test-BridgeTransferReady $state.config
  $App.external=$state;$App.internal=$null;$App.stateDir=$stateDir
 }
 Restore-BridgeExchangeCleanup $stateDir $Inbox $Role
}
function Reset-BridgeRole {
 param($App)
 if($null -ne $App.external -and $null -ne $App.external.active){throw 'REQUEST_ALREADY_PENDING'}
 if($null -ne $App.internal -and ($App.internal.busy -or $App.internal.sending -or $App.internal.connecting)){throw 'REQUEST_ALREADY_PENDING'}
 $App.role=$null;$App.internal=$null;$App.external=$null;$App.stateDir=''
 try{if(Test-Path -LiteralPath $App.configurationFile){[IO.File]::Delete($App.configurationFile)}}catch{}
}
function Stop-BridgeOperation {
 param($App)
 if($App.role-eq'External'-and$null-ne$App.external.active){
  $job=$App.external.active
  Initialize-MailInputGuard
  $stopped=[MailTransfer.InputGuard]::RequestStop('Local\MailTransferCancel-'+$job.requestId)
  if(-not$stopped-and-not$job.process.HasExited){
   $job.process.Kill()
   Write-BridgeJson $job.statusFile @{phase='done';status='작업 시작 전에 중지했습니다.';code='USER_ABORTED';collectionStatus='not-started';collectedCount=0;failedCount=0;collectionError='';sendStatus='cancelled';inputLocked=$false}
  }
  $App.external.status='중지를 요청했습니다. 입력 제한을 해제합니다.'
 }elseif($App.role-eq'Internal'){
  $state=$App.internal
  if($null-ne$state.activeSend){
   Initialize-MailInputGuard
   $job=$state.activeSend.job
   $stopped=[MailTransfer.InputGuard]::RequestStop($job.guardName)
   if(-not$stopped-and-not$job.process.HasExited){$job.process.Kill();Write-BridgeJson $job.resultFile @{result='CANCELLED';clicked=$false;error='USER_ABORTED';stage='STOPPED'}}
  }else{
   foreach($a in @($state.attachments.Values)){if($a.status-in@('requesting','receiving')){$a.status='failed';$a.error='USER_ABORTED'}}
   if($state.attachmentDataDirectory){Save-InternalAttachments $state $state.attachmentDataDirectory}
   $state.sendQueue.Clear();$state.busy=$false;$state.connecting=$false;$state.pendingId=$null;$state.keyRequestId=$null
   $state.status='이 PC의 응답 대기를 취소했습니다. 외부 PC 작업의 중지는 외부 PC에서 F4를 누르세요.'
  }
 }
}
function Get-BridgePublicState {
 param($App)
 if($App.role -eq 'Internal'){$s=Get-InternalPublicState $App.internal;$s.role='Internal';$s.calendar=Get-BridgeCalendar $App.stateDir;return (Get-BridgeSetupPublicState $App $s)}
 if($App.role -eq 'External'){$s=Get-ExternalPublicState $App.external;$s.aiSettings=Get-MailAiPublicConfig $App.stateDir;return (Get-BridgeSetupPublicState $App $s)}
 return @{role=$null;application='mail-transfer-bridge';operationTrace=$null;release='bridge-v17.3';status='이 PC의 역할을 선택하세요.';mails=@()}
}

# ---- HTTP (loopback only), reusing Write-BridgeHttpReply from Start-Internal ----
function Handle-BridgeRequest {
 param($Client,$App,[string]$Page,[string]$Token,[int]$ListenPort)
 $stream=$Client.GetStream();$stream.ReadTimeout=1000;$stream.WriteTimeout=3000
 $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$false,4096,$true)
 try{
  $line=$reader.ReadLine();if($null -eq $line -or $line.Length -gt 2048){return}
  $parts=$line.Split(' ');if($parts.Length -ne 3){return}
  $method=$parts[0];$path=$parts[1];$headers=@{};$total=0
  while($true){$line=$reader.ReadLine();if($null -eq $line){return};$total+=$line.Length;if($total -gt 16384){return};if($line -eq ''){break};$colon=$line.IndexOf(':');if($colon -lt 1){return};$name=$line.Substring(0,$colon).ToLowerInvariant();if($headers.ContainsKey($name)){return};$headers[$name]=$line.Substring($colon+1).Trim()}
  if($headers['host'] -notin @("127.0.0.1:$ListenPort","localhost:$ListenPort")){Write-BridgeHttpReply $stream 403 'text/plain; charset=utf-8' '요청을 허용하지 않습니다.';return}
  if($method -eq 'GET' -and $path -eq '/'){Write-BridgeHttpReply $stream 200 'text/html; charset=utf-8' $Page;return}
  if($method -eq 'GET' -and $path -eq '/api/state'){Write-BridgeHttpReply $stream 200 'application/json; charset=utf-8' ((Get-BridgePublicState $App)|ConvertTo-Json -Depth 100 -Compress);return}
  if($method -eq 'POST' -and $path -in @('/api/request','/api/settings','/api/role','/api/diagnostics','/api/stop','/api/attachment','/api/attachment-file','/api/setup','/api/count','/api/ai/settings','/api/ai/preferences','/api/calendar','/api/collection','/api/connection-reset')){
   if($headers['x-mail-transfer-token'] -cne $Token -or $headers['origin'] -notin @("http://127.0.0.1:$ListenPort","http://localhost:$ListenPort") -or $headers['content-type'] -notmatch '^application/json(?:;|$)' -or $headers.ContainsKey('transfer-encoding')){Write-BridgeHttpReply $stream 403 'application/json' '{"error":"REQUEST_NOT_ALLOWED"}';return}
   $length=0;if(-not [int]::TryParse($headers['content-length'],[ref]$length) -or $length -lt 2 -or $length -gt 65536){Write-BridgeHttpReply $stream 400 'application/json' '{"error":"REQUEST_SIZE_INVALID"}';return}
   $builder=New-Object Text.StringBuilder;$bodyBytes=0
   while($bodyBytes -lt $length){$value=$reader.Read();if($value -lt 0){throw 'HTTP_BODY_INCOMPLETE'};[void]$builder.Append([char]$value);$bodyBytes=[Text.Encoding]::UTF8.GetByteCount($builder.ToString())}
   if($bodyBytes -ne $length){throw 'HTTP_BODY_INVALID'}
   try{
    $bodyData=$builder.ToString()|ConvertFrom-Json
    if($App.setupJob-and-not$App.setupJob.process.HasExited-and$path-eq'/api/settings'){throw 'SETUP_TEST_RUNNING'}
    if($App.setupActive-and$path-in@('/api/request','/api/attachment','/api/role','/api/calendar','/api/ai/settings')){throw 'SETUP_IN_PROGRESS'}
    if($path-eq'/api/setup'){
     switch([string]$bodyData.action){'enter'{Enter-BridgeSetup $App};'heartbeat'{if($App.setupActive){$App.setupTouched=[DateTime]::UtcNow}};'test'{Start-BridgeSetupTest $App};'exit'{Exit-BridgeSetup $App};default{throw 'SETUP_ACTION_INVALID'}}
     Write-BridgeHttpReply $stream 200 'application/json' '{"ok":true}'
    }
    elseif($path -eq '/api/diagnostics'){
     $diagnostic=Get-MailTransferDiagnostics $PSScriptRoot $ListenPort $App.stateRoot -StateSnapshot (Get-BridgePublicState $App)
     Write-BridgeHttpReply $stream 200 'application/json' (@{text=$diagnostic}|ConvertTo-Json -Compress)
    }
    elseif($path-eq'/api/connection-reset'){
     if($bodyData.reconnect-isnot[bool]){throw 'RESET_REQUEST_INVALID'}
     Start-InternalConnectionReset $App ([string]$bodyData.operationId) ([bool]$bodyData.reconnect)
     Write-BridgeHttpReply $stream 200 'application/json' '{"ok":true}'
    }
    elseif($path-eq'/api/collection'){
     if($App.role-ne'Internal'){throw 'ROLE_NOT_INTERNAL'}
     if($App.setupActive){throw 'SETUP_IN_PROGRESS'}
     Save-MailCollectionFilter $App.stateDir $App.internal $bodyData
     Write-BridgeHttpReply $stream 200 'application/json' '{"ok":true}'
    }
    elseif($path-eq'/api/ai/preferences'){
     if($App.role-ne'Internal'){throw 'ROLE_NOT_INTERNAL'}
     if($App.setupActive){throw 'SETUP_IN_PROGRESS'}
     Save-MailAiPreferences $App.stateDir $App.internal $bodyData
     Write-BridgeHttpReply $stream 200 'application/json' '{"ok":true}'
    }
    elseif($path-eq'/api/ai/settings'){
     if($App.role-ne'External'){throw 'ROLE_NOT_EXTERNAL'}
     if($null-ne$App.external.active){throw 'REQUEST_ALREADY_PENDING'}
     Save-MailAiConfig $App.stateDir $bodyData
     Write-BridgeHttpReply $stream 200 'application/json' '{"ok":true}'
    }
    elseif($path-eq'/api/calendar'){
     if($App.role-ne'Internal'){throw 'ROLE_NOT_INTERNAL'}
     Save-BridgeCalendarAction $App.stateDir $App.internal $bodyData
     Write-BridgeHttpReply $stream 200 'application/json' '{"ok":true}'
    }
    elseif($path -eq '/api/role'){
     if([string]$bodyData.role -eq 'reset'){Reset-BridgeRole $App;Write-BridgeHttpReply $stream 200 'application/json' '{"ok":true}'}
     else{Save-BridgeRoleAndInbox $App ([string]$bodyData.role) ([string]$bodyData.inbox);Write-BridgeHttpReply $stream 200 'application/json' '{"ok":true}'}
    }
    elseif($path-eq'/api/attachment'){
     if($App.role-ne'Internal'){throw 'ROLE_NOT_INTERNAL'}
     Submit-InternalAttachmentRequest $App.internal ([string]$bodyData.attachmentId) $App.stateDir
     Write-BridgeHttpReply $stream 200 'application/json' '{"ok":true}'
    }
    elseif($path-eq'/api/attachment-file'){
     if($App.role-ne'Internal'){throw 'ROLE_NOT_INTERNAL'}
     [byte[]]$attachmentBytes=Get-InternalAttachmentBytes $App.internal ([string]$bodyData.requestId) $App.stateDir
     $downloadName=Get-InternalAttachmentDownloadName $App.internal ([string]$bodyData.requestId)
     $disposition=Get-AttachmentContentDisposition $downloadName
     $head=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/octet-stream`r`nContent-Disposition: $disposition`r`nX-Content-Type-Options: nosniff`r`nCache-Control: no-store`r`nContent-Length: $($attachmentBytes.Length)`r`nConnection: close`r`n`r`n")
     $stream.Write($head,0,$head.Length);$stream.Write($attachmentBytes,0,$attachmentBytes.Length)
    }
    elseif($path -eq '/api/stop'){Stop-BridgeOperation $App;Write-BridgeHttpReply $stream 200 'application/json' '{"ok":true}'}
    elseif($path-eq'/api/count'){
     if($App.role-ne'Internal'){throw 'ROLE_NOT_INTERNAL'}
     Save-InternalBridgeCount $App.internal (Get-BridgeCountSetting $bodyData $App.internal.lastCount) $ListenPort
     Write-BridgeHttpReply $stream 200 'application/json' '{"ok":true}'
    }
    elseif($path -eq '/api/settings'){
     if($App.role -eq 'Internal'){Save-InternalBridgeSettings $App.internal ([string]$bodyData.inbox) $ListenPort (Get-BridgeCountSetting $bodyData $App.internal.lastCount)}
     elseif($App.role -eq 'External'){Save-BridgeRoleAndInbox $App 'External' ([string]$bodyData.inbox)}
     else{throw 'ROLE_NOT_SELECTED'}
     Write-BridgeHttpReply $stream 200 'application/json' '{"ok":true}'
    }
    else{ # /api/request
     if($App.role -ne 'Internal'){throw 'ROLE_NOT_INTERNAL'}
     $reqCount=Get-BridgeCountSetting $bodyData $App.internal.lastCount
     Submit-InternalBridgeRequest $App.internal ([string]$bodyData.action) ([string]$bodyData.userName) ([string]$bodyData.password) $App.stateDir '' $reqCount
     Write-BridgeHttpReply $stream 200 'application/json' '{"ok":true}'
    }
   }catch{
    $code='REQUEST_FAILED';if($_.Exception.Message -cmatch '^[A-Z][A-Z0-9_]+$'){$code=$_.Exception.Message}
    Write-BridgeHttpReply $stream 400 'application/json' (@{error=$code}|ConvertTo-Json -Compress)
   }finally{$bodyData=$null;$builder.Clear()|Out-Null}
   return
  }
  Write-BridgeHttpReply $stream 404 'text/plain' 'Not found'
 }finally{$reader.Dispose();$Client.Dispose()}
}
if($bridgeLibrary){return}
. (Join-Path $PSScriptRoot 'KeepAwake.ps1')
$awake=$null
try{
$awake=Start-MailKeepAwake
if([string]::IsNullOrEmpty($bridgeConfigurationFile)){$bridgeConfigurationFile=Join-Path $PSScriptRoot 'bridge-settings.json'}
[void][IO.Directory]::CreateDirectory($bridgeStateRoot)
$app=@{role=$null;internal=$null;external=$null;configurationFile=$bridgeConfigurationFile;stateRoot=$bridgeStateRoot;stateDir='';port=$bridgePort}
if(Test-Path -LiteralPath $bridgeConfigurationFile){
 try{$cfg=Read-BridgeJson $bridgeConfigurationFile;if($cfg.role -in @('Internal','External') -and $cfg.folderConfirmed -eq $true){Set-BridgeRole $app ([string]$cfg.role) ([string]$cfg.inbox)}}catch{}
}
$token=[Convert]::ToBase64String((Get-BridgeRandom 32))
$page=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'app.html')).Replace('__TOKEN__',$token).Replace('__MAIL_RENDERER__',(Get-MailFormatScript))
$listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,$bridgePort)
$listener.Start()
$url="http://127.0.0.1:$bridgePort/";Write-Host ('외부메일 화면: '+$url)
if(-not $bridgeNoBrowser -and $app.role -ne 'External' -and [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){Start-Process $url}
$clients=New-Object Collections.ArrayList
$lastPoll=[DateTime]::MinValue
try{
 while($true){
  while($listener.Pending() -and $clients.Count -lt 16){[void]$clients.Add(@{client=$listener.AcceptTcpClient();accepted=[DateTime]::UtcNow})}
  foreach($entry in @($clients.ToArray())){
   $client=$entry.client
   if($client.Available -gt 0){try{Handle-BridgeRequest $client $app $page $token $bridgePort}catch{$client.Dispose()};[void]$clients.Remove($entry)}
   elseif(([DateTime]::UtcNow-$entry.accepted).TotalSeconds -gt 3){$client.Dispose();[void]$clients.Remove($entry)}
  }
  Update-BridgeSetup $app
  if($app.setupActive){Start-Sleep -Milliseconds 50;continue}
  if($null -ne $app.internal){Update-InternalBridgeSends $app.internal}
  if(([DateTime]::UtcNow-$lastPoll).TotalSeconds -ge 1){
   $lastPoll=[DateTime]::UtcNow
   if($app.role -eq 'External'){Invoke-BridgeExchangeCleanup $app.stateDir $app.external.inbox 'External'}
   elseif($app.role -eq 'Internal' -and -not $app.internal.sending -and $null -eq $app.internal.activeSend){Invoke-BridgeExchangeCleanup $app.stateDir $app.internal.inbox 'Internal'}
   if($null -ne $app.internal){
    Update-InternalBridgeInbox $app.internal $app.internal.inbox $app.stateDir
    # Connection tests start only from an explicit user request; startup and reset never auto retry.
   }
   if($null -ne $app.external){Update-ExternalBridge $app.external}
  }
  Start-Sleep -Milliseconds 50
 }
}finally{foreach($entry in @($clients.ToArray())){$entry.client.Dispose()};$listener.Stop();Close-MailCdpSessions}
}finally{Stop-MailKeepAwake $awake}
