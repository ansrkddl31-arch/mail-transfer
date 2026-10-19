#requires -Version 5.1
param([ValidateSet('chatgpt','claude','gemini')][string]$Provider,[string]$AiStateDirectory,[string]$ResultPath,[int]$ControllerPid=0,[long]$ControllerStart=0)
$localAiProvider=$Provider;$localAiDir=$AiStateDirectory;$localAiResult=$ResultPath;$localAiPid=$ControllerPid;$localAiStart=$ControllerStart
$ErrorActionPreference='Stop'
function Write-LocalAiStatus {
 param([string]$Path,$Value)
 [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 6 -Compress),(New-Object Text.UTF8Encoding($true)))
}
try{
 . (Join-Path $PSScriptRoot 'Common.ps1')
 . (Join-Path $PSScriptRoot 'Collector.ps1') -LibraryOnly
 $id=[Guid]::NewGuid().ToString('N')
 Start-MailInputGuard $id -Phase 'AI 직접 연결 점검' -ControllerPid $localAiPid -ControllerStart $localAiStart
 Write-LocalAiStatus $localAiResult @{provider=$localAiProvider;status='opening';code='';message='AI 전용 Edge를 여는 중입니다.'}
 $profile=Join-Path $localAiDir ('AIWeb-'+$localAiProvider)
 Start-ChatBrowser $profile $localAiProvider
 $hostName=([Uri](Get-AiWebUrl $localAiProvider)).Host
 $tabs=@(Get-EdgeProfilePages $profile|Where-Object{$_.type-eq'page'-and([Uri]$_.url).Host-eq$hostName})
 $tab=if($tabs.Count){$tabs[0]}else{New-ChatTab $profile $localAiProvider}
 $null=Invoke-EdgeCdp $tab.webSocketDebuggerUrl 'Page.bringToFront' @{} -TimeoutSeconds 10
 $until=[DateTime]::UtcNow.AddSeconds(20);$v=$null
 do{
  Assert-MailOperationContinue
  try{$v=Invoke-ChatDom $tab 'ready' '' $localAiProvider}catch{Assert-MailOperationContinue;$v=@{code='WAIT'}}
  if($v.code-ne'WAIT'){break};Start-Sleep -Milliseconds 500
 }while([DateTime]::UtcNow-lt$until)
 if($v.code-eq'READY'){$models=@(Get-AiWebModels $tab $localAiProvider);Write-LocalAiStatus $localAiResult @{provider=$localAiProvider;status='done';code='READY';modelCount=$models.Count;message=('외부에서 AI 화면을 확인했습니다. 로그인됨 / 모델 메뉴 '+$models.Count+'개. 내부에서 이미 로그인함을 다시 누르세요.')}}
 else{Write-LocalAiStatus $localAiResult @{provider=$localAiProvider;status='done';code=[string]$v.code;message=('AI 창을 열었습니다. 이 전용 창에서 로그인·2차 인증을 완료하세요. 확인 결과: '+[string]$v.code)}}
}catch{
 $code=[string]$_.Exception.Message;if($code-cnotmatch'^[A-Z][A-Z0-9_]+$'){$code=$_.Exception.GetType().Name}
 try{Write-LocalAiStatus $localAiResult @{provider=$localAiProvider;status='failed';code=$code;message=('AI 직접 열기 실패: '+$code)}}catch{}
}finally{if(Get-Command Stop-MailInputGuard -ErrorAction SilentlyContinue){Stop-MailInputGuard};if(Get-Command Close-MailCdpSessions -ErrorAction SilentlyContinue){Close-MailCdpSessions}}
