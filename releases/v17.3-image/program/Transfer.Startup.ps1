#requires -Version 5.1
function Initialize-TransferWindowNative {
 if('MailTransfer.TopWindows' -as [type]){return}
 Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace MailTransfer { public static class TopWindows {
 delegate bool EnumProc(IntPtr h,IntPtr l);
 [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback,IntPtr l);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h,StringBuilder text,int length);
 [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h,uint command);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int command);
 // Unowned top-level windows of one process whose title contains the text, hidden ones included.
 public static IntPtr[] Find(uint pid,string title){
  List<IntPtr> found=new List<IntPtr>();
  EnumWindows(delegate(IntPtr h,IntPtr l){
   uint owner;GetWindowThreadProcessId(h,out owner);
   if(owner==pid && GetWindow(h,4)==IntPtr.Zero){
    StringBuilder text=new StringBuilder(512);GetWindowText(h,text,text.Capacity);
    if(text.ToString().Contains(title)) found.Add(h);
   }
   return true;
  },IntPtr.Zero);
  return found.ToArray();
 }
}}
'@
}
function Test-TransferExecutable {
 param([string]$Path)
 if([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path) -or [IO.Path]::GetFileName($Path) -ine 'FtcClient.exe' -or -not [IO.File]::Exists($Path)){throw 'TRANSFER_EXECUTABLE_INVALID'}
 return [IO.Path]::GetFullPath($Path)
}
function Save-TransferExecutable {
 param([string]$Path,[string]$Configuration)
 $validated=Test-TransferExecutable $Path
 Write-TransferJson $Configuration @{schemaVersion=1;kind='transfer-launch';executable=$validated}
}
function Find-TransferExecutable {
 # Look only where installers and shortcuts normally point; never scan whole drives.
 $paths=New-Object 'System.Collections.Generic.List[string]'
 foreach($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\FtcClient.exe','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\FtcClient.exe','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\FtcClient.exe')){
  try{$value=[string](Get-ItemProperty -LiteralPath $key -ErrorAction Stop).'(default)';if($value){$paths.Add($value.Trim('"'))}}catch{}
 }
 $shell=$null
 try{
  $shell=New-Object -ComObject WScript.Shell
  $roots=@('CommonStartMenu','StartMenu','CommonDesktopDirectory','DesktopDirectory'|ForEach-Object{[Environment]::GetFolderPath($_)}|Where-Object{$_ -and [IO.Directory]::Exists($_)})
  foreach($link in @(Get-ChildItem -LiteralPath $roots -Filter '*.lnk' -Recurse -File -ErrorAction SilentlyContinue)){
   try{$target=[string]$shell.CreateShortcut($link.FullName).TargetPath;if([IO.Path]::GetFileName($target) -ieq 'FtcClient.exe'){$paths.Add($target)}}catch{}
  }
 }catch{}finally{if($shell){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)}}
 foreach($root in @($env:ProgramFiles,${env:ProgramFiles(x86)}|Where-Object{$_ -and [IO.Directory]::Exists($_)})){
  foreach($file in @(Get-ChildItem -LiteralPath $root -Filter 'FtcClient.exe' -Recurse -Depth 4 -File -ErrorAction SilentlyContinue)){$paths.Add($file.FullName)}
 }
 $valid=@(foreach($path in $paths){try{Test-TransferExecutable $path}catch{}})
 return @($valid|Sort-Object -Unique)
}
function Select-TransferExecutable {
 Add-Type -AssemblyName System.Windows.Forms
 $dialog=New-Object Windows.Forms.OpenFileDialog
 try{
  $dialog.Title='설치된 자료교환 FtcClient.exe를 한 번만 선택하세요'
  $dialog.Filter='자료교환 실행 파일 (FtcClient.exe)|FtcClient.exe'
  $dialog.CheckFileExists=$true;$dialog.Multiselect=$false
  if($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK){throw 'TRANSFER_LAUNCH_NOT_CONFIGURED'}
  return $dialog.FileName
 }finally{$dialog.Dispose()}
}
function Resolve-TransferExecutable {
 param([string]$Configuration)
 if([IO.File]::Exists($Configuration)){
  try{
   $settings=Read-TransferJson $Configuration
   if($settings.schemaVersion -eq 1 -and $settings.kind -ceq 'transfer-launch'){return (Test-TransferExecutable ([string]$settings.executable))}
  }catch{$script:report.Add('Saved transfer executable unusable; searching again')}
 }
 Write-Host '자료교환이 꺼져 있습니다. 설치 위치를 찾습니다.'
 $found=@(Find-TransferExecutable)
 if($found.Count -eq 1){$path=$found[0];$script:report.Add('Transfer executable: found automatically')}
 else{
  Write-Host '설치 위치를 하나로 정하지 못했습니다. 열리는 선택 창에서 FtcClient.exe를 골라주세요.'
  $path=Select-TransferExecutable;$script:report.Add('Transfer executable: selected once by user')
 }
 Save-TransferExecutable $path $Configuration
 return (Test-TransferExecutable $path)
}
function Get-TransferProcesses {return @(Get-Process -Name FtcClient -ErrorAction SilentlyContinue)}
function Get-TransferProcessPath {
 param($Process)
 return [string]$Process.MainModule.FileName
}
function Start-TransferExecutable {
 param([string]$Path)
 [void](Start-Process -FilePath $Path -WorkingDirectory ([IO.Path]::GetDirectoryName($Path)) -PassThru -ErrorAction Stop)
}
function Restore-TransferProcessWindow {
 param($Process)
 # MainWindowHandle is zero while a WinForms client sits hidden in the tray, so enumerate its windows directly.
 Initialize-TransferWindowNative
 $handles=@([MailTransfer.TopWindows]::Find([uint32]$Process.Id,'자료교환'))
 $hidden=@($handles|Where-Object{-not [MailTransfer.TopWindows]::IsWindowVisible($_)})
 if($handles.Count -eq 1 -and $hidden.Count -eq 1){[void][MailTransfer.TopWindows]::ShowWindow($handles[0],5);$script:report.Add('Transfer startup: hidden window shown')}
 elseif($hidden.Count -gt 1){$script:report.Add(('Transfer startup: {0} hidden windows; not guessing which to show' -f $hidden.Count))}
 foreach($handle in @($handles|Where-Object{[MailTransfer.TopWindows]::IsWindowVisible($_)})){[void][MailBridge.Native]::ShowWindowAsync($handle,9)}
 if($handles.Count -eq 0 -and $Process.MainWindowHandle -ne [IntPtr]::Zero){[void][MailBridge.Native]::ShowWindowAsync($Process.MainWindowHandle,9)}
}
function Remember-TransferWindowExecutable {
 param($Window,[string]$Configuration)
 # Failure to inspect an already running process must not interrupt a working transfer.
 try{
  $process=Get-Process -Id $Window.Current.ProcessId -ErrorAction Stop
  Save-TransferExecutable (Get-TransferProcessPath $process) $Configuration
  $script:report.Add('Transfer executable saved: yes')
 }catch{$script:report.Add('Transfer executable saved: no; it will be searched for before a cold start')}
}
function Ensure-TransferWindow {
 param([string]$Configuration,[int]$TimeoutSeconds=60)
 try{
  $window=Get-TransferWindow
  Remember-TransferWindowExecutable $window $Configuration
  $script:report.Add('Transfer startup: already open')
  return $window
 }catch{if($_.Exception.Message -cne 'ONE_TRANSFER_WINDOW_REQUIRED'){throw}}
 $processes=@(Get-TransferProcesses)
 if($processes.Count -eq 0){
  $path=Resolve-TransferExecutable $Configuration
  Start-TransferExecutable $path
  $script:report.Add('Transfer startup: launched once')
  Write-Host '자료교환을 실행했습니다. 전송 창이 준비될 때까지 기다립니다. 자료교환 로그인이 뜨면 직접 로그인하세요.'
 }else{
  $script:report.Add('Transfer startup: existing process; no duplicate launch')
  foreach($process in $processes){Restore-TransferProcessWindow $process}
  Write-Host '실행 중인 자료교환 창을 복원하고 준비를 기다립니다.'
 }
 $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds);$hinted=$false
 do{
  Assert-TransferAbort
  try{
   $window=Get-TransferWindow
   Remember-TransferWindowExecutable $window $Configuration
   $script:report.Add('Transfer startup: window ready')
   return $window
  }catch{if($_.Exception.Message -cne 'ONE_TRANSFER_WINDOW_REQUIRED'){throw}}
  if(-not $hinted -and $deadline.Subtract([DateTime]::UtcNow).TotalSeconds -lt ($TimeoutSeconds-15)){
   Write-Host '아직 자료교환 창이 보이지 않습니다. 트레이에만 있거나 로그인 창이 떠 있으면 직접 열어주세요.';$hinted=$true
  }
  Start-Sleep -Milliseconds 500
 }while([DateTime]::UtcNow -lt $deadline)
 throw 'TRANSFER_WINDOW_STARTUP_TIMEOUT'
}
