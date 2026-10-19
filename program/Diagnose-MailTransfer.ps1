#requires -Version 5.1
param([int]$Port=8765,[string]$StateRoot=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'MailTransferBridge'),[string]$OutputDirectory=[Environment]::GetFolderPath('Desktop'),[switch]$NoOpen,[switch]$LibraryOnly)
$ErrorActionPreference='Stop'
function Get-MailTransferDiagnostics {
 param([string]$ProgramFolder,[int]$ListenPort=8765,[string]$BridgeStateRoot,$StateSnapshot=$null)
 $lines=New-Object 'System.Collections.Generic.List[string]'
 $lines.Add('MailTransfer read-only diagnostic; no credentials or mail bodies')
 $lines.Add('Generated: '+[DateTime]::Now.ToString('o'));$lines.Add('Diagnostic folder: '+$ProgramFolder)
 $state=$null
 try{
  $state=if($null-ne$StateSnapshot){$StateSnapshot}else{Invoke-RestMethod -Uri ('http://127.0.0.1:'+ $ListenPort+'/api/state') -TimeoutSec 3}
  if($state.role -notin @('Internal','External')){$lines.Add('No configured bridge role returned.');$state=$null}
  else{foreach($key in @('role','release','externalRelease','aiWebSupported','phase','status','lastResult','lastAt','inbox','collectionStatus','collectedCount','failedCount','collectionError','sendStage','sendError','browserStatus','browserCode')){if(($state-is[Collections.IDictionary] -and $state.Contains($key)) -or $null-ne$state.PSObject.Properties[$key]){$lines.Add($key+': '+[string]$state.$key)}}}
  if($state.localAiStatus){foreach($k in @('provider','status','code')){$v=[string]$state.localAiStatus.$k;if($v-cmatch'^[A-Za-z0-9_-]{1,100}$'){$lines.Add('localAi.'+$k+'='+$v)}}}
  if($state.chat){
   foreach($key in @('provider','status','error')){$v=[string]$state.chat.result.$key;if($v-cmatch'^[A-Za-z0-9_-]{1,100}$'){$lines.Add('chat.'+$key+'='+$v)}}
   foreach($provider in @('chatgpt','claude','gemini')){$info=$state.chat.providers.$provider;if($info){$lines.Add('chat.'+$provider+'.ready='+[bool]$info.ready);$lines.Add('chat.'+$provider+'.modelCount='+@($info.models).Count)}}
  }
  if($state.operationTrace){$lines.Add('operationTrace: '+($state.operationTrace|ConvertTo-Json -Depth 8 -Compress))}

 }catch{$lines.Add('Local HTTP server check failed: '+$_.Exception.GetType().Name)}
 $runtimeFolder=''
 if([Environment]::OSVersion.Platform-eq[PlatformID]::Win32NT){
  try{
   $connection=Get-NetTCPConnection -LocalPort $ListenPort -State Listen -ErrorAction Stop|Where-Object{$_.LocalAddress -in @('127.0.0.1','::1')}|Select-Object -First 1
   if($null-ne$connection){
    $process=Get-CimInstance Win32_Process -Filter ('ProcessId='+$connection.OwningProcess)
    # Select only the -File path; never print arbitrary command lines.
    $match=[regex]::Match([string]$process.CommandLine,'(?i)(?:^|\s)-File\s+(?:"([^"\r\n]+)"|([^\s]+))')
    if($match.Success){$scriptPath=if($match.Groups[1].Success){$match.Groups[1].Value}else{$match.Groups[2].Value};if([IO.Path]::GetFileName($scriptPath)-ieq'Start-Bridge.ps1'){$runtimeFolder=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($scriptPath));$lines.Add('Running bridge folder: '+$runtimeFolder)}}
   }
  }catch{$lines.Add('Running folder check unavailable: '+$_.Exception.GetType().Name)}
 }
 if($runtimeFolder -and -not[string]::Equals($runtimeFolder,$ProgramFolder,[StringComparison]::OrdinalIgnoreCase)){$lines.Add('NOTICE: diagnostic/update folder differs from running bridge folder.')}
 $role=if($null-ne$state){[string]$state.role}else{'External'}
 $roleFolder=Join-Path $BridgeStateRoot $role
 # Trace files are written before blocking calls, independently of terminal status.
 $traceFiles=@(Get-ChildItem -LiteralPath $roleFolder -Filter 'worker-*.trace.json' -File -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 2)
 foreach($traceFile in $traceFiles){
  if(($traceFile.Attributes-band[IO.FileAttributes]::ReparsePoint)-or$traceFile.Length-gt65536){continue}
  try{
   $traceData=[IO.File]::ReadAllText($traceFile.FullName)|ConvertFrom-Json
   $safe=@{};foreach($k in @('requestId','stage','label','state','code','call','current','total','startedAt','stepStartedAt','updatedAt','deadlineAt','callDeadlineAt','failedStage')){$safe[$k]=$traceData.$k}
   $lines.Add('Trace snapshot: '+($safe|ConvertTo-Json -Compress))
   if([string]$traceData.requestId-cmatch'^[a-f0-9]{32}$'){
    $log=Join-Path (Join-Path $roleFolder 'logs') ('MailTransfer-Trace-'+$traceData.requestId+'.jsonl')
    $info=Get-Item -LiteralPath $log -ErrorAction SilentlyContinue
    if($info-and-not($info.Attributes-band[IO.FileAttributes]::ReparsePoint)-and$info.Length-le8MB){
     foreach($line in @(Get-Content -LiteralPath $log -Tail 30)){
      try{$event=$line|ConvertFrom-Json;$safe=@{};foreach($k in @('at','event','sequence','stage','state','call','current','total','code')){$safe[$k]=$event.$k};$lines.Add('Trace event: '+($safe|ConvertTo-Json -Compress))}catch{}
     }
    }
   }
  }catch{$lines.Add('Trace read failed: '+$_.Exception.GetType().Name)}
 }
 $inbox=if($null-ne$state -and $state.inbox){[string]$state.inbox}else{if($role-eq'External'){'C:\FTC_downloads'}else{'D:\FTC_downloads'}}
 foreach($category in @('worker','send','progress','result','request')){
  $folder=if($category-eq'worker'){$roleFolder}elseif($category-eq'request'){$inbox}else{Join-Path $roleFolder 'outbox'}
  $pattern=switch($category){'worker'{'worker-*.status.json'} 'send'{'MailTransfer-*.send.json'} 'progress'{'MailTransfer-*.send.progress.json'} 'result'{'MailTransfer-Result-*.txt'} default{'MailTransfer-Request-*.txt'}}
  $lines.Add('--- '+$category+' metadata ---')
  if(-not(Test-Path -LiteralPath $folder -PathType Container)){$lines.Add('Folder unavailable.');continue}
  $files=@(Get-ChildItem -LiteralPath $folder -Filter $pattern -File -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 3)
  if(-not $files.Count){$lines.Add('No matching files.');continue}
  foreach($file in $files){
   $lines.Add('File: '+$file.Name+'; bytes='+$file.Length)
   if(($file.Attributes-band[IO.FileAttributes]::ReparsePoint)-or$file.Length-gt67108864){$lines.Add('Skipped unsupported file.');continue}
   try{
    $data=[IO.File]::ReadAllText($file.FullName)|ConvertFrom-Json
    foreach($key in @('kind','requestId','count','status','phase','code','stage','result','clicked','collectionStatus','collectedCount','failedCount','collectionError','sendStatus')){
     $value=$data.$key
     if($value-is[string]-or$value-is[bool]-or$value-is[int]-or$value-is[long]){if(([string]$value).Length-gt512){$value=([string]$value).Substring(0,512)};$lines.Add($key+'='+[string]$value)}
    }
    $details=if($category-eq'worker'){$data.collectionDetails}else{$data.error.details}
    foreach($detailKey in @('mailIndex','collectedBeforeFailure','headerLine','mimeDepth')){
     $detail=$details.$detailKey
     if(($detail-is[int]-or$detail-is[long])-and$detail-ge0-and$detail-le10000){$lines.Add('parse.'+$detailKey+'='+[string]$detail)}
    }
    if($details.headerReason-in@('ORPHAN_CONTINUATION','NON_ASCII_HEADER_LINE','HEADER_COLON_MISSING','INVALID_FIELD_NAME')){$lines.Add('parse.headerReason='+[string]$details.headerReason)}
    if([string]$details.operationStage-cmatch'^[A-Z_]{1,40}$'){$lines.Add('collection.operationStage='+[string]$details.operationStage)}
    if([string]$details.exceptionType-cmatch'^[A-Za-z0-9]{1,80}$'){$lines.Add('collection.exceptionType='+[string]$details.exceptionType)}
    if($data.aiInfo){foreach($aiKey in @('status','count','failed','error','model')){$value=$data.aiInfo.$aiKey;if(($value-is[string]-and$value.Length-le100)-or$value-is[int]-or$value-is[long]){$lines.Add('ai.'+$aiKey+'='+[string]$value)}}}
    if($data.kind-eq'mail-result'){$lines.Add('mailCount='+@($data.mails).Count)}
    if($data.failedMails){$lines.Add('failedMailCount='+@($data.failedMails).Count)}
    $failures=if($category-eq'worker'){@($data.collectionFailures|Where-Object{$null-ne$_})}else{@($data.failedMails|Where-Object{$null-ne$_})}
    foreach($failure in @($failures|Select-Object -First 1000)){
     if([string]$failure.stage-cmatch'^[A-Z_]{1,40}$'){$lines.Add('failedMail.stage='+[string]$failure.stage)}
     if([string]$failure.sourceUid-cmatch'^\d{6,15}$'){$lines.Add('failedMail.sourceUid='+[string]$failure.sourceUid)}
     if(($failure.mailIndex-is[int]-or$failure.mailIndex-is[long])-and$failure.mailIndex-ge1-and$failure.mailIndex-le1000-and[string]$failure.code-cmatch'^[A-Z][A-Z0-9_]{0,100}$'){$lines.Add('failedMail['+$failure.mailIndex+']='+$failure.code);foreach($shape in @('responseChars','textareaCount','preCount','breakCount','frameCount','scriptCount','frameReadAttempts','subjectTokenPresent','mimeTokenPresent','loginTitle','errorTitle')){$v=$failure.details.$shape;if($v-is[bool]-or(($v-is[int]-or$v-is[long])-and$v-ge0-and$v-le12582912)){$lines.Add('failedMail['+$failure.mailIndex+'].'+$shape+'='+[string]$v)}}}
    }

    if($data.error-is[string]){$lines.Add('error='+$data.error)}
    elseif($null-ne$data.error){$lines.Add('error.code='+[string]$data.error.code+'; error.stage='+[string]$data.error.stage)}
   }catch{$lines.Add('Metadata read failed: '+$_.Exception.GetType().Name)}
  }
 }
 return ($lines -join "`r`n")
}
if($LibraryOnly){return}
$folder=$PSScriptRoot
$text=Get-MailTransferDiagnostics $folder $Port $StateRoot
if([string]::IsNullOrWhiteSpace($OutputDirectory)){$OutputDirectory=$folder}
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$path=Join-Path $OutputDirectory ('MailTransfer-Diagnostic-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)+'.txt')
[IO.File]::WriteAllText($path,$text,(New-Object Text.UTF8Encoding($true)))
Write-Host ('Saved diagnostic: '+$path)
if(-not$NoOpen-and[Environment]::OSVersion.Platform-eq[PlatformID]::Win32NT){Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\notepad.exe') -ArgumentList ('"'+$path+'"')}
