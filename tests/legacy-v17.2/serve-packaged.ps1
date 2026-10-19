param([string]$ProgramPath,[string]$QaRoot,[int]$QaPort)
$ErrorActionPreference='Stop'
. (Join-Path $ProgramPath 'Start-Bridge.ps1') -LibraryOnly
$state=New-InternalBridgeState;$state.publicXml='fixture-public-key';$state.attachmentDataDirectory=$QaRoot;$state.inbox='D:\FTC_downloads';$state.updatedAt='2026-10-15 14:32';$state.status='메일 100건을 가져왔습니다.';$state.configurationFile=Join-Path $QaRoot 'bridge-settings.json'
$state.aiPreferences=@{enabled=$true;extractSchedule=$true;provider='openai';maxCount=20};$state.connectionAttempted=$true
$state.mails=@(foreach($i in 1..100){$subjects=@('[프로젝트] 인터페이스 설계서 검토 요청','10월 3주차 주간 업무보고서 공유','회의 일정 및 검토 자료 안내','서비스 정기 점검 안내');@{id=[string]$i;subject=$subjects[($i-1)%4]+$(if($i-gt4){' · '+$i}else{''});from='김담당 <project@example.invalid>';date='Thu, 15 Oct 2026 09:32:00 +0900';body="안녕하세요.`n프로젝트 담당 김담당입니다.`n`n검토 요청하신 인터페이스 설계서를 전달드립니다.`n주요 반영 내용은 다음과 같습니다.`n`n• 요청 헤더 항목 및 인증 정보 정리`n• 연계 API 호출 규격 업데이트`n• 기존 검토 의견 및 상세 설명 반영`n`n2026-10-20 15:00에 검토 회의가 있습니다.`n회의 전까지 검토 의견 회신을 부탁드립니다.`n`n감사합니다.";attachments=@(@{id=('c'*31+'1');name='인터페이스_설계서_v1.2.xlsx';size=41518});ai=$(if($i-eq1){@{status='success';provider='openai';category='요청';summary='업데이트된 설계서의 인증 항목 검토가 필요합니다. 10월 20일 오후 3시 검토 회의 전까지 의견을 정리해 주세요.';candidates=@(@{id=('a'*64);title='설계서 검토 회의';date='2026-10-20';time='15:00';evidence='2026-10-20 15:00에 검토 회의가 있습니다.'})}}else{$null})}})
Write-BridgeJson (Join-Path $QaRoot 'calendar.json') @{version=1;items=@(@{id=('b'*32);title='주간 업무 점검';date='2026-10-16';time='10:00';done=$false;sourceKey=''})}
Write-BridgeJson $state.configurationFile @{role='Internal';inbox=$state.inbox;folderConfirmed=$true;count=100}
$app=@{role='Internal';internal=$state;stateDir=$QaRoot;stateRoot=$QaRoot;configurationFile=$state.configurationFile;setupActive=$false}
$page=[IO.File]::ReadAllText((Join-Path $ProgramPath 'app.html')).Replace('__TOKEN__','visual-qa-token').Replace('__MAIL_RENDERER__',(Get-MailFormatScript))
$listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,$QaPort);$clients=New-Object Collections.ArrayList
try{$listener.Start();[Console]::WriteLine('READY');[Console]::Out.Flush()
 while(-not(Test-Path (Join-Path $QaRoot 'stop'))){
  while($listener.Pending()){[void]$clients.Add(@{client=$listener.AcceptTcpClient();at=[DateTime]::UtcNow})}
  foreach($entry in @($clients.ToArray())){if($entry.client.Available-gt0){try{Handle-BridgeRequest $entry.client $app $page 'visual-qa-token' $QaPort}catch{$entry.client.Dispose()};[void]$clients.Remove($entry)}elseif(([DateTime]::UtcNow-$entry.at).TotalSeconds-gt3){$entry.client.Dispose();[void]$clients.Remove($entry)}}
  Start-Sleep -Milliseconds 20
 }
}finally{foreach($entry in @($clients.ToArray())){$entry.client.Dispose()};$listener.Stop()}
