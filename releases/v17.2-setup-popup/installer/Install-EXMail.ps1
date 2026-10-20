param([switch]$LibraryOnly)
$ErrorActionPreference='Stop'
function Get-EXMailDigest {
 param([byte[]]$Bytes)
 $sha=[Security.Cryptography.SHA256]::Create()
 try{return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Get-EXMailBundle {
 param([string]$InstallerPath)
 $raw=[IO.File]::ReadAllText($InstallerPath)
 $m=[regex]::Match($raw,'(?m)^::EXMAIL_ZIP:([A-Za-z0-9+/=]+)\r?$')
 if(-not$m.Success){throw '설치 파일의 프로그램 데이터를 찾지 못했습니다. 다시 다운로드하세요.'}
 $bytes=[Convert]::FromBase64String($m.Groups[1].Value)
 if((Get-EXMailDigest $bytes)-ne'__BUNDLE_SHA256__'){throw '설치 데이터가 손상되었습니다. 다시 다운로드하세요.'}
 return ,$bytes
}
function Install-EXMailFiles {
 param([byte[]]$Bundle,[string]$Destination)
 Add-Type -AssemblyName System.IO.Compression
 $stream=New-Object IO.MemoryStream(,$Bundle)
 $archive=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Read)
 $stage=$null
 try{
  $entries=@($archive.Entries)
  if($entries.Count-ne__PAYLOAD_COUNT__){throw '프로그램 파일 개수가 올바르지 않습니다.'}
  $names=@{}
  foreach($entry in $entries){
   if($entry.FullName-cnotmatch'^EX메일 익스플로러/([^/\\]+)$'){throw '설치 파일 경로가 올바르지 않습니다.'}
   $name=$Matches[1]
   if($name-in@('.','..')-or$name.Contains(':')-or$names.ContainsKey($name)){throw '설치 파일 이름이 올바르지 않습니다.'}
   $names[$name]=$true
  }
  if(-not$names.ContainsKey('시작.bat')){throw '시작 파일이 없습니다.'}
  [void][IO.Directory]::CreateDirectory($Destination)
  $stage=Join-Path $Destination ('.install-'+[guid]::NewGuid().ToString('N'))
  [void][IO.Directory]::CreateDirectory($stage)
  foreach($entry in $entries){
   $name=$entry.Name;$target=Join-Path $stage $name;$entryStream=$entry.Open();$output=[IO.File]::Create($target)
   try{$entryStream.CopyTo($output)}finally{$output.Dispose();$entryStream.Dispose()}
   if((Get-Item -LiteralPath $target).Length-ne$entry.Length){throw ('파일 저장 확인 실패: '+$name)}
  }
  foreach($entry in $entries){
   $name=$entry.Name;$source=Join-Path $stage $name;$target=Join-Path $Destination $name
   [IO.File]::Copy($source,$target,$true)
   if((Get-EXMailDigest ([IO.File]::ReadAllBytes($source)))-ne(Get-EXMailDigest ([IO.File]::ReadAllBytes($target)))){throw ('파일 검증 실패: '+$name)}
   if([Environment]::OSVersion.Platform-eq[PlatformID]::Win32NT){Unblock-File -LiteralPath $target}
  }
  return $entries.Count
 }finally{
  $archive.Dispose();$stream.Dispose()
  if($stage-and(Test-Path -LiteralPath $stage)){Remove-Item -LiteralPath $stage -Recurse -Force}
 }
}
function Assert-EXMailStopped {
 $client=New-Object Net.Sockets.TcpClient
 try{
  $pending=$client.BeginConnect('127.0.0.1',8765,$null,$null)
  if($pending.AsyncWaitHandle.WaitOne(600)){
   try{$client.EndConnect($pending)}catch{return}
   if($client.Connected){throw '기존 프로그램이 실행 중입니다. 기존 EX메일 PowerShell 창을 종료하고 설치 BAT를 다시 실행하세요. 브라우저 탭만 닫으면 프로그램은 계속 실행됩니다.'}
  }
 }finally{$client.Dispose()}
}
function Get-EXMailLauncherBytes {return ,[Convert]::FromBase64String('__LAUNCHER_BASE64__')}
function Test-EXMailFiles {
 param([byte[]]$Bundle,[string]$Destination)
 $stream=New-Object IO.MemoryStream(,$Bundle);Add-Type -AssemblyName System.IO.Compression
 $zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Read)
 try{
  foreach($entry in $zip.Entries){
   $path=Join-Path $Destination $entry.Name
   if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $false}
   $info=Get-Item -LiteralPath $path
   if(($info.Attributes-band[IO.FileAttributes]::ReparsePoint)-or$info.Length-ne$entry.Length){return $false}
   $inputStream=$entry.Open();$memory=New-Object IO.MemoryStream
   try{$inputStream.CopyTo($memory);if((Get-EXMailDigest $memory.ToArray())-cne(Get-EXMailDigest ([IO.File]::ReadAllBytes($path)))){return $false}}finally{$inputStream.Dispose();$memory.Dispose()}
  }
  $launcher=Join-Path $Destination 'Launch-EXMail.ps1'
  if(-not(Test-Path -LiteralPath $launcher -PathType Leaf)){return $false}
  return (Get-EXMailDigest ([IO.File]::ReadAllBytes($launcher)))-ceq(Get-EXMailDigest (Get-EXMailLauncherBytes))
 }finally{$zip.Dispose();$stream.Dispose()}
}
function New-EXMailShortcut {
 param([string]$Path,[string]$RecoveryBatch)
 $shell=New-Object -ComObject WScript.Shell;$link=$null
 try{
  $link=$shell.CreateShortcut($Path)
  $link.TargetPath=Join-Path $env:SystemRoot 'System32\cmd.exe'
  $link.Arguments='/d /c ""{0}" /launch"' -f $RecoveryBatch
  $link.WorkingDirectory=Split-Path -Parent $RecoveryBatch
  $link.WindowStyle=7;$link.Description='EX메일 익스플로러 복구·실행';$link.IconLocation=(Join-Path $env:SystemRoot 'System32\shell32.dll')+',14'
  $link.Save();if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw '바로가기를 저장하지 못했습니다.'}
 }finally{if($link){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link)};[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}
}
function Register-EXMailRecovery {
 param([string]$InstallerPath,[string]$Destination,[string]$Desktop,[string]$Startup)
 if(-not$Desktop-or-not$Startup){throw 'Windows 바탕화면/시작프로그램 경로를 확인할 수 없습니다.'}
 $Startup=[IO.Path]::GetFullPath($Startup).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
 foreach($dir in @($Desktop,$Startup)){[void][IO.Directory]::CreateDirectory($dir)}
 $batch=Join-Path $Startup 'EXMail-Recover.bat'
 if(-not[string]::Equals([IO.Path]::GetFullPath($InstallerPath),[IO.Path]::GetFullPath($batch),[StringComparison]::OrdinalIgnoreCase)){
  $stagingFolder=Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Startup))) 'EXMailRecovery';[void][IO.Directory]::CreateDirectory($stagingFolder)
  $temp=Join-Path $stagingFolder ('recovery-'+[guid]::NewGuid().ToString('N')+'.tmp')
  try{[IO.File]::Copy($InstallerPath,$temp,$true);if(Test-Path -LiteralPath $batch){[IO.File]::Replace($temp,$batch,[NullString]::Value)}else{[IO.File]::Move($temp,$batch)}}finally{if(Test-Path -LiteralPath $temp){[IO.File]::Delete($temp)}}
 }
 if([Environment]::OSVersion.Platform-eq[PlatformID]::Win32NT){Unblock-File -LiteralPath $batch}
 # One startup entry, not both an old launcher shortcut and a recovery BAT.
 $old=Join-Path $Startup 'EX메일 익스플로러.lnk';if(Test-Path -LiteralPath $old){[IO.File]::Delete($old)}
 New-EXMailShortcut (Join-Path $Desktop 'EX메일 익스플로러.lnk') $batch
 return $batch
}
function Write-EXMailInstallError {
 param([string]$Code)
 try{
  $folder=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'MailTransferBridge\logs';[void][IO.Directory]::CreateDirectory($folder)
  if($Code-cnotmatch'^[A-Za-z0-9_]{1,100}$'){$Code='INSTALL_FAILED'}
  [IO.File]::AppendAllText((Join-Path $folder ('errors-'+(Get-Date -Format yyyyMMdd)+'.jsonl')),((@{at=[DateTime]::UtcNow.ToString('o');stage='INSTALL_OR_RECOVERY';code=$Code}|ConvertTo-Json -Compress)+"`r`n"),(New-Object Text.UTF8Encoding($false)))
 }catch{}
}
function Invoke-EXMailInstall {
 param([string]$InstallerPath,[string]$Destination,[string]$Desktop,[string]$Startup,[ValidateSet('Install','Startup','Launch')][string]$Mode='Install',[scriptblock]$OpenApplication=$null)
 $bundle=Get-EXMailBundle $InstallerPath
 if($Mode-eq'Install'-or-not(Test-EXMailFiles $bundle $Destination)){
  Assert-EXMailStopped
  $count=Install-EXMailFiles $bundle $Destination
  [IO.File]::WriteAllBytes((Join-Path $Destination 'Launch-EXMail.ps1'),(Get-EXMailLauncherBytes))
  if([Environment]::OSVersion.Platform-eq[PlatformID]::Win32NT){Unblock-File -LiteralPath (Join-Path $Destination 'Launch-EXMail.ps1')}
 }
 if($Mode-eq'Install'){
  [void](Register-EXMailRecovery $InstallerPath $Destination $Desktop $Startup)
 }
 # Backend is ready before opening the local EX메일 page; the launcher does not navigate to webmail or start a connection test.
 . (Join-Path $Destination 'Launch-EXMail.ps1') -LibraryOnly
 if($OpenApplication){& $OpenApplication $Destination}else{Open-EXMail $Destination}
}
if($LibraryOnly){return}
$mutex=$null;$owned=$false
try{
 if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT){throw '이 설치 파일은 Windows용입니다.'}
 [Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
 $mutex=New-Object Threading.Mutex($false,'Local\EXMailExplorerInstallRecovery')
 try{$owned=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
 if(-not$owned){throw '다른 설치·복구 작업이 실행 중입니다.'}
 $mode=if($env:EXMAIL_INSTALL_MODE-in@('Startup','Launch')){$env:EXMAIL_INSTALL_MODE}else{'Install'}
 Write-Host 'EX메일 익스플로러 v17.2 시작프로그램 수정3 · 내부·외부 PC에 각각 설치하세요.'
 Invoke-EXMailInstall $env:EXMAIL_INSTALLER_FILE 'C:\EX메일 익스플로러' ([Environment]::GetFolderPath('DesktopDirectory')) ([Environment]::GetFolderPath('Startup')) $mode
 Write-Host '완료: 설치·복구 확인 후 EX메일 화면을 열었습니다.' -ForegroundColor Green
 Write-Host '시작프로그램: EXMail-Recover.bat / 자동 실행 해제: Win+R → shell:startup → 해당 BAT 삭제'
 exit 0
}catch{
 Write-EXMailInstallError $_.Exception.GetType().Name
 $message='설치·복구를 완료하지 못했습니다: '+$_.Exception.Message
 Write-Host $message -ForegroundColor Red
 if($env:EXMAIL_INSTALL_MODE-in@('Startup','Launch')){Add-Type -AssemblyName System.Windows.Forms;[void][Windows.Forms.MessageBox]::Show($message,'EX메일 익스플로러 복구 실패')}
 exit 1
}finally{if($owned){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}}
