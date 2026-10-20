# Application-owned probe cleanup and newly opened receive-folder window handling.
function ConvertTo-BridgeFolderPath {
 param([string]$Path)
 if([string]::IsNullOrWhiteSpace($Path)){return ''}
 try{$full=[IO.Path]::GetFullPath($Path);if($full.Length-gt[IO.Path]::GetPathRoot($full).Length){$full=$full.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)};return $full}catch{return ''}
}
function Get-BridgeReceiveArtifacts {
 param([string]$Folder)
 if(-not[IO.Directory]::Exists($Folder)){return @()}
 return @(Get-ChildItem -LiteralPath $Folder -File -ErrorAction SilentlyContinue|Where-Object{
  -not($_.Attributes-band[IO.FileAttributes]::ReparsePoint)-and
  $_.Name-match'^(?:MailTransfer-(?:(?:Request|Result|Probe)-[a-f0-9]{32}(?: \([0-9]+\))?\.txt|Attachment-[a-f0-9]{32}(?: \([0-9]+\))?\.[^\\/:*?"<>|]{1,20})|EXMail-ImageTrial-[a-f0-9]{32}(?: \([0-9]+\))?\.txt)$'
 })
}
function Get-BridgeFolderWindows {
 if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT){return @()}
 $shell=$null;$windows=$null;$records=New-Object 'Collections.Generic.List[object]'
 try{
  $shell=New-Object -ComObject Shell.Application;$windows=$shell.Windows()
  for($i=0;$i-lt$windows.Count;$i++){
   $window=$null
   try{
    $window=$windows.Item($i)
    if([IO.Path]::GetFileName([string]$window.FullName)-ine'explorer.exe'){continue}
    $uri=$null
    if(-not[Uri]::TryCreate([string]$window.LocationURL,[UriKind]::Absolute,[ref]$uri)-or-not$uri.IsFile){continue}
    $path=ConvertTo-BridgeFolderPath $uri.LocalPath
    if($path){$records.Add([pscustomobject]@{handle=[long]$window.HWND;path=$path})}
   }catch{}finally{if($window){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($window)}}
  }
 }catch{}finally{if($windows){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($windows)};if($shell){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}}
 return @($records.ToArray())
}
function Close-BridgeReceiveFolderWindow {
 param([long]$Handle,[string]$Path)
 if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT){return $false}
 # Revalidate immediately; never close a window which navigated elsewhere or has several registered tabs.
 $matches=@(Get-BridgeFolderWindows|Where-Object{$_.handle-eq$Handle})
 if($matches.Count-ne1-or-not[string]::Equals($matches[0].path,(ConvertTo-BridgeFolderPath $Path),[StringComparison]::OrdinalIgnoreCase)){return $false}
 if(-not('MailTransfer.FolderTabs'-as[type])){
  Add-Type -TypeDefinition @'
using System;using System.Text;using System.Runtime.InteropServices;
namespace MailTransfer {public static class FolderTabs {
 delegate bool EnumProc(IntPtr h,IntPtr p);
 [DllImport("user32.dll")]static extern bool EnumChildWindows(IntPtr h,EnumProc cb,IntPtr p);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]static extern int GetClassName(IntPtr h,StringBuilder b,int n);
 public static int Count(IntPtr h){int count=0;EnumChildWindows(h,(c,p)=>{var b=new StringBuilder(256);GetClassName(c,b,b.Capacity);if(b.ToString()=="ShellTabWindowClass")count++;return true;},IntPtr.Zero);return count;}
}}
'@
 }
 if([MailTransfer.FolderTabs]::Count([IntPtr]$Handle)-gt1){return $false}
 $shell=$null;$windows=$null;$closed=$false
 try{
  $shell=New-Object -ComObject Shell.Application;$windows=$shell.Windows()
  for($i=0;$i-lt$windows.Count;$i++){
   $window=$null
   try{
    $window=$windows.Item($i)
    if([long]$window.HWND-ne$Handle-or[IO.Path]::GetFileName([string]$window.FullName)-ine'explorer.exe'){continue}
    $uri=$null;if(-not[Uri]::TryCreate([string]$window.LocationURL,[UriKind]::Absolute,[ref]$uri)-or-not$uri.IsFile){continue}
    if(-not[string]::Equals((ConvertTo-BridgeFolderPath $uri.LocalPath),(ConvertTo-BridgeFolderPath $Path),[StringComparison]::OrdinalIgnoreCase)){continue}
    $window.Quit();$closed=$true;break
   }catch{}finally{if($window){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($window)}}
  }
 }catch{}finally{if($windows){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($windows)};if($shell){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}}
 return $closed
}
function Remove-BridgeOwnedProbe {
 param([IO.FileInfo]$File,[DateTime]$Now=[DateTime]::UtcNow)
 try{
  $File.Refresh()
  if(-not$File.Exists-or($File.Attributes-band[IO.FileAttributes]::ReparsePoint)-or$File.Length-lt1-or$File.Length-gt4096-or($Now-$File.LastWriteTimeUtc).TotalSeconds-lt60){return $null}
  $id='';$expected=''
  if($File.Name-cmatch'^MailTransfer-Probe-([a-f0-9]{32})(?: \([0-9]+\))?\.txt$'){
   $id=$Matches[1];$expected=[Text.Encoding]::UTF8.GetString((Get-TransferProbeBytes $id))
  }elseif($File.Name-cmatch'^EXMail-ImageTrial-([a-f0-9]{32})(?: \([0-9]+\))?\.txt$'){
   $id=$Matches[1];$expected="EXMAIL_IMAGE_SEND_TRIAL_V1`r`nID: EXMail-ImageTrial-$id.txt`r`nImage recognition transfer test only. No credentials or mail data."
  }else{return $null}
  $stream=[IO.File]::Open($File.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
  try{$reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true);try{$actual=$reader.ReadToEnd()}finally{$reader.Dispose()}}finally{$stream.Dispose()}
  if($actual-cne$expected){return $null}
  $hash=Get-TransferBytesHash ([IO.File]::ReadAllBytes($File.FullName))
  [IO.File]::Delete($File.FullName)
  return @{id=$id;hash=$hash}
 }catch{return $null}
}
function Invoke-BridgeArtifactMaintenance {
 param($App,[DateTime]$Now=[DateTime]::UtcNow,[scriptblock]$ReadWindows={Get-BridgeFolderWindows},[scriptblock]$CloseWindow={param($Handle,$Path) Close-BridgeReceiveFolderWindow $Handle $Path})
 if($App.role-notin@('Internal','External')){return}
 $state=if($App.role-eq'Internal'){$App.internal}else{$App.external}
 if(-not$state){return};$inbox=ConvertTo-BridgeFolderPath ([string]$state.inbox)
 if(-not$inbox){return}
 $current=@(& $ReadWindows);$files=@(Get-BridgeReceiveArtifacts $inbox)
 $identity=$App.role+'|'+$inbox
 if(-not$App.maintenance-or$App.maintenance.identity-cne$identity){
  $App.maintenance=@{identity=$identity;knownWindows=@{};pendingWindows=@{};files=@{};probeSeen=@{};lastArrival=[DateTime]::MinValue;lastCleanup=[DateTime]::MinValue}
  foreach($window in $current){$App.maintenance.knownWindows[[string]$window.handle]=$true}
  foreach($file in $files){$App.maintenance.files[$file.Name]=$file.LastWriteTimeUtc.Ticks.ToString()+':'+$file.Length}
 }
 $m=$App.maintenance
 foreach($file in $files){
  $stamp=$file.LastWriteTimeUtc.Ticks.ToString()+':'+$file.Length
  if(-not$m.files.ContainsKey($file.Name)-or$m.files[$file.Name]-cne$stamp){$m.lastArrival=$Now;$m.files[$file.Name]=$stamp}
 }
 foreach($group in @($current|Group-Object handle)){
  $window=$group.Group[0];$key=[string]$window.handle
  if(-not$m.knownWindows.ContainsKey($key)){$m.knownWindows[$key]=$true;$m.pendingWindows[$key]=$Now}
  if($group.Count-ne1-or-not$m.pendingWindows.ContainsKey($key)){continue}
  if(($Now-$m.pendingWindows[$key]).TotalSeconds-gt20){$m.pendingWindows.Remove($key);continue}
  if(-not[string]::Equals((ConvertTo-BridgeFolderPath $window.path),$inbox,[StringComparison]::OrdinalIgnoreCase)){continue}
  if(($Now-$m.lastArrival).TotalSeconds-gt15-or$m.pendingWindows[$key]-lt$m.lastArrival.AddSeconds(-5)){continue}
  try{if(& $CloseWindow $window.handle $inbox){$m.pendingWindows.Remove($key)}}catch{}
 }
 if(($Now-$m.lastCleanup).TotalSeconds-lt10){return};$m.lastCleanup=$Now
 if($state.busy-or$state.connecting-or$state.sending-or$state.activeSend-or($state.sendQueue-and$state.sendQueue.Count-gt0)-or($state.phase-and$state.phase-ne'idle')){return}
 $locks=New-Object 'Collections.Generic.List[object]'
 try{
  # Never delete a probe while either the app sender or standalone trial is using it.
  foreach($name in @('Local\MailTransferScreenSender','Local\EXMailImageSendTrial')){
   $mutex=New-Object Threading.Mutex($false,$name);$owned=$false
   try{$owned=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
   if(-not$owned){$mutex.Dispose();return};$locks.Add($mutex)
  }
  if($App.setupJob-and-not$App.setupJob.process.HasExited){return}
  foreach($folder in @($inbox,(ConvertTo-BridgeFolderPath $App.stateDir),(Join-Path $App.stateDir 'outbox'))|Select-Object -Unique){
   if(-not[IO.Directory]::Exists($folder)){continue}
   foreach($file in @(Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue)){
    if($file.Name-cnotmatch'^(?:MailTransfer-Probe|EXMail-ImageTrial)-[a-f0-9]{32}(?: \([0-9]+\))?\.txt$'){continue}
    $key=$file.FullName;$stamp=$file.LastWriteTimeUtc.Ticks.ToString()+':'+$file.Length
    if(-not$m.probeSeen.ContainsKey($key)-or$m.probeSeen[$key].stamp-cne$stamp){$m.probeSeen[$key]=@{stamp=$stamp;seen=$Now}}
    if(($Now-$m.probeSeen[$key].seen).TotalSeconds-lt60){continue}
    $removed=Remove-BridgeOwnedProbe $file $Now
    if($removed-and[string]::Equals((ConvertTo-BridgeFolderPath $folder),$inbox,[StringComparison]::OrdinalIgnoreCase)){
     Write-BridgeJson (Join-Path $App.stateDir 'last-probe-receipt.json') @{schemaVersion=1;id=$removed.id;hash=$removed.hash;received=$true;cleanedAt=$Now.ToString('o')}
    }
   }
  }
 }catch{}finally{foreach($mutex in $locks){$mutex.ReleaseMutex();$mutex.Dispose()}}
}
