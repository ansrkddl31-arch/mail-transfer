# Attachment requests contain opaque catalog IDs, never caller-supplied paths or URLs.
function Get-AttachmentFileName {
 param([string]$Name)
 if([string]::IsNullOrWhiteSpace($Name)-or$Name.Length-gt180-or$Name-match'[\x00-\x1f<>:"/\\|?*]' -or$Name-match'[. ]$' -or$Name-match'^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)' -or$Name-in@('.','..')){throw 'ATTACHMENT_FILENAME_INVALID'}
 return $Name
}
function Get-AttachmentExtension {
 param([string]$Name)
 $valid=Get-AttachmentFileName $Name;$extension=[IO.Path]::GetExtension($valid)
 if($extension.Length-gt20){throw 'ATTACHMENT_FILENAME_INVALID'}
 return $extension
}
function Get-AttachmentTransportName {
 param([string]$RequestId,[string]$Name)
 if(-not(Test-BridgeId $RequestId)){throw 'ATTACHMENT_ID_INVALID'}
 return ('MailTransfer-Attachment-'+$RequestId+(Get-AttachmentExtension $Name))
}
function Get-AttachmentParameter {
 param([string]$Value,[string]$Name)
 $extended=Get-MailParameter $Value ($Name+'*')
 if(-not$extended){
  $segments=New-Object Text.StringBuilder
  for($i=0;$i-lt20;$i++){$part=Get-MailParameter $Value ($Name+'*'+$i+'*');if(-not$part){break};[void]$segments.Append($part)}
  $extended=$segments.ToString()
 }
 if($extended){
  $m=[regex]::Match($extended,"^([^']*)'[^']*'(.*)$")
  if(-not$m.Success){throw 'ATTACHMENT_FILENAME_ENCODING_INVALID'}
  $bytes=New-Object 'Collections.Generic.List[byte]';$valueText=$m.Groups[2].Value
  for($i=0;$i-lt$valueText.Length;$i++){
   if($valueText[$i]-eq'%'){if($i+2-ge$valueText.Length-or$valueText.Substring($i+1,2)-notmatch'^[0-9a-fA-F]{2}$'){throw 'ATTACHMENT_FILENAME_ENCODING_INVALID'};$bytes.Add([Convert]::ToByte($valueText.Substring($i+1,2),16));$i+=2}
   elseif([int]$valueText[$i]-le127){$bytes.Add([byte][char]$valueText[$i])}else{throw 'ATTACHMENT_FILENAME_ENCODING_INVALID'}
  }
  return (Get-MailEncoding $m.Groups[1].Value).GetString($bytes.ToArray())
 }
 $plain=Get-MailParameter $Value $Name
 if(-not$plain){$parts=New-Object Text.StringBuilder;for($i=0;$i-lt20;$i++){$part=Get-MailParameter $Value ($Name+'*'+$i);if(-not$part){break};[void]$parts.Append($part)};$plain=$parts.ToString()}
 return (ConvertFrom-MailEncodedWord $plain)
}
function Get-MailAttachmentParts {
 param([string]$Raw,[string]$Part='0',[int]$Depth=0,[switch]$WithBytes)
 if($Depth-gt20){throw 'MIME_NESTING_LIMIT'}
 $entity=Split-MailEntity $Raw -Depth $Depth -AllowEmptyHeaders:($Depth-gt0)
 $ct=[string]$entity.Headers['Content-Type'];$disp=[string]$entity.Headers['Content-Disposition']
 $isFile=$disp-match'^\s*attachment(?:;|\s|$)'-or$disp-match'(?i)(?:^|;)\s*filename\*?'-or$ct-match'(?i)(?:^|;)\s*name\*?'
 if($ct-match'^\s*multipart/'-and-not$isFile){
  $boundary=Get-MailParameter $ct 'boundary'
  if(-not$boundary-or$boundary.Length-gt200){throw 'INVALID_MIME_BOUNDARY'}
  $d=[regex]::Matches($entity.Body,'(?m)^--'+[regex]::Escape($boundary)+'(--)?[ \t]*\r?$')
  if($d.Count-lt2-or$d.Count-gt200-or-not$d[$d.Count-1].Groups[1].Success){throw 'INVALID_MIME_PART_COUNT'}
  for($i=0;$i-lt$d.Count-1;$i++){
   if($d[$i].Groups[1].Success){break}
   $start=$d[$i].Index+$d[$i].Length;if($start-lt$entity.Body.Length-and$entity.Body[$start]-eq[char]10){$start++}
   $child=$entity.Body.Substring($start,$d[$i+1].Index-$start)
   # Remove only the CRLF that precedes a MIME boundary.
   $sep=[regex]::Match($child,'\r?\n\r?\n');$end=if($child.EndsWith("`r`n")){2}elseif($child.EndsWith("`n")){1}else{0}
   if($end-and$sep.Success-and$child.Length-$end-ge$sep.Index+$sep.Length){$child=$child.Substring(0,$child.Length-$end)}
   Get-MailAttachmentParts $child ($Part+'.'+$i) ($Depth+1) -WithBytes:$WithBytes
  }
  return
 }
 if(-not$isFile){return}
 $name=Get-AttachmentParameter $disp 'filename';if(-not$name){$name=Get-AttachmentParameter $ct 'name'}
 $errorCode='';try{$name=Get-AttachmentFileName $name}catch{$errorCode=$_.Exception.Message;if(-not$name){$name='이름 없는 첨부파일'}}
 [byte[]]$bytes=@()
 try{
  switch(([string]$entity.Headers['Content-Transfer-Encoding']).Trim().ToLowerInvariant()){
   'base64'{$bytes=[Convert]::FromBase64String($entity.Body)}
   'quoted-printable'{$bytes=ConvertFrom-MailQuotedPrintable $entity.Body}
   {$_-in@('','7bit','8bit','binary')}{$bytes=[Text.Encoding]::GetEncoding(28591).GetBytes($entity.Body)}
   default{throw 'ATTACHMENT_ENCODING_UNSUPPORTED'}
  }
  if($bytes.Length-gt8MB){throw 'ATTACHMENT_SIZE_LIMIT'}
 }catch{$errorCode=if($_.Exception.Message-cmatch'^[A-Z_]+$'){$_.Exception.Message}else{'ATTACHMENT_DECODE_FAILED'}}
 $item=@{id=[Guid]::NewGuid().ToString('N');part=$Part;name=$name;size=$bytes.Length;hash=(Get-TransferBytesHash $bytes);error=$errorCode}
 if($WithBytes){$item.bytes=$bytes}
 return $item
}
function Register-ExternalAttachments {
 param($Mails,[string]$StateDirectory)
 $folder=Join-Path $StateDirectory 'attachment-catalog';[void][IO.Directory]::CreateDirectory($folder)
 foreach($mail in @($Mails)){
  if([string]$mail.sourceUid-cnotmatch'^\d{6,15}$'){continue}
  foreach($a in @($mail.attachments)){
   if(-not$a-or-not(Test-BridgeId ([string]$a.id))-or$a.error){continue}
   Write-BridgeJson (Join-Path $folder ($a.id+'.json')) @{id=$a.id;uid=$mail.sourceUid;mailId=$mail.id;part=$a.part;name=$a.name;size=$a.size;hash=$a.hash;createdAt=[DateTime]::UtcNow.ToString('o')}
  }
 }
}
function Read-ExternalAttachmentRequest {
 param($Request,[string]$StateDirectory)
 $id=[string]$Request.requestId
 try{
  if(-not(Test-BridgeId ([string]$Request.attachmentId))){throw 'ATTACHMENT_ID_INVALID'}
  $catalogPath=Join-Path (Join-Path $StateDirectory 'attachment-catalog') ($Request.attachmentId+'.json')
  $info=Get-Item -LiteralPath $catalogPath -ErrorAction Stop;if($info.Attributes-band[IO.FileAttributes]::ReparsePoint){throw 'ATTACHMENT_ID_INVALID'}
  $ticket=Read-BridgeJson $catalogPath -MaximumBytes 16384
  if($ticket.id-cne$Request.attachmentId-or[string]$ticket.uid-cnotmatch'^\d{6,15}$'){throw 'ATTACHMENT_ID_INVALID'}
  $name=Get-AttachmentFileName ([string]$ticket.name)
  Set-OperationStep 'ATTACHMENT_READ' 120
  Set-MailOperationPhase '첨부파일 다운로드 중'
  if(Get-Command Write-WorkerStatus -ErrorAction SilentlyContinue){Write-WorkerStatus 'collecting' '첨부파일 다운로드 중 · F4 중지'}
  $profile=Join-Path $StateDirectory 'EdgeProfile';$tabs=@(Get-ReadyExternalWebmailTab $profile)
  if($tabs.Count-ne1){throw 'LOGIN_REQUIRED'}
  $reply=Invoke-EdgeCdp $tabs[0].webSocketDebuggerUrl 'Runtime.evaluate' @{expression=(Get-DirectMailExpression 1 -MailIds @([string]$ticket.uid));returnByValue=$true;awaitPromise=$true}
  if($reply.exceptionDetails-or$reply.result.value.ok-ne$true){throw 'ATTACHMENT_DOWNLOAD_FAILED'}
  $sources=@($reply.result.value.sources)
  if($sources.Count-ne1-or$sources[0].ok-ne$true){$code=[string]$sources[0].code;if($code-cmatch'^[A-Z][A-Z0-9_]+$'){throw $code};throw 'ATTACHMENT_DOWNLOAD_FAILED'}
  $raw=[Text.Encoding]::GetEncoding(28591).GetString([Text.Encoding]::UTF8.GetBytes([string]$sources[0].original))
  $found=@(Get-MailAttachmentParts $raw -WithBytes|Where-Object{$_.part-ceq$ticket.part})
  if($found.Count-ne1-or$found[0].error-or$found[0].name-cne$name-or$found[0].size-ne$ticket.size-or$found[0].hash-cne$ticket.hash){throw 'ATTACHMENT_CHANGED_RELOAD_MAIL'}
  Assert-MailOperationContinue
  $transport=Get-AttachmentTransportName $id $name
  $outbox=Join-Path $StateDirectory 'outbox';[void][IO.Directory]::CreateDirectory($outbox)
  $path=Join-Path $outbox $transport
  [IO.File]::WriteAllBytes($path,[byte[]]$found[0].bytes)
  return @{schemaVersion=4;kind='attachment-result';requestId=$id;attachmentId=$Request.attachmentId;createdAt=[DateTime]::UtcNow.ToString('o');status='success';file=@{name=$name;transportName=$transport;size=$ticket.size;hash=$ticket.hash}}
 }catch{
  Assert-MailOperationContinue
  $code='ATTACHMENT_DOWNLOAD_FAILED';if($_.Exception.Message-cmatch'^[A-Z][A-Z0-9_]+$'){$code=$_.Exception.Message}
  return @{schemaVersion=4;kind='attachment-result';requestId=$id;attachmentId=$Request.attachmentId;createdAt=[DateTime]::UtcNow.ToString('o');status='failed';error=@{code=$code;message=(Get-AttachmentErrorText $code)}}
 }finally{Close-MailCdpSessions}
}
function Get-AttachmentErrorText {
 param([string]$Code)
 if((Test-BridgeLoginRequiredCode $Code)-and(Get-Command Get-MailFailureMessage -ErrorAction SilentlyContinue)){return (Get-MailFailureMessage $Code)}
 switch($Code){
  'LOGIN_REQUIRED'{return '외부 웹메일 로그인 후 첨부파일을 다시 요청하세요.'}
  'ATTACHMENT_CHANGED_RELOAD_MAIL'{return '첨부파일 정보가 달라졌습니다. 메일을 다시 불러오세요.'}
  'ATTACHMENT_SIZE_LIMIT'{return '첨부파일이 지원 크기(8MB)를 넘었습니다.'}
  'ATTACHMENT_RECEIVE_TIMEOUT'{return '파일 수신을 확인하지 못했습니다. 자료교환 허용 형식·용량과 다운로드 상태를 확인하세요.'}
  'ATTACHMENT_HASH_MISMATCH'{return '받은 파일의 크기 또는 내용이 다릅니다. 파일을 제공하지 않았습니다.'}
  'USER_ABORTED'{return '작업을 중지했습니다. 이미 전송됐을 수 있으므로 수신 여부를 확인하세요.'}
  default{return ('첨부파일 처리 실패 ('+$Code+'). 자료교환 허용 형식과 전송 상태를 확인하세요.')}
 }
}
function Submit-InternalAttachmentRequest {
 param($State,[string]$AttachmentId,[string]$DataDirectory)
 if($State.busy-or$State.connecting-or$State.sending){throw 'REQUEST_ALREADY_PENDING'}
 if(-not$State.transferReady){throw 'BACKGROUND_TRANSFER_NOT_CONFIGURED'}
 $selected=@(foreach($m in @($State.mails)){foreach($a in @($m.attachments)){if($a.id-ceq$AttachmentId){$a}}})
 if($selected.Count-ne1-or-not(Test-BridgeId $AttachmentId)-or$selected[0].error){throw 'ATTACHMENT_ID_INVALID'}
 $id=[Guid]::NewGuid().ToString('N');$packet=@{schemaVersion=4;kind='attachment-request';requestId=$id;attachmentId=$AttachmentId;createdAt=[DateTime]::UtcNow.ToString('o')}
 Write-BridgeJson (Join-Path (Join-Path $DataDirectory 'outbox') ('MailTransfer-Request-'+$id+'.txt')) $packet
 $State.attachments[$AttachmentId]=@{requestId=$id;attachmentId=$AttachmentId;name=$selected[0].name;status='requesting';error='';started=[DateTime]::UtcNow.ToString('o');file=$null;path=''}
 Save-InternalAttachments $State $DataDirectory
 Add-InternalBridgeSend $State (Join-Path (Join-Path $DataDirectory 'outbox') ('MailTransfer-Request-'+$id+'.txt')) 'attachment' $id
 $State.pendingId=$id;$State.pendingAt=[DateTime]::UtcNow;$State.busy=$true;$State.status='첨부파일 요청을 외부 PC로 보냅니다.'
}
function Save-InternalAttachments {
 param($State,[string]$DataDirectory)
 Write-BridgeJson (Join-Path $DataDirectory 'attachment-state.json') @($State.attachments.Values)
}
function Update-InternalAttachments {
 param($State,[string]$Folder,[string]$DataDirectory)
 foreach($job in @($State.attachments.Values)){
  if($job.status-notin@('requesting','receiving')){continue}
  if($job.status-eq'receiving'){
   try{
    $name=Get-AttachmentFileName ([string]$job.file.name)
    $expected=Get-AttachmentTransportName $job.requestId $name
    if($job.file.transportName-cne$expected-or[string]$job.file.hash-cnotmatch'^[A-Fa-f0-9]{64}$'-or$job.file.size-lt0-or$job.file.size-gt8MB){throw 'ATTACHMENT_MANIFEST_INVALID'}
    $path=Join-Path $Folder $expected
    # Exact transport filename only: never select a similarly named old file.
    if(Test-Path -LiteralPath $path -PathType Leaf){
     $info=Get-Item -LiteralPath $path
     if($info.Attributes-band[IO.FileAttributes]::ReparsePoint){throw 'ATTACHMENT_MANIFEST_INVALID'}
     if($info.Length-eq$job.file.size){
      [byte[]]$bytes=[IO.File]::ReadAllBytes($path)
      if((Get-TransferBytesHash $bytes)-cne$job.file.hash){throw 'ATTACHMENT_HASH_MISMATCH'}
      $destFolder=Join-Path (Join-Path $DataDirectory 'attachments') $job.requestId;[void][IO.Directory]::CreateDirectory($destFolder)
      $dest=Join-Path $destFolder $name
      # Keep long Windows paths compatible; the download header still preserves the full original name.
      if($dest.Length-gt240){$dest=Join-Path $destFolder ('content'+(Get-AttachmentExtension $name))}
      [IO.File]::WriteAllBytes($dest,$bytes)
      if((Get-TransferBytesHash ([IO.File]::ReadAllBytes($dest)))-cne$job.file.hash){throw 'ATTACHMENT_HASH_MISMATCH'}
      $job.path=$dest;$job.status='ready';$job.error='';$State.status='첨부파일을 받았습니다. 첨부 목록에서 저장할 수 있습니다.'
      $State.busy=$false;$State.pendingId=$null;Save-InternalAttachments $State $DataDirectory
      # Keep received attachment transport and saved original-name copies.
     }
    }
   }catch{$job.status='failed';$job.error=if($_.Exception.Message-cmatch'^[A-Z][A-Z0-9_]+$'){$_.Exception.Message}else{'ATTACHMENT_RECEIVE_FAILED'};$State.busy=$false;$State.status=Get-AttachmentErrorText $job.error;Save-InternalAttachments $State $DataDirectory}
  }
  if($job.status-in@('requesting','receiving')-and([DateTime]::UtcNow-[DateTime]$job.started).TotalMinutes-gt8){$job.status='failed';$job.error='ATTACHMENT_RECEIVE_TIMEOUT';$State.busy=$false;$State.status=Get-AttachmentErrorText $job.error;Save-InternalAttachments $State $DataDirectory}
 }
}
function Get-InternalAttachmentBytes {
 param($State,[string]$Id,[string]$DataDirectory)
 $jobs=@($State.attachments.Values|Where-Object{$_.requestId-ceq$Id-and$_.status-eq'ready'})
 if($jobs.Count-ne1-or-not(Test-BridgeId $Id)){throw 'ATTACHMENT_NOT_READY'}
 $job=$jobs[0];$name=Get-AttachmentFileName ([string]$job.file.name)
 $folder=Join-Path (Join-Path $DataDirectory 'attachments') $Id
 $current=Join-Path $folder $name
 $legacy=Join-Path $folder ('content'+(Get-AttachmentExtension $name))
 # Previously received attachments retain their verified legacy path after upgrade.
 if($job.path-cne$current-and$job.path-cne$legacy){throw 'ATTACHMENT_MANIFEST_INVALID'}
 $expected=[string]$job.path
 foreach($p in @($DataDirectory,(Join-Path $DataDirectory 'attachments'),(Split-Path $expected -Parent),$expected)){if((Get-Item -LiteralPath $p).Attributes-band[IO.FileAttributes]::ReparsePoint){throw 'ATTACHMENT_MANIFEST_INVALID'}}
 $size=(Get-Item -LiteralPath $expected).Length
 if($job.file.size-lt0-or$job.file.size-gt8MB-or$size-ne$job.file.size){throw 'ATTACHMENT_HASH_MISMATCH'}
 [byte[]]$bytes=[IO.File]::ReadAllBytes($expected)
 if($bytes.Length-ne$job.file.size-or(Get-TransferBytesHash $bytes)-cne$job.file.hash){throw 'ATTACHMENT_HASH_MISMATCH'}
 return ,$bytes
}

