# Independent per-process progress snapshots; no credentials, subjects, bodies or URLs are recorded.
function Get-OperationStageLabel {
 param([string]$Stage)
 $labels=@{AI_SUMMARY='AI 메일 요약';BOOTSTRAP='작업 프로세스 시작';WORKER_IMPORT='수집 모듈 준비';REQUEST_READ='요청 파일 확인';GUARD_START='중지 키 준비';KEY_PREPARE='연결 키 준비';SESSION_CHECK='로그인 상태 확인';BROWSER_START='자동화용 Edge 연결';LOGIN_NAVIGATION='로그인 화면 준비';LOGIN_SUBMIT='로그인 정보 입력';BIOMETRIC_WAIT='생체 인증 대기';INBOX_SELECT='받은메일함 선택';INBOX_IDS='메일 목록·페이지 읽기';MAIL_BODY='메일 원문 다운로드';MAIL_PARSE='메일 본문 해석';ATTACHMENT_READ='첨부파일 다운로드';ATTACHMENT_CATALOG='첨부 목록 저장';RESULT_WRITE='수집 결과 파일 저장';TRANSFER='자료교환 전송';FINISH='작업 정리'}
 if($labels.ContainsKey($Stage)){return $labels[$Stage]};return $Stage
}
function Write-OperationTraceFiles {
 param([string]$Event)
 if(-not$script:MailOperationTrace){return}
 $ctx=$script:MailOperationTrace;$snap=$ctx.snapshot;$snap.updatedAt=[DateTime]::UtcNow.ToString('o');$snap.sequence++
 $json=$snap|ConvertTo-Json -Depth 8 -Compress
 $temp=$ctx.snapshotPath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 try{
  [IO.File]::WriteAllText($temp,$json,(New-Object Text.UTF8Encoding($false)))
  if([IO.File]::Exists($ctx.snapshotPath)){[IO.File]::Replace($temp,$ctx.snapshotPath,($temp+'.bak'));[IO.File]::Delete($temp+'.bak')}else{[IO.File]::Move($temp,$ctx.snapshotPath)}
  $entry=@{at=$snap.updatedAt;requestId=$snap.requestId;event=$Event;sequence=$snap.sequence;stage=$snap.stage;state=$snap.state;call=$snap.call;current=$snap.current;total=$snap.total;code=$snap.code}
  [IO.File]::AppendAllText($ctx.logPath,(($entry|ConvertTo-Json -Depth 5 -Compress)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
 }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Initialize-OperationTrace {
 param([string]$StateDirectory,[string]$RequestId)
 if($RequestId-cnotmatch'^[a-f0-9]{32}$'){throw 'TRACE_REQUEST_ID_INVALID'}
 [void][IO.Directory]::CreateDirectory($StateDirectory);$logs=Join-Path $StateDirectory 'logs';[void][IO.Directory]::CreateDirectory($logs)
 $script:MailOperationTrace=@{snapshotPath=(Join-Path $StateDirectory ('worker-'+$RequestId+'.trace.json'));logPath=(Join-Path $logs ('MailTransfer-Trace-'+$RequestId+'.jsonl'));snapshot=@{requestId=$RequestId;stage='BOOTSTRAP';label='작업 프로세스 시작';state='running';sequence=0;startedAt=[DateTime]::UtcNow.ToString('o');stepStartedAt='';updatedAt='';deadlineAt='';call='';callStartedAt='';callDeadlineAt='';current=0;total=0;code='';failedStage=''}}
 Set-OperationStep 'BOOTSTRAP' 30
}
function Set-OperationStep {
 param([string]$Stage,[ValidateRange(1,600)][int]$TimeoutSeconds=60,[ValidateRange(0,100000)][int]$Current=0,[ValidateRange(0,100000)][int]$Total=0)
 if(-not$script:MailOperationTrace){return}
 if($Stage-cnotmatch'^[A-Z_]{1,40}$'){throw 'TRACE_STAGE_INVALID'}
 $s=$script:MailOperationTrace.snapshot;$now=[DateTime]::UtcNow
 $s.stage=$Stage;$s.label=Get-OperationStageLabel $Stage;$s.stepStartedAt=$now.ToString('o');$s.deadlineAt=$now.AddSeconds($TimeoutSeconds).ToString('o');$s.current=$Current;$s.total=$Total;$s.call='';$s.callDeadlineAt=''
 Write-OperationTraceFiles 'step_started'
}
function Start-OperationCall {
 param([string]$Method,[int]$TimeoutSeconds)
 if(-not$script:MailOperationTrace){return}
 if($Method-cnotmatch'^[A-Za-z]+\.[A-Za-z]+$'){throw 'TRACE_METHOD_INVALID'}
 $s=$script:MailOperationTrace.snapshot;$s.call=$Method;$s.callStartedAt=[DateTime]::UtcNow.ToString('o');$s.callDeadlineAt=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds).ToString('o')
 Write-OperationTraceFiles 'call_started'
}
function Stop-OperationCall {
 param([string]$Code='')
 if(-not$script:MailOperationTrace){return}
 $s=$script:MailOperationTrace.snapshot
 if($Code){Record-OperationFailure $Code}
 Write-OperationTraceFiles $(if($Code){'call_failed'}else{'call_completed'})
 $s.call='';$s.callDeadlineAt='';Write-OperationTraceFiles 'call_closed'
}
function Record-OperationFailure {
 param([string]$Code)
 if(-not$script:MailOperationTrace){return}
 if($Code-cnotmatch'^[A-Z][A-Z0-9_]{0,100}$'){$Code='OPERATION_FAILED'}
 $s=$script:MailOperationTrace.snapshot;$s.code=$Code;if(-not$s.failedStage){$s.failedStage=$s.stage}
 Write-OperationTraceFiles 'failure_observed'
}
function Complete-OperationTrace {
 param([string]$Code='')
 if(-not$script:MailOperationTrace){return}
 if($Code){Record-OperationFailure $Code}
 $s=$script:MailOperationTrace.snapshot;$s.state=if($Code){'failed'}else{'completed'};$s.code=$Code;if(-not$Code){$s.failedStage=''};$s.deadlineAt='';$s.callDeadlineAt=''
 Write-OperationTraceFiles 'operation_finished'
}
function Get-OperationTraceSnapshot {
 if($script:MailOperationTrace){return $script:MailOperationTrace.snapshot};return $null
}
function Get-OperationWatchdogDecision {
 param($Trace,[DateTime]$Now=[DateTime]::UtcNow)
 if($null-eq$Trace-or$Trace.state-ne'running'){return $false}
 foreach($key in @('deadlineAt','callDeadlineAt')){
  $deadline=[DateTime]::MinValue
  if([DateTime]::TryParse([string]$Trace.$key,[ref]$deadline)-and$Now-ge$deadline.ToUniversalTime()){return $true}
 }
 return $false
}
function Update-ExternalOperationWatchdog {
 param($State,$Trace,[DateTime]$Now=[DateTime]::UtcNow)
 $job=$State.active;if($null-eq$job){return}
 if($job.process.HasExited-and(-not$job.Contains('watchdogAt')-or$job.watchdogAt-eq[DateTime]::MinValue)){return}
 if(-not$job.Contains('startedAt')){$job.startedAt=$Now}
 if(-not$job.Contains('watchdogAt')){$job.watchdogAt=[DateTime]::MinValue}
 $expired=if($Trace){
  if($Trace.state-eq'running'){Get-OperationWatchdogDecision $Trace $Now}
  else{$ended=[DateTime]::MinValue;[DateTime]::TryParse([string]$Trace.updatedAt,[ref]$ended)-and($Now-$ended.ToUniversalTime()).TotalSeconds-gt15}
 }else{($Now-$job.startedAt).TotalSeconds-gt45}
 if(-not$expired-and$job.watchdogAt-eq[DateTime]::MinValue){return}
 if($job.watchdogAt-eq[DateTime]::MinValue){
  $job.watchdogAt=$Now;$job.timeoutStage=if($Trace-and$Trace.state-ne'running'){'FINISH'}elseif($Trace){[string]$Trace.stage}else{'BOOTSTRAP'}
  $job.timeoutCall=if($Trace){[string]$Trace.call}else{''}
  # Signal cancellation first. The guard releases input independently of a hung PowerShell call.
  try{[void][MailTransfer.InputGuard]::RequestStop('Local\MailTransferCancel-'+$job.requestId)}catch{}
  $State.status='응답 시간 초과: '+(Get-OperationStageLabel $job.timeoutStage)+' · 중지 중입니다.'
 }
 if(-not$job.process.HasExited-and($Now-$job.watchdogAt).TotalSeconds-lt3){return}
 # This is the exact child Process object created for this request, not a name-based process search.
 try{if(-not$job.process.HasExited){$job.process.Kill()}}catch{if(-not$job.process.HasExited){$State.status+=' 작업 프로세스를 종료하지 못했습니다.';return}}
 try{[void]$job.process.WaitForExit(1000)}catch{}
 $label=Get-OperationStageLabel $job.timeoutStage
 $snap=@{requestId=$job.requestId;stage=$job.timeoutStage;label=$label;state='failed';code='OPERATION_STEP_TIMEOUT';call=$job.timeoutCall;startedAt=$job.startedAt.ToString('o');stepStartedAt=$(if($Trace){$Trace.stepStartedAt}else{$job.startedAt.ToString('o')});updatedAt=$Now.ToString('o');deadlineAt='';callDeadlineAt='';current=$(if($Trace){$Trace.current}else{0});total=$(if($Trace){$Trace.total}else{0});failedStage=$job.timeoutStage}
 Write-BridgeJson (Join-Path $State.stateDir ('worker-'+$job.requestId+'.trace.json')) $snap
 $logs=Join-Path $State.stateDir 'logs';[void][IO.Directory]::CreateDirectory($logs)
 [IO.File]::AppendAllText((Join-Path $logs ('MailTransfer-Trace-'+$job.requestId+'.jsonl')),(($snap|ConvertTo-Json -Depth 5 -Compress)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
 Write-BridgeJson $job.statusFile @{phase='done';status=('응답 시간 초과로 중지했습니다. 멈춘 단계: '+$label+' ('+$job.timeoutStage+'). 자동 재시도하지 않습니다.');code='OPERATION_STEP_TIMEOUT';collectionStatus='failed';collectedCount=$([int]$State.collectedCount);failedCount=0;collectionError='OPERATION_STEP_TIMEOUT';collectionDetails=@{operationStage=$job.timeoutStage};sendStatus=$(if($job.timeoutStage-eq'TRANSFER'){'uncertain'}else{'not-started'});inputLocked=$false;operationPhase=''}
 $State.operationTrace=$snap
}
