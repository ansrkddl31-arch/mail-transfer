#requires -Version 5.1
function Invoke-ChatDom {
 param($Tab,[string]$Action,[string]$Expected='',[string]$Provider='chatgpt',[string]$Model='')
 $script=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'ChatGPT-Dom.js'))
 $args=@($Action,$Expected,$Provider,$Model)|ConvertTo-Json -Compress
 $reply=Invoke-EdgeCdp $Tab.webSocketDebuggerUrl 'Runtime.evaluate' @{expression=($script+"`nexChatDom.apply(null,"+$args+');');returnByValue=$true} -TimeoutSeconds 15
 if($reply.exceptionDetails-or-not$reply.result.value){throw 'CHAT_LAYOUT_UNSUPPORTED'}
 return $reply.result.value
}
function Start-ChatBrowser {
 param([string]$Profile,[string]$Provider='chatgpt')
 if(@(Get-EdgeProfilePages $Profile).Count-gt0){return}
 $edge=$null
 foreach($base in @([Environment]::GetEnvironmentVariable('ProgramFiles(x86)'),[Environment]::GetEnvironmentVariable('ProgramFiles'),[Environment]::GetFolderPath('LocalApplicationData'))){
  if($base){$candidate=Join-Path $base 'Microsoft\Edge\Application\msedge.exe';if(Test-Path -LiteralPath $candidate -PathType Leaf){$edge=$candidate;break}}
 }
 if(-not$edge){throw 'INSTALLED_EDGE_NOT_FOUND'}
 [void][IO.Directory]::CreateDirectory($Profile);Set-MailAutomationProfileOwner $Profile
 $null=Start-Process -FilePath $edge -ArgumentList @('--remote-debugging-port=0','--remote-debugging-address=127.0.0.1',('--user-data-dir="{0}"'-f$Profile),'--no-first-run','--no-default-browser-check','--new-window',(Get-AiWebUrl $Provider)) -PassThru
 $until=[DateTime]::UtcNow.AddSeconds(20)
 do{Assert-MailOperationContinue;if(@(Get-EdgeProfilePages $Profile).Count-gt0){return};Start-Sleep -Milliseconds 300}while([DateTime]::UtcNow-lt$until)
 throw 'CHAT_BROWSER_START_FAILED'
}
function New-ChatTab {
 param([string]$Profile,[string]$Provider='chatgpt')
 Start-ChatBrowser $Profile $Provider
 $pages=@(Get-EdgeProfilePages $Profile|Where-Object{$_.type-eq'page'})
 if(-not$pages.Count){throw 'CHAT_BROWSER_START_FAILED'}
 # Always a fresh online conversation; follow-up context is carried explicitly in the encrypted request.
 $url=Get-AiWebUrl $Provider
 $created=Invoke-EdgeCdp $pages[0].webSocketDebuggerUrl 'Target.createTarget' @{url=$url} -TimeoutSeconds 15
 $id=[string]$created.targetId
 if(-not$id){throw 'CHAT_BROWSER_START_FAILED'}
 $until=[DateTime]::UtcNow.AddSeconds(15)
 do{Assert-MailOperationContinue;$tab=@(Get-EdgeProfilePages $Profile|Where-Object{$_.id-ceq$id});if($tab.Count-eq1){return $tab[0]};Start-Sleep -Milliseconds 300}while([DateTime]::UtcNow-lt$until)
 throw 'CHAT_BROWSER_START_FAILED'
}
function Get-AiWebUrl {
 param([string]$Provider)
 switch($Provider){'chatgpt'{'https://chatgpt.com/'};'claude'{'https://claude.ai/new'};'gemini'{'https://gemini.google.com/app'};default{throw 'CHAT_PROVIDER_INVALID'}}
}
function Get-AiWebModels {
 param($Tab,[string]$Provider)
 $m=Invoke-ChatDom $Tab 'models' '' $Provider
 if($m.code-eq'MODEL_MENU_OPENING'){Start-Sleep -Milliseconds 400;$m=Invoke-ChatDom $Tab 'models' '' $Provider}
 $null=Invoke-ChatDom $Tab 'dismiss-models' '' $Provider
 if($m.code-match'^CHAT_'){throw ([string]$m.code)}
 return @($m.models|Where-Object{$_-is[string]-and$_-notmatch'(?i)upgrade|subscribe|purchase|설정|업그레이드|구독|구매' -and $_-match'(?i)gpt|claude|sonnet|opus|haiku|gemini|flash|\bpro\b|thinking|fast|instant|auto|\bo[1-9]\b|빠른|사고|생각|자동'})
}
function Set-AiWebModel {
 param($Tab,[string]$Provider,[string]$Model)
 if(-not$Model){return}
 if($Model.Length-gt100-or$Model-match'(?i)upgrade|subscribe|purchase|업그레이드|구독|구매'){throw 'CHAT_MODEL_UNAVAILABLE'}
 $v=Invoke-ChatDom $Tab 'select-model' '' $Provider $Model
 if($v.code-eq'MODEL_MENU_OPENING'){Start-Sleep -Milliseconds 400;$v=Invoke-ChatDom $Tab 'select-model' '' $Provider $Model}
 if($v.code-eq'MODEL_CLICKED'){Start-Sleep -Milliseconds 500;$v=Invoke-ChatDom $Tab 'ready' '' $Provider}
 if($v.code-eq'MODEL_SELECTED'){return}
 # Verify the actual picker label. A click alone is not a model change confirmation.
 if($v.code-ne'READY'-or[string]$v.current-cne$Model){throw 'CHAT_MODEL_UNAVAILABLE'}
}
function Set-AiWebFiles {
 param($Tab,[string]$Provider,[string[]]$Paths,[string[]]$Names)
 if(-not$Paths.Count){return}
 Set-OperationStep 'CHAT_UPLOAD' 150
 $doc=Invoke-EdgeCdp $Tab.webSocketDebuggerUrl 'DOM.getDocument' @{depth=0} -TimeoutSeconds 10
 $input=Invoke-EdgeCdp $Tab.webSocketDebuggerUrl 'DOM.querySelector' @{nodeId=$doc.root.nodeId;selector='input[type="file"]'} -TimeoutSeconds 10
 if(-not$input.nodeId){
  # Intercept before opening an upload menu: no native file picker can steal focus or block the worker.
  $null=Invoke-EdgeCdp $Tab.webSocketDebuggerUrl 'Page.setInterceptFileChooserDialog' @{enabled=$true} -TimeoutSeconds 10
  try{
   for($attempt=0;$attempt-lt3;$attempt++){
    $prepare=Invoke-ChatDom $Tab 'prepare-files' '' $Provider
    if($prepare.code-eq'CHAT_ATTACHMENT_UNSUPPORTED'){throw 'CHAT_ATTACHMENT_UNSUPPORTED'}
    Start-Sleep -Milliseconds 400
    $doc=Invoke-EdgeCdp $Tab.webSocketDebuggerUrl 'DOM.getDocument' @{depth=0} -TimeoutSeconds 10
    $input=Invoke-EdgeCdp $Tab.webSocketDebuggerUrl 'DOM.querySelector' @{nodeId=$doc.root.nodeId;selector='input[type="file"]'} -TimeoutSeconds 10
    if($input.nodeId){break}
   }
  }finally{try{$null=Invoke-EdgeCdp $Tab.webSocketDebuggerUrl 'Page.setInterceptFileChooserDialog' @{enabled=$false} -TimeoutSeconds 5}catch{}}
 }
 if(-not$input.nodeId){throw 'CHAT_ATTACHMENT_UNSUPPORTED'}
 $null=Invoke-EdgeCdp $Tab.webSocketDebuggerUrl 'DOM.setFileInputFiles' @{nodeId=$input.nodeId;files=@($Paths)} -TimeoutSeconds 15
 $until=[DateTime]::UtcNow.AddSeconds(45);$namesJson=ConvertTo-Json -InputObject @($Names) -Compress
 do{
  Assert-MailOperationContinue;$v=Invoke-ChatDom $Tab 'files' $namesJson $Provider
  if($v.code-eq'FILES_READY'){return}
  if($v.code-match'^CHAT_'){throw ([string]$v.code)}
  Start-Sleep -Milliseconds 750
 }while([DateTime]::UtcNow-lt$until)
 throw 'CHAT_ATTACHMENT_TIMEOUT'
}
function Invoke-AiWebQuestion {
 param($Tab,[string]$Provider,[string]$Prompt,[string]$Model,[string[]]$Paths=@(),[string[]]$Names=@())
 Set-OperationStep 'CHAT_SEND' 90
 Set-AiWebModel $Tab $Provider $Model
 Set-AiWebFiles $Tab $Provider $Paths $Names
 Set-OperationStep 'CHAT_SUBMIT' 45
 $value=Invoke-ChatDom $Tab 'focus' '' $Provider;if($value.code-ne'FOCUSED'){throw 'CHAT_LAYOUT_UNSUPPORTED'}
 $null=Invoke-EdgeCdp $Tab.webSocketDebuggerUrl 'Input.insertText' @{text=$Prompt} -TimeoutSeconds 15
 Start-Sleep -Milliseconds 400
 $value=Invoke-ChatDom $Tab 'submit' $Prompt $Provider
 if($value.code-notin@('CLICKED','ALREADY_SUBMITTED')){if($value.code-match'^CHAT_'){throw ([string]$value.code)};throw 'CHAT_SUBMIT_UNCONFIRMED'}
 # Exactly one click. Polling never resubmits an uncertain question.
 Set-OperationStep 'CHAT_ANSWER' 210
 $until=[DateTime]::UtcNow.AddSeconds(180);$stable=0;$previous='';$submitted=$false
 do{
  Assert-MailOperationContinue;$v=Invoke-ChatDom $Tab 'answer' $Prompt $Provider
  if($v.code-match'^CHAT_'){throw ([string]$v.code)}
  if($v.code-eq'ANSWER'){
   $submitted=$true;if($v.text.Length-gt100000){throw 'CHAT_ANSWER_TOO_LARGE'}
   if($v.text-and-not$v.streaming-and$v.completed){if([string]$v.text-ceq$previous){$stable++}else{$stable=0};if($stable-ge2){return [string]$v.text}}else{$stable=0}
   $previous=[string]$v.text
  }elseif($v.code-eq'WAIT_ANSWER'){$submitted=$true}
  Start-Sleep -Milliseconds 1000
 }while([DateTime]::UtcNow-lt$until)
 if(-not$submitted){throw 'CHAT_SUBMIT_UNCONFIRMED'};throw 'CHAT_RESPONSE_TIMEOUT'
}
function Read-ExternalChatRequest {
 param($Packet,[string]$StateDirectory,$Key)
 $id=[string]$Packet.requestId;$q=Unprotect-ChatPayload $Key $Packet.sealed $id 'question'
 if($q.provider-notin@('chatgpt','claude','gemini')-or$q.action-notin@('open','check','ask')){throw 'CHAT_REQUEST_INVALID'}
 $null=Protect-ChatPayload ([string]$q.replyPublicXml) @{status='failed';code='CHAT_REQUEST_INVALID'} $id 'answer'
 $temp=Join-Path $StateDirectory ('chat-upload-'+$id);$paths=@();$names=@()
 try{
  Set-MailOperationPhase 'AI 웹 로그인·답변 대기'
  Set-OperationStep 'CHAT_BROWSER' 60
  # Reuse a provider tab for login checks; always use a fresh tab for each submitted question.
  $profile=Join-Path $StateDirectory ('AIWeb-'+[string]$q.provider)
  Start-ChatBrowser $profile ([string]$q.provider)
  $hostName=([Uri](Get-AiWebUrl $q.provider)).Host
  $tabs=@(Get-EdgeProfilePages $profile|Where-Object{$_.type-eq'page'-and([Uri]$_.url).Host-eq$hostName})
  if($q.action-eq'ask'-or-not$tabs.Count){$tab=New-ChatTab $profile $q.provider}else{$tab=$tabs[0]}
  $null=Invoke-EdgeCdp $tab.webSocketDebuggerUrl 'Page.bringToFront' @{} -TimeoutSeconds 10
  Set-OperationStep 'CHAT_LOGIN' 90
  $until=[DateTime]::UtcNow.AddSeconds(20);$v=$null
  do{
   Assert-MailOperationContinue
   try{$v=Invoke-ChatDom $tab 'ready' '' $q.provider}catch{Assert-MailOperationContinue;$v=@{code='WAIT'}}
   if($v.code-ne'WAIT'){break};Start-Sleep -Milliseconds 500
  }while([DateTime]::UtcNow-lt$until)
  if($q.action-eq'open'){$value=@{status='success';ready=($v.code-eq'READY');models=$(if($v.code-eq'READY'){@(Get-AiWebModels $tab $q.provider)}else{@()})}}
  else{
   if($v.code-ne'READY'){if($v.code-in@('CHAT_USAGE_LIMIT','CHAT_CHALLENGE_REQUIRED')){throw ([string]$v.code)};throw 'CHAT_LOGIN_REQUIRED'}
   if($q.action-eq'check'){$value=@{status='success';ready=$true;models=@(Get-AiWebModels $tab $q.provider)}}
   else{
    if($q.prompt-isnot[string]-or-not$q.prompt.Trim()-or$q.prompt.Length-gt12000-or@($q.history).Count-gt20){throw 'CHAT_REQUEST_INVALID'}
    $lines=New-Object 'System.Collections.Generic.List[string]'
    if(@($q.history).Count){$lines.Add('이전 대화 참고 기록입니다. 마지막 사용자 질문에 답해주세요.');foreach($turn in @($q.history)){
     if($turn.role-notin@('user','assistant')-or$turn.content-isnot[string]-or$turn.content.Length-gt100000){throw 'CHAT_REQUEST_INVALID'}
     $lines.Add(([string]$turn.role)+': '+[string]$turn.content)
    }}
    $lines.Add([string]$q.prompt);$prompt=$lines -join "`n`n";if($prompt.Length-gt60000){throw 'CHAT_CONTEXT_TOO_LARGE'}
    $files=@($q.files|Where-Object{$null-ne$_});if($files.Count-gt3){throw 'CHAT_FILE_LIMIT'};$size=0
    if($files.Count){[void][IO.Directory]::CreateDirectory($temp)}
    foreach($f in $files){
     if(-not(Test-ChatFileName ([string]$f.name))){throw 'CHAT_FILE_INVALID'}
     $bytes=[Convert]::FromBase64String([string]$f.data);$size+=$bytes.Length;if(-not$bytes.Length-or$size-gt5242880){throw 'CHAT_FILE_LIMIT'}
     $path=Join-Path $temp $f.name;if(Test-Path -LiteralPath $path){throw 'CHAT_FILE_INVALID'}
     [IO.File]::WriteAllBytes($path,$bytes);$paths+=,$path;$names+=,[string]$f.name
    }
    $answer=Invoke-AiWebQuestion $tab ([string]$q.provider) $prompt ([string]$q.model) $paths $names
    $downloads=Get-AiWebGeneratedFiles $tab ([string]$q.provider) $StateDirectory $id
    $value=@{status='success';answer=$answer;model=[string]$q.model;files=@($downloads.files);fileFailures=@($downloads.failures)}
   }
  }
 }catch{
  $code=[string]$_.Exception.Message;if($code-cnotmatch'^[A-Z][A-Z0-9_]{1,80}$'){$code='CHAT_SERVICE_ERROR'}
  $value=@{status='failed';code=$code}
 }finally{foreach($path in $paths){if(Test-Path -LiteralPath $path){[IO.File]::Delete($path)}};if(Test-Path -LiteralPath $temp){foreach($left in @(Get-ChildItem -LiteralPath $temp -File)){if(-not($left.Attributes-band[IO.FileAttributes]::ReparsePoint)){try{[IO.File]::Delete($left.FullName)}catch{}}};try{[IO.Directory]::Delete($temp,$false)}catch{}}}
 return @{schemaVersion=4;kind='chat-result';requestId=$id;createdAt=[DateTime]::UtcNow.ToString('o');sealed=Protect-ChatPayload ([string]$q.replyPublicXml) $value $id 'answer'}
}
function Get-AiWebGeneratedFiles {
 param($Tab,[string]$Provider,[string]$StateDirectory,[string]$RequestId)
 $folder=Join-Path $StateDirectory ('chat-download-'+$RequestId)
 $files=@();$failures=@();$total=0
 try{
  $v=Invoke-ChatDom $Tab 'artifacts' '' $Provider
  if($v.code-ne'ARTIFACTS'-or$v.count-lt1){return @{files=@();failures=@()}}
  [void][IO.Directory]::CreateDirectory($folder)
  $null=Invoke-EdgeCdp $Tab.webSocketDebuggerUrl 'Browser.setDownloadBehavior' @{behavior='allow';downloadPath=$folder;eventsEnabled=$true} -TimeoutSeconds 10
  for($i=0;$i-lt[Math]::Min(3,[int]$v.count);$i++){
   Set-OperationStep 'CHAT_DOWNLOAD' 60
   $before=@(Get-ChildItem -LiteralPath $folder -File|ForEach-Object{$_.Name})
   try{
    $click=Invoke-ChatDom $Tab 'download' ([string]$i) $Provider
    if($click.code-ne'DOWNLOAD_CLICKED'){throw 'CHAT_DOWNLOAD_UNSUPPORTED'}
    $until=[DateTime]::UtcNow.AddSeconds(40);$previous=-1;$stable=0;$found=$null
    do{
     Assert-MailOperationContinue
     $items=@(Get-ChildItem -LiteralPath $folder -File|Where-Object{$_.Name-notin$before})
     $finished=@($items|Where-Object{$_.Extension-notin@('.crdownload','.tmp')})
     if($finished.Count-eq1-and$items.Count-eq1){
      if($finished[0].Length-eq$previous){$stable++}else{$stable=0};$previous=$finished[0].Length
      if($finished[0].Length-gt5242880){throw 'CHAT_OUTPUT_FILE_LIMIT'}
      if($stable-ge2){$found=$finished[0];break}
     }
     Start-Sleep -Milliseconds 750
    }while([DateTime]::UtcNow-lt$until)
    if(-not$found){throw 'CHAT_DOWNLOAD_TIMEOUT'}
    if($found.Attributes-band[IO.FileAttributes]::ReparsePoint){throw 'CHAT_DOWNLOAD_INVALID'}
    $total+=$found.Length;if($total-gt5242880-or$found.Length-lt1){throw 'CHAT_OUTPUT_FILE_LIMIT'}
    $files+=@{id=[Guid]::NewGuid().ToString('N');name=$found.Name;size=$found.Length;data=[Convert]::ToBase64String([IO.File]::ReadAllBytes($found.FullName))}
   }catch{
    Assert-MailOperationContinue
    $code=[string]$_.Exception.Message;if($code-cnotmatch'^[A-Z][A-Z0-9_]+$'){$code='CHAT_DOWNLOAD_FAILED'}
    $failures+=@{index=$i+1;code=$code}
   }
  }
 }catch{
  Assert-MailOperationContinue;$failures+=@{index=0;code='CHAT_DOWNLOAD_UNSUPPORTED'}
 }finally{
  # Disable downloads for this dedicated browser until the next explicit file retrieval.
  try{$null=Invoke-EdgeCdp $Tab.webSocketDebuggerUrl 'Browser.setDownloadBehavior' @{behavior='deny'} -TimeoutSeconds 5}catch{}
  if(Test-Path -LiteralPath $folder){foreach($item in @(Get-ChildItem -LiteralPath $folder -File)){if(-not($item.Attributes-band[IO.FileAttributes]::ReparsePoint)){try{[IO.File]::Delete($item.FullName)}catch{}}};try{[IO.Directory]::Delete($folder,$false)}catch{}}
 }
 return @{files=@($files);failures=@($failures)}
}
