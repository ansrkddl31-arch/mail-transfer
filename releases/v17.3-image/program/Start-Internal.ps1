#requires -Version 5.1
[CmdletBinding()]
param([ValidateRange(1024,65535)][int]$Port=8765,[string]$Inbox='D:\FTC_downloads',[string]$StateDirectory=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'MailTransferBridge\Internal'),[string]$TransferSettings='',[string]$ConfigurationFile='', [switch]$LibraryOnly)
. (Join-Path $PSScriptRoot 'Common.ps1')
$bridgeLibraryMode=$LibraryOnly
. (Join-Path $PSScriptRoot 'Collector.ps1') -LibraryOnly
$LibraryOnly=$bridgeLibraryMode
function New-InternalBridgeState {
 return @{connectionResetPending=$false;connectionResetAt=[DateTime]::MinValue;connectionResetId='';connectionResetReconnect=$false;collectionFilter=(Get-DefaultMailCollectionFilter);activeFilter=(Get-DefaultMailCollectionFilter);aiPreferences=(Get-DefaultMailAiPreferences);publicXml=$null;keyRequestId=$null;lastKeyAt=[DateTime]::MinValue;pendingId=$null;pendingAt=[DateTime]::MinValue;status='외부 연결을 눌러 연결 테스트를 시작하세요.';busy=$false;loginNeeded=$false;loginError='';sessionReady=$false;mails=@();failedMails=@();seen=@{};inbox='';configurationFile='';configured=$true;transferReady=$true;updatedAt=$null;connecting=$false;connectionAttempted=$false;monitorStatus='waiting';release='internal-v17.3';activeCount=100;attachments=@{};attachmentDataDirectory='';transferConfiguration='';sendQueue=(New-Object 'System.Collections.Generic.Queue[object]');activeSend=$null;sending=$false;lastCount=100}
}
function Add-InternalBridgeSend {
 # Queue a written request file for the screen sender; never drive the mouse from the HTTP thread.
 param($State,[string]$Path,[string]$Action,[string]$RequestId)
 $State.sendQueue.Enqueue(@{path=$Path;action=$Action;requestId=$RequestId})
}
function Update-InternalBridgeSends {
 param($State)
 if($State.connectionResetPending){Update-InternalConnectionReset $State;return}
 if($null -ne $State.activeSend){
  $outcome=Complete-BridgePacketSend $State.activeSend.job
  if($null -eq $outcome){return} # still sending
  $job=$State.activeSend;$State.activeSend=$null;$State.sending=$false
  if($outcome.result -eq 'SUBMITTED_UI_CONFIRMED'){
   # Start the external-response clock only once the file has actually been submitted.
   if($job.action -eq 'connect'){$State.lastKeyAt=[DateTime]::UtcNow;$State.status='외부 PC의 연결 응답을 기다립니다. 최대 60초 후 결과를 표시합니다.'}
   elseif($job.action-eq'attachment'){$State.pendingAt=[DateTime]::UtcNow;$State.status='외부에서 첨부파일을 다운로드하고 전송하는 중입니다.'}
   else{$State.pendingAt=[DateTime]::UtcNow;$State.status='외부 PC에서 메일을 가져오는 중입니다. 로그인 요청은 외부 PC에서 생체 인증을 완료하세요.'}
   return
  }
  # A send failed. Roll back the waiting state so the user can retry, and never resend automatically.
  $code=[string]$outcome.error;if([string]::IsNullOrWhiteSpace($code)){$code='TRANSFER_FAILED'}
  if($outcome.clicked-and$code-ne'USER_ABORTED'){$code='TRANSFER_SUBMITTED_UNCONFIRMED'}
  if($job.action -eq 'connect'){$State.connecting=$false;$State.keyRequestId=$null}
  else{$State.busy=$false;$State.pendingId=$null}
  if($job.action-eq'attachment'){foreach($a in @($State.attachments.Values)){if($a.requestId-ceq$job.requestId){$a.status='failed';$a.error=$code}};Save-InternalAttachments $State $State.attachmentDataDirectory}
  $State.status=Get-BridgeSendFailureMessage $code
  return
 }
 if($State.sendQueue.Count -eq 0){return}
 $next=$State.sendQueue.Dequeue()
 $State.activeSend=@{job=(Start-BridgePacketSend $next.path $State.transferConfiguration);action=$next.action;requestId=$next.requestId}
 $State.sending=$true
}
function Submit-InternalBridgeRequest {
 param($State,[string]$Action,[string]$UserName,[string]$Password,[string]$DataDirectory,[string]$Settings,[int]$Count=100)
 if($Action -notin @('connect','login','refresh','resume')){throw 'REQUEST_ACTION_INVALID'}
 if($State.connectionResetPending-or$State.busy -or $State.connecting -or $State.sending){throw 'REQUEST_ALREADY_PENDING'}
 if(-not $State.configured){throw 'RECEIVE_FOLDER_NOT_CONFIRMED'}
 if(-not $State.transferReady){throw 'BACKGROUND_TRANSFER_NOT_CONFIGURED'}
 if($Count -lt 1){$Count=1}elseif($Count -gt 1000){$Count=1000}
 $State.lastCount=$Count;$State.activeCount=$Count
 $id=[Guid]::NewGuid().ToString('N')
 $packet=@{schemaVersion=4;kind='mail-request';requestId=$id;createdAt=[DateTime]::UtcNow.ToString('o');count=$Count}
 if($Action-ne'connect'){$packet.ai=ConvertTo-MailAiPreferences $State.aiPreferences;$packet.collection=ConvertTo-MailCollectionFilter $State.collectionFilter;$State.activeFilter=$packet.collection}
 if($Action -eq 'connect'){$packet.kind='key-request'}
 elseif($Action -eq 'login'){
  if([string]::IsNullOrEmpty($State.publicXml)){throw 'EXTERNAL_KEY_NOT_READY'}
  $packet.sealedCredential=Protect-BridgeCredential $State.publicXml $UserName $Password $id
 }
 $path=Join-Path (Join-Path $DataDirectory 'outbox') ('MailTransfer-Request-'+$id+'.txt')
 Write-BridgeJson $path $packet
 $Password=$null
 # The screen send runs in a background process, picked up by Update-InternalBridgeSends.
 Add-InternalBridgeSend $State $path $Action $id
 if($Action -eq 'connect'){$State.keyRequestId=$id;$State.lastKeyAt=[DateTime]::UtcNow;$State.connecting=$true;$State.connectionAttempted=$true;$State.status='자료교환으로 연결 요청을 보내는 중입니다. 자동 전송이 끝나면 외부 응답을 기다립니다.'}
 else{$State.pendingId=$id;$State.pendingAt=[DateTime]::UtcNow;$State.busy=$true;$State.loginNeeded=$false;$State.loginError='';$State.status='자료교환으로 요청을 보내는 중입니다. 외부 PC에서 생체 인증을 완료하세요.'}
}
function Update-InternalBridgeInbox {
 param($State,[string]$Folder,[string]$DataDirectory)
 if($State.connectionResetPending){return}
 if(-not (Test-Path -LiteralPath $Folder -PathType Container)){$State.monitorStatus='folder-missing'}
 else{
  try{Get-Item -LiteralPath $Folder -ErrorAction Stop|Out-Null;$State.monitorStatus='watching'}catch{$State.monitorStatus='folder-unreadable'}
 }
 foreach($entry in @(Read-BridgeInbox $Folder)){
  $packet=$entry.Packet;$id=[string]$packet.requestId
  if($State.seen.ContainsKey($entry.File.FullName)){continue}
  if($packet.kind -eq 'public-key' -and $id -ceq $State.keyRequestId){
   try{
    if($packet.publicXml -match '<(?:D|P|Q|DP|DQ|InverseQ)>'){throw 'PUBLIC_KEY_REQUIRED'}
    $rsa=New-BridgeKey
    try{$rsa.FromXmlString([string]$packet.publicXml);if($rsa.KeySize -lt 2048){throw 'PUBLIC_KEY_TOO_SMALL'}}finally{$rsa.Dispose()}
    $State.publicXml=[string]$packet.publicXml;Add-BridgeExchangeCleanup $DataDirectory $Folder 'Internal' $id $entry.File.FullName;$State.status='외부 연결 준비가 됐습니다. 메일 가져오기를 누르세요.'
   }catch{$State.status='외부 연결 키를 확인하지 못했습니다. 연결 확인을 다시 누르세요.'}
   $State.connecting=$false;$State.keyRequestId=$null
   $State.seen[$entry.File.FullName]=$true
  }
  elseif($packet.kind-eq'attachment-result'-and$id-ceq$State.pendingId){
   $jobs=@($State.attachments.Values|Where-Object{$_.requestId-ceq$id-and$_.attachmentId-ceq$packet.attachmentId})
   if($jobs.Count-ne1){continue};$job=$jobs[0]
   if($packet.status-eq'success'){$job.file=$packet.file;$job.status='receiving';$State.status='첨부파일의 내부 수신을 확인하는 중입니다.'}
   elseif($packet.status-eq'failed'){$job.status='failed';$job.error=[string]$packet.error.code;$State.busy=$false;$State.status=Get-AttachmentErrorText $job.error;if(Test-BridgeLoginRequiredCode $job.error){$State.loginNeeded=$true;$State.sessionReady=$false;$State.loginError=Get-MailFailureMessage $job.error}}else{continue}
   Save-InternalAttachments $State $DataDirectory
   $State.seen[$entry.File.FullName]=$true;Add-BridgeExchangeCleanup $DataDirectory $Folder 'Internal' $id $entry.File.FullName
  }
  elseif($packet.kind -eq 'mail-result' -and $id -ceq $State.pendingId){
   if($packet.status -in @('success','partial') -and (@($packet.mails).Count -ge 1-or($packet.status-eq'success'-and$packet.emptyRange-eq$true)) -and @($packet.mails).Count -le 1000){
    $valid=$true
    foreach($mail in @($packet.mails)){if($mail.subject -isnot [string] -or $mail.body -isnot [string]){$valid=$false}}
    if(-not $valid){continue}
    $State.failedMails=@($packet.failedMails|Where-Object{$null-ne$_});$State.mails=@($packet.mails);$State.updatedAt=[DateTime]::Now.ToString('yyyy-MM-dd HH:mm');$State.status=('메일 {0}건을 가져왔습니다.' -f $State.mails.Count);$State.loginNeeded=$false
    if($packet.status -eq 'partial'){$State.status=('메일 {0}건을 가져왔습니다. {1}건은 가져오지 못했습니다.' -f $State.mails.Count,$State.failedMails.Count)}
    if($packet.status -eq 'partial'){$State.loginNeeded=@($State.failedMails|Where-Object{(Test-BridgeLoginRequiredCode ([string]$_.code))}).Count-gt0}
    if($packet.emptyRange-eq$true){$State.status='선택한 기간에 해당하는 메일이 없습니다.'}
    elseif($packet.dateLimitReached-eq$true){$State.status+=' 기간 내 최대 수집 개수에 도달했습니다. 필요하면 개수를 늘리세요.'}
    $State.sessionReady=-not$State.loginNeeded;$State.loginError='';if($State.loginNeeded){$authFailure=@($State.failedMails|Where-Object{Test-BridgeLoginRequiredCode ([string]$_.code)})[0];$State.loginError=Get-MailFailureMessage ([string]$authFailure.code)}
    Write-BridgeJson (Join-Path $DataDirectory 'last-mail-result.json') $packet
   }elseif($packet.status -eq 'failed'){
    $State.failedMails=@($packet.failedMails|Where-Object{$null-ne$_});$State.status=[string]$packet.error.message
    $State.loginNeeded=Test-BridgeLoginRequiredCode ([string]$packet.error.code)
    if($State.loginNeeded){$State.sessionReady=$false;$State.loginError=Get-MailFailureMessage ([string]$packet.error.code)}elseif($packet.authenticated-eq$true){$State.sessionReady=$true}
   }else{continue}
   Add-BridgeExchangeCleanup $DataDirectory $Folder 'Internal' $id $entry.File.FullName
   $State.busy=$false;$State.seen[$entry.File.FullName]=$true
  }
 }
 Update-InternalAttachments $State $Folder $DataDirectory
 if($State.connecting -and ([DateTime]::UtcNow-$State.lastKeyAt).TotalSeconds -ge 60){$State.connecting=$false;$State.keyRequestId=$null;$State.status='외부 PC의 연결 응답이 60초 안에 도착하지 않았습니다. 자료교환 전송과 양쪽 실행 상태를 확인하세요.'}
 if($State.busy -and ([DateTime]::UtcNow-$State.pendingAt).TotalMinutes -gt $(if($State.activeCount -gt 20){12}else{6})){$State.busy=$false;$State.status='응답 대기 시간이 초과되었습니다. 자료교환 수신과 외부 PC 실행 상태를 확인하세요.'}
}
function Get-InternalPublicState {
 param($State)
 return @{connectionResetPending=[bool]$State.connectionResetPending;connectionAttempted=[bool]$State.connectionAttempted;collectionFilter=$State.collectionFilter;activeFilter=$State.activeFilter;aiPreferences=$State.aiPreferences;attachmentJobs=@(foreach($a in @($State.attachments.Values)){@{attachmentId=$a.attachmentId;requestId=$a.requestId;name=$a.name;status=$a.status;error=$a.error}});requestId=$State.pendingId;status=$State.status;busy=($State.busy -or $State.sending -or $State.connectionResetPending);loginNeeded=$State.loginNeeded;loginError=$State.loginError;sessionReady=$State.sessionReady;keyReady=(-not [string]::IsNullOrEmpty($State.publicXml));sending=$State.sending;inputLocked=$State.sending;mails=@($State.mails);failedMails=@($State.failedMails);application='mail-transfer-internal';inbox=$State.inbox;configured=$State.configured;transferReady=$State.transferReady;updatedAt=$State.updatedAt;connecting=($State.connecting -or $State.sending);monitorStatus=$State.monitorStatus;release=$State.release;lastCount=$State.lastCount;activeCount=$State.activeCount}
}
# Reset is local and asynchronous: stop only this app's sender before touching its queue.
function Start-InternalConnectionReset {
 param($App,[string]$OperationId,[bool]$Reconnect)
 if($App.role-ne'Internal'){throw 'ROLE_NOT_INTERNAL'}
 if($App.setupActive){throw 'SETUP_IN_PROGRESS'}
 if(-not(Test-BridgeId $OperationId)){throw 'RESET_ID_INVALID'}
 $state=$App.internal
 if($state.connectionResetId-ceq$OperationId){return}
 if($state.connectionResetPending){throw 'CONNECTION_RESET_IN_PROGRESS'}
 $state.connectionResetPending=$true;$state.connectionResetId=$OperationId;$state.connectionResetAt=[DateTime]::UtcNow;$state.connectionResetReconnect=$Reconnect
 # Invalidate replies immediately, so a response arriving while the sender stops is ignored.
 $state.pendingId=$null;$state.keyRequestId=$null;$state.publicXml=$null;$state.loginNeeded=$false;$state.loginError='';$state.sessionReady=$false
 $state.sendQueue.Clear();$state.connectionAttempted=$true
 $state.status='연결 초기화 중입니다. 이 PC의 전송을 중지하고 있습니다.'
 if($null-ne$state.activeSend){
  try{Stop-BridgeOperation $App}catch{$state.status='연결 초기화 중입니다. 전송 프로세스 종료를 기다립니다.'}
 }
 Update-InternalConnectionReset $state
}
function Update-InternalConnectionReset {
 param($State)
 if(-not$State.connectionResetPending){return}
 $uncertain=$false
 if($null-ne$State.activeSend){
  $job=$State.activeSend.job
  if(-not$job.process.HasExited-and([DateTime]::UtcNow-$State.connectionResetAt).TotalSeconds-ge3){try{$job.process.Kill()}catch{}}
  if(-not$job.process.HasExited){return}
  # The stopped sender may already have clicked Send. Never infer that the old request was not sent.
  $State.activeSend=$null;$uncertain=$true
 }
 foreach($a in @($State.attachments.Values)){if($a.status-in@('requesting','receiving')){$a.status='failed';$a.error='CONNECTION_RESET'}}
 try{if($State.attachmentDataDirectory){Save-InternalAttachments $State $State.attachmentDataDirectory}}catch{$State.status='연결은 초기화했지만 첨부 대기 상태를 저장하지 못했습니다.'}
 $State.busy=$false;$State.sending=$false;$State.connecting=$false;$State.pendingAt=[DateTime]::MinValue;$State.lastKeyAt=[DateTime]::MinValue
 $reconnect=$State.connectionResetReconnect;$State.connectionResetReconnect=$false;$State.connectionResetPending=$false
 $State.status='연결을 초기화했습니다. 저장된 메일·일정·설정은 유지했습니다.'
 if($uncertain){$State.status+=' 이전 전송 여부를 확인한 뒤 외부 연결을 다시 누르세요. 자동 재전송하지 않습니다.';return}
 if($reconnect){
  if(-not$State.configured-or-not$State.transferReady){$State.status+=' 수신 폴더와 보내기 초기 설정을 확인한 뒤 외부 연결을 누르세요.';return}
  try{Submit-InternalBridgeRequest $State 'connect' '' '' $State.attachmentDataDirectory '' $State.lastCount}catch{$State.status='초기화했지만 연결 테스트를 시작하지 못했습니다. 설정을 확인한 뒤 다시 연결하세요.'}
 }
}
function Get-BridgeRequestedCount {
 param($Value,[int]$Default=100)
 if($null-eq$Value){return $Default}
 $parsed=0
 if(-not[int]::TryParse([string]$Value,[ref]$parsed)-or$parsed-lt1-or$parsed-gt1000){throw 'MAIL_COUNT_INVALID'}
 return $parsed
}
function Get-BridgeCountSetting {
 param($Object,[int]$Default=100)
 # Missing JSON count must not resolve to PowerShell's intrinsic .Count property.
 if($null-eq$Object){return $Default}
 if($Object-is[Collections.IDictionary]){
  if(-not$Object.Contains('count')){return $Default}
  return (Get-BridgeRequestedCount $Object['count'] $Default)
 }
 $property=$Object.PSObject.Properties['count']
 if($null-eq$property){return $Default}
 return (Get-BridgeRequestedCount $property.Value $Default)
}
function Save-InternalBridgeSettings {
 param($State,[string]$Folder,[int]$ListenPort,[int]$Count=0)
 if($State.busy){throw 'REQUEST_ALREADY_PENDING'}
 if($Count-eq0){$Count=[int]$State.lastCount}
 if($Count-lt1-or$Count-gt1000){throw 'MAIL_COUNT_INVALID'}
 $Folder=$Folder.Trim().Trim('"')
 # Accept the user's common shorthand D\FTC_downloads; display and persist the normalized path.
 if($Folder -match '^[A-Za-z]\\'){$Folder=$Folder.Insert(1,':')}
 if([string]::IsNullOrWhiteSpace($Folder) -or -not [IO.Path]::IsPathRooted($Folder) -or $Folder.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0){throw 'RECEIVE_FOLDER_MUST_BE_ABSOLUTE'}
 if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and $Folder -notmatch '^(?:[A-Za-z]:\\|\\\\[^\\]+\\[^\\]+)'){throw 'RECEIVE_FOLDER_MUST_BE_ABSOLUTE'}
 $full=[IO.Path]::GetFullPath($Folder)
 try{[void][IO.Directory]::CreateDirectory($full)}catch{throw 'RECEIVE_FOLDER_ACCESS_DENIED'}
 if([string]::IsNullOrEmpty($State.configurationFile)){throw 'SETTINGS_FILE_NOT_CONFIGURED'}
 $pathChanged=-not[string]::Equals([string]$State.inbox,$full,[StringComparison]::OrdinalIgnoreCase)
 try{Write-BridgeJson $State.configurationFile @{role='Internal';inbox=$full;port=$ListenPort;count=$Count;folderConfirmed=$true}}catch{throw 'SETTINGS_SAVE_FAILED'}
 $State.inbox=$full;$State.configured=$true;$State.lastCount=$Count
 if($pathChanged){$State.publicXml=$null;$State.keyRequestId=$null;$State.connecting=$false;$State.connectionAttempted=$false}
 $State.monitorStatus='watching'
 if(-not $State.transferReady){$State.status='수신 폴더를 저장했습니다. 자료교환 연결 준비가 필요합니다.'}
 else{$State.status=('설정을 저장했습니다. 다시 불러오기는 {0}건을 요청합니다.' -f $Count)}
}
function Save-InternalBridgeCount {
 param($State,[int]$Count,[int]$ListenPort)
 if($Count-lt1-or$Count-gt1000){throw 'MAIL_COUNT_INVALID'}
 if([string]::IsNullOrEmpty($State.configurationFile)){throw 'SETTINGS_FILE_NOT_CONFIGURED'}
 try{$saved=Read-BridgeJson $State.configurationFile}catch{$saved=[pscustomobject]@{role='Internal';inbox=$State.inbox;port=$ListenPort;folderConfirmed=[bool]$State.configured}}
 $saved|Add-Member -NotePropertyName count -NotePropertyValue $Count -Force
 try{Write-BridgeJson $State.configurationFile $saved}catch{throw 'SETTINGS_SAVE_FAILED'}
 # This is the next request's default. Do not change activeCount, pendingAt, keys or queues.
 $State.lastCount=$Count
}
function Write-BridgeHttpReply {
 param($Stream,[int]$Status,[string]$ContentType,[string]$Body)
 $bytes=[Text.Encoding]::UTF8.GetBytes($Body)
 $reason=@{200='OK';204='No Content';400='Bad Request';403='Forbidden';404='Not Found';405='Method Not Allowed'}[$Status]
 $header="HTTP/1.1 $Status $reason`r`nContent-Type: $ContentType`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`nCache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`nContent-Security-Policy: default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'none'; frame-src 'self' about:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`r`n`r`n"
 $raw=[Text.Encoding]::ASCII.GetBytes($header);$Stream.Write($raw,0,$raw.Length);$Stream.Write($bytes,0,$bytes.Length)
}
function Handle-BridgeHttpClient {
 param($Client,$State,[string]$Page,[string]$Token,[int]$ListenPort,[string]$DataDirectory,[string]$Settings)
 $stream=$Client.GetStream();$stream.ReadTimeout=1000;$stream.WriteTimeout=3000
 $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$false,4096,$true)
 try{
  $line=$reader.ReadLine();if($null -eq $line -or $line.Length -gt 2048){return}
  $parts=$line.Split(' ');if($parts.Length -ne 3){return}
  $method=$parts[0];$path=$parts[1];$headers=@{};$total=0
  while($true){$line=$reader.ReadLine();if($null -eq $line){return};$total+=$line.Length;if($total -gt 16384){return};if($line -eq ''){break};$colon=$line.IndexOf(':');if($colon -lt 1){return};$name=$line.Substring(0,$colon).ToLowerInvariant();if($headers.ContainsKey($name)){return};$headers[$name]=$line.Substring($colon+1).Trim()}
  if($headers['host'] -notin @("127.0.0.1:$ListenPort","localhost:$ListenPort")){Write-BridgeHttpReply $stream 403 'text/plain; charset=utf-8' '요청을 허용하지 않습니다.';return}
  if($method -eq 'GET' -and $path -eq '/'){Write-BridgeHttpReply $stream 200 'text/html; charset=utf-8' $Page;return}
  if($method -eq 'GET' -and $path -eq '/api/state'){Write-BridgeHttpReply $stream 200 'application/json; charset=utf-8' ((Get-InternalPublicState $State)|ConvertTo-Json -Depth 100 -Compress);return}
  if($method -eq 'POST' -and $path -in @('/api/request','/api/settings')){
   if($headers['x-mail-transfer-token'] -cne $Token -or $headers['origin'] -notin @("http://127.0.0.1:$ListenPort","http://localhost:$ListenPort") -or $headers['content-type'] -notmatch '^application/json(?:;|$)' -or $headers.ContainsKey('transfer-encoding')){Write-BridgeHttpReply $stream 403 'application/json' '{"error":"REQUEST_NOT_ALLOWED"}';return}
   $length=0;if(-not [int]::TryParse($headers['content-length'],[ref]$length) -or $length -lt 2 -or $length -gt 65536){Write-BridgeHttpReply $stream 400 'application/json' '{"error":"REQUEST_SIZE_INVALID"}';return}
   # Content-Length counts UTF-8 bytes; read the body through the same buffered
   # reader without assuming Korean credentials have one byte per character.
   $builder=New-Object Text.StringBuilder;$bodyBytes=0
   while($bodyBytes -lt $length){$value=$reader.Read();if($value -lt 0){throw 'HTTP_BODY_INCOMPLETE'};[void]$builder.Append([char]$value);$bodyBytes=[Text.Encoding]::UTF8.GetByteCount($builder.ToString())}
   if($bodyBytes -ne $length){throw 'HTTP_BODY_INVALID'}
   try{
    $bodyData=$builder.ToString()|ConvertFrom-Json
    if($path -eq '/api/settings'){Save-InternalBridgeSettings $State ([string]$bodyData.inbox) $ListenPort (Get-BridgeCountSetting $bodyData $State.lastCount)}
    else{Submit-InternalBridgeRequest $State ([string]$bodyData.action) ([string]$bodyData.userName) ([string]$bodyData.password) $DataDirectory $Settings}
    Write-BridgeHttpReply $stream 200 'application/json' '{"ok":true}'
   }catch{
    $code='REQUEST_FAILED';if($_.Exception.Message -cmatch '^[A-Z][A-Z0-9_]+$'){$code=$_.Exception.Message}
    if($path -eq '/api/request'){$State.status='요청 전송을 완료하지 못했습니다. 자료교환 연결 상태를 확인하세요.'}
    if($code -eq 'BACKGROUND_TRANSFER_NOT_CONFIGURED'){$State.status='자료교환의 백그라운드 전송 연동을 설정해야 합니다.'}
    Write-BridgeHttpReply $stream 400 'application/json' (@{error=$code}|ConvertTo-Json -Compress)
   }finally{$bodyData=$null;$builder.Clear()|Out-Null}
   return
  }
  Write-BridgeHttpReply $stream 404 'text/plain' 'Not found'
 }finally{$reader.Dispose();$Client.Dispose()}
}
if($LibraryOnly){return}
. (Join-Path $PSScriptRoot 'KeepAwake.ps1')
$awake=$null
try{
$awake=Start-MailKeepAwake
[void][IO.Directory]::CreateDirectory($StateDirectory)
$state=New-InternalBridgeState
$state.inbox=$Inbox;$state.configurationFile=$ConfigurationFile
# The screen-automation adapter is ready only when this PC has saved button positions from the
# integration test (batch-v2+). Internal PC uses the Internal calibration profile.
$state.transferConfiguration=Get-BridgeTransferConfiguration 'Internal'
$state.transferReady=Test-BridgeTransferReady $state.transferConfiguration
if(-not $state.transferReady){$state.status='자료교환 버튼 위치 설정이 없습니다. 설정에서 버튼 위치 설정·테스트 전송을 진행하세요.'}
if(-not [string]::IsNullOrEmpty($ConfigurationFile)){
 try{$configuration=Read-BridgeJson $ConfigurationFile;$state.configured=($configuration.folderConfirmed -eq $true);$state.lastCount=Get-BridgeCountSetting $configuration 100}catch{$state.configured=$false}
}
$cache=Join-Path $StateDirectory 'last-mail-result.json'
if(Test-Path -LiteralPath $cache){try{$cached=Read-BridgeJson $cache;$state.mails=@($cached.mails);$state.failedMails=@($cached.failedMails|Where-Object{$null-ne$_});$state.updatedAt=(Get-Item -LiteralPath $cache).LastWriteTime.ToString('yyyy-MM-dd HH:mm')}catch{}}
$token=[Convert]::ToBase64String((Get-BridgeRandom 32))
$page=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Internal.html')).Replace('__TOKEN__',$token).Replace('__MAIL_RENDERER__',(Get-MailFormatScript))
$listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,$Port)
$listener.Start()
$url="http://127.0.0.1:$Port/";Write-Host ('내부 메일 화면: '+$url)
if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){Start-Process $url}
$clients=New-Object Collections.ArrayList
$lastInboxPoll=[DateTime]::MinValue
try{
 while($true){
  # Browsers may open idle TCP connections. Do not block folder monitoring
  # or other HTTP requests waiting for a request line on those connections.
  while($listener.Pending() -and $clients.Count -lt 16){
   [void]$clients.Add(@{client=$listener.AcceptTcpClient();accepted=[DateTime]::UtcNow})
  }
  foreach($entry in @($clients.ToArray())){
   $client=$entry.client
   if($client.Available -gt 0){
    try{Handle-BridgeHttpClient $client $state $page $token $Port $StateDirectory $TransferSettings}catch{$client.Dispose()}
    [void]$clients.Remove($entry)
   }elseif(([DateTime]::UtcNow-$entry.accepted).TotalSeconds -gt 3){$client.Dispose();[void]$clients.Remove($entry)}
  }
  Update-InternalBridgeSends $state
  if(([DateTime]::UtcNow-$lastInboxPoll).TotalSeconds -ge 1){
   $lastInboxPoll=[DateTime]::UtcNow
   Update-InternalBridgeInbox $state $state.inbox $StateDirectory
  }
  # Legacy entry point also requires an explicit connection request.
  Start-Sleep -Milliseconds 50
 }
}finally{foreach($entry in @($clients.ToArray())){$entry.client.Dispose()};$listener.Stop();Close-MailCdpSessions}

}finally{Stop-MailKeepAwake $awake}
