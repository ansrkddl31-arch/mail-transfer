#requires -Version 5.1
[CmdletBinding()]
param([switch]$LibraryOnly)
$ErrorActionPreference='Stop'
function Get-EXMailPortablePaths {
 param([string]$Root)
 $full=[IO.Path]::GetFullPath($Root)
 $data=Join-Path $full 'data'
 return @{root=$full;program=(Join-Path $full 'program');data=$data;configuration=(Join-Path $data 'bridge-settings.json');owner=(Join-Path $data 'running.json');url='http://127.0.0.1:8765/'}
}
function Test-EXMailPortableOwner {
 param($Paths)
 try{
  $owner=[IO.File]::ReadAllText($Paths.owner)|ConvertFrom-Json
  $process=Get-Process -Id ([int]$owner.processId) -ErrorAction Stop
  if($process.StartTime.ToUniversalTime().Ticks-ne[long]$owner.startedTicks){return $false}
  if($process.ProcessName-notin@('powershell','pwsh')){return $false}
  $state=Invoke-RestMethod ($Paths.url+'api/state') -TimeoutSec 2
  return $state.application-in@('mail-transfer-bridge','mail-transfer-internal')-and$state.release-in@('bridge-v17.3','internal-v17.3')
 }catch{return $false}
}
function Test-EXMailPortablePort {
 $client=New-Object Net.Sockets.TcpClient
 try{
  $pending=$client.BeginConnect('127.0.0.1',8765,$null,$null)
  if(-not$pending.AsyncWaitHandle.WaitOne(400)){return $false}
  $client.EndConnect($pending);return $true
 }catch{return $false}finally{$client.Dispose()}
}
function Start-EXMailPortableBridge {
 param($Paths)
 # State, Edge profile, received mail, calendar and settings are scoped to this folder.
 $previousRoot=[Environment]::GetEnvironmentVariable('EXMAIL_PORTABLE_STATE_ROOT')
 try{
  [Environment]::SetEnvironmentVariable('EXMAIL_PORTABLE_STATE_ROOT',$Paths.data,'Process')
  & (Join-Path $Paths.program 'Start-Bridge.ps1') -Port 8765 -ConfigurationFile $Paths.configuration -StateRoot $Paths.data
 }finally{[Environment]::SetEnvironmentVariable('EXMAIL_PORTABLE_STATE_ROOT',$previousRoot,'Process')}
}
function Open-EXMailPortablePage {param([string]$Url) Start-Process $Url}
function Invoke-EXMailPortable {
 param([string]$Root=$PSScriptRoot)
 $paths=Get-EXMailPortablePaths $Root
 foreach($name in @('Start-Bridge.ps1','Common.ps1','app.html','Maintenance.ps1','Transfer.Image.ps1')){
  if(-not[IO.File]::Exists((Join-Path $paths.program $name))){throw '프로그램 파일이 빠졌습니다. ZIP 전체를 새 폴더에 압축 해제하세요.'}
 }
 # Different copies never silently attach to each other's running service.
 [void][IO.Directory]::CreateDirectory($paths.data)
 $check=Join-Path $paths.data ('.write-check-'+[guid]::NewGuid().ToString('N'))
 try{[IO.File]::WriteAllText($check,'');[IO.File]::Delete($check)}catch{throw '포터블 폴더에 저장할 수 없습니다. 쓰기 가능한 폴더에 압축 해제하세요.'}
 $sha=[Security.Cryptography.SHA256]::Create()
 try{$id=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($paths.root.ToUpperInvariant())))).Replace('-','')}finally{$sha.Dispose()}
 $mutex=New-Object Threading.Mutex($false,('Local\EXMailPortable-'+$id));$owned=$false;$ownerWritten=$false
 try{
  try{$owned=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
  if(-not$owned){
   for($i=0;$i-lt20;$i++){if(Test-EXMailPortableOwner $paths){Open-EXMailPortablePage $paths.url;return};Start-Sleep -Milliseconds 300}
   throw '같은 포터블 프로그램이 시작 중이거나 응답하지 않습니다. 기존 PowerShell 창을 확인하세요.'
  }
  if(Test-EXMailPortablePort){throw '기존 EX메일 또는 다른 프로그램이 8765 포트를 사용 중입니다. 기존 PowerShell 창을 닫고 다시 실행하세요.'}
  $current=Get-Process -Id $PID
  [IO.File]::WriteAllText($paths.owner,(@{processId=$PID;startedTicks=$current.StartTime.ToUniversalTime().Ticks}|ConvertTo-Json -Compress))
  $ownerWritten=$true
  Write-Host 'EX메일 익스플로러 · 포터블 (이미지4)'
  Write-Host '이 창을 켜 두세요. 브라우저 탭만 닫아도 프로그램은 계속 실행됩니다.'
  Write-Host '종료: 자료교환 작업을 F4로 중지한 뒤 이 PowerShell 창을 닫으세요.'
  Write-Host ('설정·메일 보관: '+$paths.data)
  Start-EXMailPortableBridge $paths
 }finally{
  if($ownerWritten){try{[IO.File]::Delete($paths.owner)}catch{}}
  if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()
 }
}
if($LibraryOnly){return}
try{Invoke-EXMailPortable $PSScriptRoot}catch{
 Write-Host ('실행하지 못했습니다: '+$_.Exception.Message) -ForegroundColor Red
 Write-Host '압축 해제 폴더, 기존 프로그램 실행 여부와 회사의 PowerShell 실행 정책을 확인하세요.'
}
