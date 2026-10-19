param([switch]$LibraryOnly)
$ErrorActionPreference='Stop'
function Test-EXMailRunning {
 $state=$null
 try{$state=Invoke-RestMethod 'http://127.0.0.1:8765/api/state' -TimeoutSec 2}catch{return $false}
 if($state.application-in@('mail-transfer-bridge','mail-transfer-internal')){
  if($state.release-notin@('bridge-v18.2','internal-v18.2')){throw '구버전 프로그램이 실행 중입니다. 기존 PowerShell 창을 종료한 뒤 EX메일 익스플로러 바로가기를 다시 실행하세요. 새 앱 상단에는 앱 v18.2이 표시됩니다.'}
  return $true
 }
 throw '8765 포트를 다른 프로그램이 사용하고 있습니다. 실행 중인 프로그램을 확인하세요.'
}
function Open-EXMail {
 param([string]$ProgramDirectory)
 $url='http://127.0.0.1:8765/'
 if(Test-EXMailRunning){Start-Process $url;return}
 $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
 $args='-NoProfile -STA -ExecutionPolicy RemoteSigned -File "{0}" -NoBrowser' -f (Join-Path $ProgramDirectory 'Start-Bridge.ps1')
 [void](Start-Process -FilePath $ps -ArgumentList $args -WorkingDirectory $ProgramDirectory -WindowStyle Minimized)
 for($i=0;$i-lt30;$i++){Start-Sleep -Milliseconds 300;if(Test-EXMailRunning){Start-Process $url;return}}
 throw '프로그램 시작 응답이 없습니다. 최소화된 PowerShell 창의 오류를 확인하세요.'
}
if($LibraryOnly){return}
$mutex=New-Object Threading.Mutex($false,'Local\EXMailExplorerLaunch')
$owned=$false
try{
 try{$owned=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
 if($owned){Open-EXMail $PSScriptRoot}
}catch{Add-Type -AssemblyName System.Windows.Forms;[void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'EX메일 익스플로러')}finally{if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()}
