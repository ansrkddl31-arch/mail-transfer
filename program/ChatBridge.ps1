#requires -Version 5.1
# Chat-only transport: both request and response payloads are encrypted. Existing mail transport is unchanged.
function Protect-ChatPayload {
 param([string]$PublicXml,$Payload,[string]$RequestId,[ValidateSet('question','answer')][string]$Purpose)
 if(-not(Test-BridgeId $RequestId)-or$PublicXml-match'<(?:D|P|Q|DP|DQ|InverseQ)>'){throw 'CHAT_ENVELOPE_INVALID'}
 $rsa=New-BridgeKey;$aes=[Security.Cryptography.Aes]::Create();$keys=Get-BridgeRandom 64
 $enc=New-Object byte[] 32;$macKey=New-Object byte[] 32
 [Array]::Copy($keys,0,$enc,0,32);[Array]::Copy($keys,32,$macKey,0,32)
 $hmac=New-Object Security.Cryptography.HMACSHA256(,$macKey)
 $plain=[Text.Encoding]::UTF8.GetBytes((@{requestId=$RequestId;purpose=$Purpose;payload=$Payload}|ConvertTo-Json -Depth 20 -Compress))
 try{
  if($plain.Length-gt12582912){throw 'CHAT_PAYLOAD_TOO_LARGE'}
  $rsa.FromXmlString($PublicXml);if($rsa.KeySize-lt2048){throw 'CHAT_ENVELOPE_INVALID'}
  $aes.Key=$enc;$aes.GenerateIV();$aes.Mode='CBC';$aes.Padding='PKCS7'
  $t=$aes.CreateEncryptor();try{$cipher=$t.TransformFinalBlock($plain,0,$plain.Length)}finally{$t.Dispose()}
  $auth=New-Object byte[] (16+$cipher.Length);[Array]::Copy($aes.IV,0,$auth,0,16);[Array]::Copy($cipher,0,$auth,16,$cipher.Length)
  return @{algorithm='RSA-OAEP-AES256-CBC-HMAC256';key=[Convert]::ToBase64String($rsa.Encrypt($keys,$true));iv=[Convert]::ToBase64String($aes.IV);ciphertext=[Convert]::ToBase64String($cipher);mac=[Convert]::ToBase64String($hmac.ComputeHash($auth))}
 }finally{foreach($b in @($plain,$keys,$enc,$macKey)){if($b){[Array]::Clear($b,0,$b.Length)}};$hmac.Dispose();$aes.Dispose();$rsa.Dispose()}
}
function Unprotect-ChatPayload {
 param($Key,$Envelope,[string]$RequestId,[ValidateSet('question','answer')][string]$Purpose)
 $keys=$null;$enc=$null;$mk=$null;$plain=$null;$aes=[Security.Cryptography.Aes]::Create();$h=$null
 try{
  if($Envelope.algorithm-cne'RSA-OAEP-AES256-CBC-HMAC256'){throw 'CHAT_ENVELOPE_INVALID'}
  $cipher=[Convert]::FromBase64String($Envelope.ciphertext);$iv=[Convert]::FromBase64String($Envelope.iv);$tag=[Convert]::FromBase64String($Envelope.mac)
  if($cipher.Length-lt16-or$cipher.Length-gt12582928-or$iv.Length-ne16-or$tag.Length-ne32){throw 'CHAT_ENVELOPE_INVALID'}
  $keys=$Key.Decrypt([Convert]::FromBase64String($Envelope.key),$true);if($keys.Length-ne64){throw 'CHAT_ENVELOPE_INVALID'}
  $enc=New-Object byte[] 32;$mk=New-Object byte[] 32;[Array]::Copy($keys,0,$enc,0,32);[Array]::Copy($keys,32,$mk,0,32)
  $h=New-Object Security.Cryptography.HMACSHA256(,$mk);$auth=New-Object byte[] (16+$cipher.Length);[Array]::Copy($iv,0,$auth,0,16);[Array]::Copy($cipher,0,$auth,16,$cipher.Length)
  $expected=$h.ComputeHash($auth);$diff=0;for($i=0;$i-lt32;$i++){$diff=$diff-bor($expected[$i]-bxor$tag[$i])};if($diff-ne0){throw 'CHAT_ENVELOPE_INVALID'}
  $aes.Key=$enc;$aes.IV=$iv;$aes.Mode='CBC';$aes.Padding='PKCS7';$t=$aes.CreateDecryptor();try{$plain=$t.TransformFinalBlock($cipher,0,$cipher.Length)}finally{$t.Dispose()}
  $data=[Text.Encoding]::UTF8.GetString($plain)|ConvertFrom-Json
  if($data.requestId-cne$RequestId-or$data.purpose-cne$Purpose){throw 'CHAT_ENVELOPE_INVALID'}
  return $data.payload
 }catch{throw 'CHAT_ENVELOPE_INVALID'}finally{foreach($b in @($plain,$keys,$enc,$mk)){if($b){[Array]::Clear($b,0,$b.Length)}};if($h){$h.Dispose()};$aes.Dispose()}
}
function Get-ChatErrorText {
 param([string]$Code)
 switch($Code){
  'CHAT_EXTERNAL_UPDATE_REQUIRED' {'외부 프로그램의 AI 웹 지원이 확인되지 않았습니다. 양쪽을 v18.2-r1로 업데이트하고 외부 연결을 다시 확인하세요.'}
  'CHAT_LOGIN_REQUIRED' {'외부 PC의 선택한 AI 전용 Edge 창에서 로그인한 뒤 이미 로그인함을 누르세요.'}
  'CHAT_MODEL_UNAVAILABLE' {'선택한 모델로 변경됐는지 확인하지 못했습니다. 외부 AI 화면에서 모델을 확인하고 로그인 상태를 다시 확인하세요.'}
  'CHAT_ATTACHMENT_UNSUPPORTED' {'현재 AI 화면의 파일 첨부 입력을 찾지 못했습니다. 이번 질문은 보내지 않았습니다.'}
  'CHAT_ATTACHMENT_TIMEOUT' {'파일 첨부 완료를 확인하지 못했습니다. 이번 질문은 보내지 않았습니다.'}
  'CHAT_CONTEXT_TOO_LARGE' {'대화가 길어졌습니다. 새 대화에서 질문하세요.'}
  'CHAT_USAGE_LIMIT' {'선택한 AI의 사용량 제한입니다. 외부 화면에 표시된 재사용 가능 시간을 확인하세요.'}
  'CHAT_CHALLENGE_REQUIRED' {'외부 PC의 AI 창에서 추가 확인을 직접 완료한 뒤 다시 질문하세요.'}
  'CHAT_RESPONSE_TIMEOUT' {'답변 완료를 확인하지 못했습니다. 외부 AI 창을 확인하세요. 질문은 자동 재전송하지 않습니다.'}
  'CHAT_SUBMIT_UNCONFIRMED' {'질문 전송 여부를 확인하지 못했습니다. 외부 AI 창을 확인한 뒤 다시 요청하세요.'}
  'CHAT_LAYOUT_UNSUPPORTED' {'AI 입력창 또는 버튼을 찾지 못했습니다. 외부 화면을 확인하세요.'}
  'CHAT_ENVELOPE_INVALID' {'AI 전달 파일의 암호화 검증에 실패했습니다. 연결을 초기화하고 다시 연결하세요.'}
  'CHAT_SERVICE_ERROR' {'AI에서 오류를 표시했습니다. 외부 화면을 확인하세요.'}
  'CHAT_CANCELLED' {'내부 대기를 취소했습니다. 이미 전달된 외부 작업은 외부 PC에서 F4로 중지하세요.'}
  default {('AI 질의 처리 실패 ('+$Code+'). 외부 PC의 AI 창과 자료교환 상태를 확인하세요.')}
 }
}
function Close-InternalChatPending {
 param($State,[string]$Code='')
 if($State.chatPending){if($State.chatPending.key){$State.chatPending.key.Dispose()};$State.chatPending=$null}
 if($Code-and$State.chat){$State.chat.stage=$Code;$State.chat.status='failed';$State.chat.error=$Code;$State.chat.message=Get-ChatErrorText $Code}
}
function Save-ChatHistory {
 param($State,[string]$Directory)
 Add-Type -AssemblyName System.Security
 $bytes=[Text.Encoding]::UTF8.GetBytes((@{threads=@($State.chatThreads)}|ConvertTo-Json -Depth 15 -Compress))
 if($bytes.Length-gt8388608){[Array]::Clear($bytes,0,$bytes.Length);throw 'CHAT_HISTORY_LIMIT'}
 try{
  $protected=[Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
  Write-BridgeJson (Join-Path $Directory 'chat-history.dpapi.json') @{version=1;ciphertext=[Convert]::ToBase64String($protected)}
 }finally{[Array]::Clear($bytes,0,$bytes.Length)}
}
function Initialize-ChatHistory {
 param($State,[string]$Directory)
 $path=Join-Path $Directory 'chat-history.dpapi.json';if(-not(Test-Path -LiteralPath $path)){return}
 $bytes=$null
 try{
  $data=Read-BridgeJson $path 16777216;Add-Type -AssemblyName System.Security
  $bytes=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($data.ciphertext),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
  $data=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json
  $threads=@($data.threads);if($threads.Count-gt50){throw 'CHAT_HISTORY_INVALID'}
  $State.chatThreads=$threads
 }catch{$State.chat.message='저장된 AI 대화 이력을 열지 못했습니다. 현재 Windows 사용자 계정을 확인하세요.'}
 finally{if($bytes){[Array]::Clear($bytes,0,$bytes.Length)}}
}
function Get-ChatPublicState {
 param($State)
 $active=@($State.chatThreads|Where-Object{$_.id-ceq$State.chatThreadId})
 return @{result=$State.chat;providers=$State.chatProviders;threadId=$State.chatThreadId;threads=@(foreach($t in @($State.chatThreads)){@{id=$t.id;provider=$t.provider;title=$t.title;updatedAt=$t.updatedAt}});messages=$(if($active.Count){@($active[0].messages)}else{@()})}
}
function Submit-ChatAction {
 param($State,$Body,[string]$Directory)
 $action=[string]$Body.action;$provider=[string]$Body.provider
 if($provider-notin@('chatgpt','claude','gemini')){throw 'CHAT_PROVIDER_INVALID'}
 if([string]$Body.operationId-and$State.chat.requestId-ceq[string]$Body.operationId){return}
 if($State.busy-or$State.connecting-or$State.sending-or$State.connectionResetPending){throw 'REQUEST_ALREADY_PENDING'}
 if($action-in@('select','delete','new')){
  if($action-eq'new'){$State.chatThreadId='';$State.chat=@{status='idle';message='AI를 선택하고 로그인 상태를 확인한 뒤 질문하세요.'};return}
  $threads=@($State.chatThreads|Where-Object{$_.id-ceq[string]$Body.threadId});if($threads.Count-ne1){throw 'CHAT_THREAD_INVALID'}
  if($action-eq'delete'){
   foreach($m in @($threads[0].messages)){foreach($f in @($m.files|Where-Object{$null-ne$_})){if(Test-BridgeId ([string]$f.requestId)){$path=Join-Path $Directory ('chat-files-'+$f.requestId+'.dpapi.json');if(Test-Path -LiteralPath $path){[IO.File]::Delete($path)}}}}
   $State.chatThreads=@($State.chatThreads|Where-Object{$_.id-cne[string]$Body.threadId});if($State.chatThreadId-ceq[string]$Body.threadId){$State.chatThreadId=''};Save-ChatHistory $State $Directory}
  else{$State.chatThreadId=[string]$threads[0].id}
  return
 }
 if($action-notin@('open','check','ask')){throw 'CHAT_ACTION_INVALID'}
 $id=[string]$Body.operationId;if(-not(Test-BridgeId $id)){throw 'CHAT_OPERATION_INVALID'}
 if($State.chat.requestId-ceq$id){return}
 if(-not$State.configured-or-not$State.transferReady){throw 'BACKGROUND_TRANSFER_NOT_CONFIGURED'}
 if(-not$State.publicXml){throw 'EXTERNAL_KEY_NOT_READY'}
 if('ai-web-v1'-notin@($State.externalCapabilities)){throw 'CHAT_EXTERNAL_UPDATE_REQUIRED'}
 $prompt=[string]$Body.prompt;$model=[string]$Body.model;$history=@();$thread=$null
 if($action-eq'ask'){
  if($State.chatProviders[$provider].ready-ne$true){throw 'CHAT_LOGIN_CHECK_REQUIRED'}
  if(-not$prompt.Trim()-or$prompt.Length-gt12000){throw 'CHAT_PROMPT_INVALID'}
  if($model-and$model-notin@($State.chatProviders[$provider].models)) {throw 'CHAT_MODEL_INVALID'}
  $threads=@($State.chatThreads|Where-Object{$_.id-ceq$State.chatThreadId-and$_.provider-ceq$provider})
  if($threads.Count){$thread=$threads[0];$history=@($thread.messages);if($history.Count-ge20){throw 'CHAT_HISTORY_LIMIT'}}
  elseif(@($State.chatThreads).Count-ge50){throw 'CHAT_THREAD_LIMIT'}
 }
 $files=@($Body.files|Where-Object{$null-ne$_});if($files.Count-gt3){throw 'CHAT_FILE_LIMIT'}
 if($action-ne'ask'-and$files.Count){throw 'CHAT_ACTION_INVALID'}
 $size=0
 foreach($f in $files){
  if(-not(Test-ChatFileName ([string]$f.name))){throw 'CHAT_FILE_INVALID'}
  try{$bytes=[Convert]::FromBase64String([string]$f.data)}catch{throw 'CHAT_FILE_INVALID'}
  if(-not$bytes.Length){throw 'CHAT_FILE_INVALID'};$size+=$bytes.Length
  if($size-gt5242880){throw 'CHAT_FILE_LIMIT'}
 }
 $key=New-BridgeKey
 try{
  $payload=@{provider=$provider;action=$action;prompt=$prompt;model=$model;history=$history;files=$files;replyPublicXml=$key.ToXmlString($false)}
  $packet=@{schemaVersion=4;kind='chat-request';requestId=$id;createdAt=[DateTime]::UtcNow.ToString('o');sealed=Protect-ChatPayload $State.publicXml $payload $id 'question'}
  $path=Join-Path (Join-Path $Directory 'outbox') ('MailTransfer-Request-'+$id+'.txt');Write-BridgeJson $path $packet
  $State.chatPending=@{key=$key;provider=$provider;action=$action;prompt=$prompt;model=$model;thread=$thread};$key=$null
  $State.chat=@{requestId=$id;provider=$provider;status='waiting';stage='QUEUED';action=$action;prompt=$prompt;answer='';error='';message=$(if($action-eq'open'){'외부 PC에서 선택한 AI의 로그인 창을 엽니다.'}elseif($action-eq'check'){'외부 AI의 로그인 상태와 모델 메뉴를 확인합니다.'}else{'외부 AI 답변을 기다립니다. 질문은 자동 재전송하지 않습니다.'})}
  $State.pendingId=$id;$State.pendingAt=[DateTime]::UtcNow;$State.busy=$true;$State.status=$State.chat.message
  Add-InternalBridgeSend $State $path 'chat' $id
 }finally{if($key){$key.Dispose()}}
}
function Receive-InternalChat {
 param($State,$Packet,[string]$Directory)
 if(-not$State.chatPending){return}
 $pending=$State.chatPending
 try{
  $value=Unprotect-ChatPayload $pending.key $Packet.sealed ([string]$Packet.requestId) 'answer'
  if($value.status-eq'success'){
   if($pending.action-eq'ask'){
    if($value.answer-isnot[string]-or-not$value.answer-or$value.answer.Length-gt100000){throw 'CHAT_ENVELOPE_INVALID'}
    $thread=$pending.thread
    if(-not$thread){$thread=[pscustomobject]@{id=[Guid]::NewGuid().ToString('N');provider=$pending.provider;title=$pending.prompt.Substring(0,[Math]::Min(40,$pending.prompt.Length));updatedAt='';messages=@()};$State.chatThreads=@($State.chatThreads)+@($thread)}
    $outputFiles=@();$fileWarning=''
    try{$outputFiles=@(Save-ChatOutputFiles $Directory ([string]$Packet.requestId) $value.files)}catch{$fileWarning=' 파일을 내부에 저장하지 못했습니다.'}
    $fileFailures=@($value.fileFailures|Where-Object{$null-ne$_})
    if($fileFailures.Count){$fileWarning+=' 생성 파일 '+$fileFailures.Count+'건 다운로드 실패. 외부 AI 화면을 확인하세요.'}
    $thread.messages=@($thread.messages)+@(@{role='user';content=$pending.prompt;model=$pending.model},@{role='assistant';content=[string]$value.answer;model=[string]$value.model;files=$outputFiles;fileWarning=$fileWarning})
    $thread.updatedAt=[DateTime]::UtcNow.ToString('o');$State.chatThreadId=$thread.id
    $State.chat.answer=[string]$value.answer;$State.chat.message='AI 답변을 받았습니다.'+$fileWarning
    try{Save-ChatHistory $State $Directory}catch{$State.chat.message+=' 이력 파일 저장에 실패해 이번 대화는 실행 중에만 유지됩니다.'}
   }else{
    $models=@($value.models|Where-Object{$_-is[string]-and$_.Length-ge1-and$_.Length-le100}|Select-Object -Unique -First 30)
    $State.chatProviders[$pending.provider]=@{ready=($value.ready-eq$true);models=$models;checkedAt=[DateTime]::UtcNow.ToString('o')}
    $State.chat.message=if($value.ready-eq$true){'로그인 상태를 확인했습니다. 모델을 선택하고 질문하세요.'}else{'외부 PC에 열린 AI 창에서 로그인한 뒤 이미 로그인함을 누르세요.'}
   }
   $State.chat.status='success';$State.chat.error=''
  }elseif($value.status-eq'failed'-and[string]$value.code-cmatch'^[A-Z][A-Z0-9_]{1,80}$'){
   $State.chat.status='failed';$State.chat.error=[string]$value.code;$State.chat.message=Get-ChatErrorText ([string]$value.code)
   if($value.code-in@('CHAT_LOGIN_REQUIRED','CHAT_CHALLENGE_REQUIRED')){$State.chatProviders[$pending.provider].ready=$false}
  }else{throw 'CHAT_ENVELOPE_INVALID'}
 }catch{$State.chat.status='failed';$State.chat.error='CHAT_ENVELOPE_INVALID';$State.chat.message=Get-ChatErrorText 'CHAT_ENVELOPE_INVALID'}
 finally{Close-InternalChatPending $State;$State.busy=$false;$State.pendingId=$null;$State.status=$State.chat.message}
}
function Read-BridgeUtf8Body {
 param([IO.TextReader]$Reader,[int]$Length)
 if(-not('EXMail.HttpBody'-as[type])){Add-Type -TypeDefinition @'
using System;using System.IO;using System.Text;
namespace EXMail {public static class HttpBody {public static string Read(TextReader r,int length){var b=new StringBuilder();int n=0;while(n<length){int c=r.Read();if(c<0)throw new IOException("HTTP_BODY_INCOMPLETE");char ch=(char)c;b.Append(ch);if(char.IsHighSurrogate(ch)){int d=r.Read();if(d<0||!char.IsLowSurrogate((char)d))throw new IOException("HTTP_BODY_INVALID");b.Append((char)d);n+=4;}else{if(char.IsLowSurrogate(ch))throw new IOException("HTTP_BODY_INVALID");n+=ch<128?1:ch<2048?2:3;}}if(n!=length)throw new IOException("HTTP_BODY_INVALID");return b.ToString();}}}
'@}
 return [EXMail.HttpBody]::Read($Reader,$Length)
}
function Save-ChatOutputFiles {
 param([string]$Directory,[string]$RequestId,$Files)
 $filesArray=@($Files|Where-Object{$null-ne$_});if(-not$filesArray.Count){return @()}
 if($filesArray.Count-gt3){throw 'CHAT_OUTPUT_FILE_INVALID'}
 $total=0;$metadata=@()
 foreach($f in $filesArray){
  if(-not(Test-BridgeId ([string]$f.id))-or$f.name-isnot[string]-or-not$f.name-or$f.name.Length-gt180-or$f.name-match'[\\/:*?"<>|\x00-\x1f]' -or $f.name-in@('.','..')){throw 'CHAT_OUTPUT_FILE_INVALID'}
  $b=[Convert]::FromBase64String([string]$f.data);$total+=$b.Length
  if(-not$b.Length-or$total-gt5242880){throw 'CHAT_OUTPUT_FILE_INVALID'}
  $metadata+=@{id=[string]$f.id;requestId=$RequestId;name=[string]$f.name;size=$b.Length}
 }
 $plain=[Text.Encoding]::UTF8.GetBytes((@{files=$filesArray}|ConvertTo-Json -Depth 8 -Compress))
 try{
  Add-Type -AssemblyName System.Security
  $cipher=[Security.Cryptography.ProtectedData]::Protect($plain,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
  Write-BridgeJson (Join-Path $Directory ('chat-files-'+$RequestId+'.dpapi.json')) @{ciphertext=[Convert]::ToBase64String($cipher)}
 }finally{[Array]::Clear($plain,0,$plain.Length)}
 return @($metadata)
}
function Get-ChatOutputFile {
 param($State,[string]$Directory,[string]$RequestId,[string]$FileId)
 if(-not(Test-BridgeId $RequestId)-or-not(Test-BridgeId $FileId)){throw 'CHAT_OUTPUT_FILE_INVALID'}
 $allowed=@(foreach($t in @($State.chatThreads)){foreach($m in @($t.messages)){foreach($f in @($m.files|Where-Object{$null-ne$_})){if($f.id-ceq$FileId-and$f.requestId-ceq$RequestId){$f}}}})
 if($allowed.Count-ne1){throw 'CHAT_OUTPUT_FILE_MISSING'}
 $plain=$null
 try{
  $path=Join-Path $Directory ('chat-files-'+$RequestId+'.dpapi.json');$packet=Read-BridgeJson $path 12582912
  Add-Type -AssemblyName System.Security
  $plain=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($packet.ciphertext),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
  $value=[Text.Encoding]::UTF8.GetString($plain)|ConvertFrom-Json;$files=@($value.files|Where-Object{$_.id-ceq$FileId})
  if($files.Count-ne1){throw 'CHAT_OUTPUT_FILE_INVALID'}
  return @{name=[string]$files[0].name;bytes=[Convert]::FromBase64String($files[0].data)}
 }finally{if($plain){[Array]::Clear($plain,0,$plain.Length)}}
}
function Test-ChatFileName {
 param([string]$Name)
 return (-not[string]::IsNullOrWhiteSpace($Name)-and$Name.Length-le180-and$Name-notmatch'[\\/:*?"<>|\x00-\x1f]'-and$Name-notin@('.','..')-and$Name-notmatch'[. ]$'-and$Name-notmatch'(?i)^(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)')
}
function Remove-StaleChatScratch {
 param([string]$Directory)
 foreach($folder in @(Get-ChildItem -LiteralPath $Directory -Directory -ErrorAction SilentlyContinue)){
  if($folder.Name-cnotmatch'^chat-(?:upload|download)-[a-f0-9]{32}$'-or($folder.Attributes-band[IO.FileAttributes]::ReparsePoint)-or$folder.LastWriteTimeUtc-gt[DateTime]::UtcNow.AddMinutes(-30)){continue}
  foreach($file in @(Get-ChildItem -LiteralPath $folder.FullName -File)){if(-not($file.Attributes-band[IO.FileAttributes]::ReparsePoint)){try{[IO.File]::Delete($file.FullName)}catch{}}}
  try{[IO.Directory]::Delete($folder.FullName,$false)}catch{}
 }
}
