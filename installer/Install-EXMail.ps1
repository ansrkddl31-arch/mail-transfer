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
 if((Get-EXMailDigest $bytes)-ne'0de00563366c720e01441e41f61592a9a65254d30a5089619821404f3cfc25fc'){throw '설치 데이터가 손상되었습니다. 다시 다운로드하세요.'}
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
  if($entries.Count-ne34){throw '프로그램 파일 개수가 올바르지 않습니다.'}
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
function New-EXMailShortcut {
 param([string]$Path,[string]$Destination)
 $shell=New-Object -ComObject WScript.Shell
 try{
  $link=$shell.CreateShortcut($Path)
  $link.TargetPath=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $link.Arguments='-NoProfile -STA -ExecutionPolicy RemoteSigned -File "{0}"' -f (Join-Path $Destination 'Launch-EXMail.ps1')
  $link.WorkingDirectory=$Destination
  $link.WindowStyle=7
  $link.Description='EX메일 익스플로러 실행'
  $link.IconLocation=(Join-Path $env:SystemRoot 'System32\shell32.dll')+',14'
  $link.Save()
  if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw '바로가기를 저장하지 못했습니다.'}
 }finally{
  if($link){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link)}
  if($shell){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}
 }
}
function Register-EXMailShortcuts {
 param([string]$Destination,[string]$Desktop,[string]$Startup)
 foreach($folder in @($Desktop,$Startup)){if([string]::IsNullOrWhiteSpace($folder)){throw 'Windows 바탕화면 또는 시작프로그램 경로를 확인하지 못했습니다.'};[void][IO.Directory]::CreateDirectory($folder)}
 New-EXMailShortcut (Join-Path $Desktop 'EX메일 익스플로러.lnk') $Destination
 New-EXMailShortcut (Join-Path $Startup 'EX메일 익스플로러.lnk') $Destination
}
if($LibraryOnly){return}
try{
 if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT){throw '이 설치 파일은 Windows용입니다.'}
 [Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
 $destination='C:\EX메일 익스플로러'
 Write-Host 'EX메일 익스플로러 자동 설치'
 Write-Host '필수: 내부 PC와 외부 PC에 이 설치 파일을 각각 실행해야 합니다.' -ForegroundColor Yellow
 Write-Host ('설치 위치: '+$destination)
 Write-Host '업데이트 전에는 양쪽 PC의 기존 프로그램을 종료하세요.'
 Assert-EXMailStopped
 $data=Get-EXMailBundle $env:EXMAIL_INSTALLER_FILE
 $count=Install-EXMailFiles $data $destination
 # Known folders handle OneDrive and redirected desktops; per-user startup only.
 [IO.File]::WriteAllBytes((Join-Path $destination 'Launch-EXMail.ps1'),[Convert]::FromBase64String('__LAUNCHER_BASE64__'))
 Unblock-File -LiteralPath (Join-Path $destination 'Launch-EXMail.ps1')
 $desktop=[Environment]::GetFolderPath('DesktopDirectory')
 $startup=[Environment]::GetFolderPath('Startup')
 Register-EXMailShortcuts $destination $desktop $startup
 Write-Host ('완료: 프로그램 '+$count+'개 파일 저장·검증, 바탕화면 바로가기, 시작프로그램 등록.') -ForegroundColor Green
 Write-Host '이 Windows 사용자로 로그인하면 자동 실행됩니다. PC 역할·수신 폴더·보내기 초기 설정은 앱에서 확인하세요.'
 Write-Host '바탕화면의 EX메일 익스플로러 바로가기로 실행하세요.'
 Write-Host '자동 실행 해제: Win+R → shell:startup → EX메일 익스플로러 바로가기 삭제.'
 exit 0
}catch{
 Write-Host ('설치를 완료하지 못했습니다: '+$_.Exception.Message) -ForegroundColor Red
 if($_.Exception.GetBaseException()-is[UnauthorizedAccessException]){Write-Host 'C: 또는 바로가기 폴더의 쓰기 권한이 없습니다. 설치 BAT를 우클릭하여 관리자 권한으로 실행하거나 PC 관리자의 권한 설정을 확인하세요.'}
 Write-Host '완료 메시지가 없으면 설치가 끝난 것이 아닙니다. 기존 프로그램을 종료하고 설치를 다시 실행하세요.'
 exit 1
}