function Send-AttachmentBridgeOnce {
 param([string]$Path,[string]$Configuration)
 $outcomePath=[IO.Path]::ChangeExtension($Path,'.send.json')
 if(Test-Path -LiteralPath $outcomePath){
  $previous=Read-BridgeJson $outcomePath -MaximumBytes 16384
  if($previous.result-eq'SUBMITTED_UI_CONFIRMED'-and$previous.clicked-eq$true){return}
  if($previous.clicked){throw 'TRANSFER_SUBMITTED_UNCONFIRMED'}
  throw 'ATTACHMENT_PREVIOUS_SEND_FAILED'
 }
 if(Test-Path -LiteralPath ([IO.Path]::ChangeExtension($Path,'.send.progress.json'))){throw 'TRANSFER_SUBMITTED_UNCONFIRMED'}
 Send-BridgePacket $Path $Configuration -Role External
}

function Get-InternalAttachmentDownloadName {
 param($State,[string]$Id)
 if(-not(Test-BridgeId $Id)){throw 'ATTACHMENT_NOT_READY'}
 $matches=@($State.attachments.Values|Where-Object{$_.requestId-ceq$Id-and$_.status-eq'ready'})
 if($matches.Count-ne1){throw 'ATTACHMENT_NOT_READY'}
 return (Get-AttachmentFileName ([string]$matches[0].file.name))
}
function Get-AttachmentContentDisposition {
 param([string]$Name)
 $valid=Get-AttachmentFileName $Name
 $fallback=[regex]::Replace($valid,'[^\x20-\x7e]','_')
 $encoded=[Uri]::EscapeDataString($valid)
 return ('attachment; filename="'+$fallback+'"; filename*=UTF-8'+"''"+$encoded)
}
