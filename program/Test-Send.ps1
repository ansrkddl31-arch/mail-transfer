#requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('Calibrate','Send')][string]$Mode='Calibrate',[string]$SettingsPath='',[string]$ReportDirectory='',[string]$TargetInbox='D:\FTC_downloads',[switch]$LibraryOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'InputGuard.ps1')
# Resolve defaults after parameter binding for Windows PowerShell 5.1.
# Do not rely on an automatic script-root variable inside default expressions.
$scriptFile=[string]$MyInvocation.MyCommand.Path
if([string]::IsNullOrWhiteSpace($scriptFile)){$scriptFile=[string]$PSCommandPath}
if([string]::IsNullOrWhiteSpace($scriptFile)){throw 'SCRIPT_DIRECTORY_UNAVAILABLE'}
$scriptDirectory=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($scriptFile))
if([string]::IsNullOrWhiteSpace($ReportDirectory)){$ReportDirectory=$scriptDirectory}
if([string]::IsNullOrWhiteSpace($SettingsPath)){$SettingsPath=Join-Path $scriptDirectory 'sender-settings.json'}
. (Join-Path $scriptDirectory 'Transfer.TestCore.ps1')
. (Join-Path $scriptDirectory 'Transfer.Helpers.ps1')
. (Join-Path $scriptDirectory 'Transfer.Startup.ps1')
. (Join-Path $scriptDirectory 'KeepAwake.ps1')
$TransferBuild='batch-v5'
$TransferMutexName='Local\MailTransferScreenSender'
function Initialize-TransferDesktop {
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'WINDOWS_REQUIRED'}
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
if(-not ('MailBridge.Native' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace MailBridge {
 [StructLayout(LayoutKind.Sequential)] public struct Point { public int X; public int Y; }
 public static class Native {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out Point p);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
  [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr h,int n);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a,uint b,bool attach);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h,uint flag);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int key);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags,uint x,uint y,uint data,UIntPtr extra);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(Point p);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h,uint msg,IntPtr w,IntPtr l);
  [DllImport("user32.dll")] public static extern void keybd_event(byte key,byte scan,uint flags,UIntPtr extra);
 }
}
'@
}
[void][MailBridge.Native]::SetThreadDpiAwarenessContext([IntPtr](-4))
[void][MailBridge.Native]::GetAsyncKeyState(27)

}
function Assert-TransferAbort {
 if(Get-Command Assert-MailOperationContinue -ErrorAction SilentlyContinue){Assert-MailOperationContinue}
 if(([MailBridge.Native]::GetAsyncKeyState(27) -band 0x8001) -ne 0){throw 'USER_ABORTED'}
}
function Get-TransferWindow {
 $windows=[System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.Condition]::TrueCondition)
 $found=@()
 foreach($window in $windows){try{
  $info=$window.Current
  if($info.Name -notmatch '자료교환' -or $info.IsOffscreen -or $info.BoundingRectangle.Width -lt 200){continue}
  if((Get-Process -Id $info.ProcessId).ProcessName -ieq 'FtcClient'){$found+=,$window}
 }catch{}}
 if($found.Count -ne 1){throw 'ONE_TRANSFER_WINDOW_REQUIRED'}
 return $found[0]
}
function Focus-TransferWindow {
 param($Window)
 $handle=[IntPtr]$Window.Current.NativeWindowHandle
 $foreground=[MailBridge.Native]::GetForegroundWindow(); $pidIgnored=[uint32]0
 $foregroundThread=[MailBridge.Native]::GetWindowThreadProcessId($foreground,[ref]$pidIgnored)
 $thread=[MailBridge.Native]::GetCurrentThreadId()
 $attached=$false
 try{
  if($foregroundThread -ne 0 -and $foregroundThread -ne $thread){$attached=[MailBridge.Native]::AttachThreadInput($thread,$foregroundThread,$true)}
  [void][MailBridge.Native]::ShowWindowAsync($handle,9)
  [void][MailBridge.Native]::SetForegroundWindow($handle)
 }finally{if($attached){[void][MailBridge.Native]::AttachThreadInput($thread,$foregroundThread,$false)}}
 Start-Sleep -Milliseconds 400
 if([MailBridge.Native]::GetForegroundWindow() -ne $handle){
  # Windows refuses foreground changes from a background console unless a key event came first.
  # A bare Alt tap satisfies that rule and types nothing.
  [MailBridge.Native]::keybd_event(0x12,0,0,[UIntPtr]::Zero);[MailBridge.Native]::keybd_event(0x12,0,2,[UIntPtr]::Zero)
  [void][MailBridge.Native]::SetForegroundWindow($handle)
  Start-Sleep -Milliseconds 400
 }
 Assert-TransferAbort
 if([MailBridge.Native]::GetForegroundWindow() -ne $handle){throw 'TRANSFER_WINDOW_NOT_FOREGROUND'}
}
function Get-ForegroundDescription {
 $handle=[MailBridge.Native]::GetForegroundWindow();$owner=[uint32]0
 [void][MailBridge.Native]::GetWindowThreadProcessId($handle,[ref]$owner)
 $name='';$title=''
 try{$name=(Get-Process -Id $owner -ErrorAction Stop).ProcessName}catch{}
 try{$title=[System.Windows.Automation.AutomationElement]::FromHandle($handle).Current.Name}catch{}
 return [pscustomobject]@{handle=$handle;processId=[int]$owner;process=$name;title=$title}
}
function Wait-TransferForeground {
 # A receive notice from i-oneNet, or a file dialog left by an interrupted run, can hold the foreground.
 # Wait for it, retry raising the window, and record what was in front so the report shows the blocker.
 param($Window,[int]$Seconds=15)
 $handle=[IntPtr]$Window.Current.NativeWindowHandle
 $deadline=[DateTime]::UtcNow.AddSeconds($Seconds);$seen=@{};$lastRaise=[DateTime]::MinValue
 while($true){
  Assert-TransferAbort
  if([MailBridge.Native]::GetForegroundWindow() -eq $handle){return}
  $front=Get-ForegroundDescription
  $key=$front.process+'|'+$front.title
  if(-not $seen.ContainsKey($key)){$seen[$key]=$true;$script:report.Add(('Foreground held by: process={0}; title={1}' -f $front.process,$front.title))}
  if($front.processId -eq $Window.Current.ProcessId -and $front.title -in @('파일 선택','열기','파일 열기','Open','Select File')){
   # Only a file dialog of the transfer client is closed, as Cancel. Nothing is registered or sent.
   [void][MailBridge.Native]::PostMessage($front.handle,0x10,[IntPtr]::Zero,[IntPtr]::Zero)
   $script:report.Add('Leftover file dialog closed (cancel)');Start-Sleep -Milliseconds 800
  }
  if([DateTime]::UtcNow -ge $deadline){throw 'TRANSFER_WINDOW_NOT_FOREGROUND'}
  if(([DateTime]::UtcNow-$lastRaise).TotalSeconds -ge 2){
   $lastRaise=[DateTime]::UtcNow
   try{Focus-TransferWindow $Window;$script:report.Add('Transfer window raised again');return}catch{if($_.Exception.Message -cne 'TRANSFER_WINDOW_NOT_FOREGROUND'){throw}}
  }
  Start-Sleep -Milliseconds 300
 }
}
function Get-SenderHash {
 param($Window)
 $r=$Window.Current.BoundingRectangle
 $x=[int]($r.Left+$r.Width*.07);$y=[int]($r.Top+$r.Height*.20)
 $w=[int]($r.Width*.86);$h=[int]($r.Height*.55)
 $bitmap=New-Object Drawing.Bitmap($w,$h)
 $graphics=[Drawing.Graphics]::FromImage($bitmap);$stream=New-Object IO.MemoryStream
 $sha=[Security.Cryptography.SHA256]::Create()
 try{
  $graphics.CopyFromScreen($x,$y,0,0,$bitmap.Size)
  $bitmap.Save($stream,[Drawing.Imaging.ImageFormat]::Png)
  return ([BitConverter]::ToString($sha.ComputeHash($stream.ToArray()))).Replace('-','')
 }finally{$sha.Dispose();$stream.Dispose();$graphics.Dispose();$bitmap.Dispose()}
}
function Get-ControlPoint {
 param($Window,[string]$Instruction)
 Wait-TransferForeground $Window
 Write-Host $Instruction
 Write-Host '자료교환 창을 앞으로 띄웠습니다. 12초 안에 해당 버튼 위에 마우스만 올려두세요. 클릭하지 마세요.'
 for($n=12;$n -gt 0;$n--){Assert-TransferAbort;Write-Host "$n...";Start-Sleep -Seconds 1}
 $handle=[IntPtr]$Window.Current.NativeWindowHandle
 Assert-TransferAbort
 # Focus can drift back to the console during the countdown. Re-raising the window does not move the cursor the user placed.
 if([MailBridge.Native]::GetForegroundWindow() -ne $handle){$script:report.Add('Calibration: window re-raised after countdown');Wait-TransferForeground $Window}
 $r=$Window.Current.BoundingRectangle
 $point=New-Object MailBridge.Point
 [void][MailBridge.Native]::GetCursorPos([ref]$point)
 if($point.X -le $r.Left -or $point.X -ge $r.Right -or $point.Y -le $r.Top -or $point.Y -ge $r.Bottom){throw 'CONTROL_POINT_OUTSIDE_WINDOW'}
 $hit=[System.Windows.Automation.AutomationElement]::FromPoint([System.Windows.Point]::new($point.X,$point.Y))
 if($hit.Current.ProcessId -ne $Window.Current.ProcessId){throw 'CONTROL_POINT_OCCLUDED'}
 return [pscustomobject]@{x=($point.X-$r.Left)/$r.Width;y=($point.Y-$r.Top)/$r.Height;width=$r.Width;height=$r.Height}
}
function Invoke-TransferPoint {
 param($Window,$Point)
 $r=$Window.Current.BoundingRectangle;$handle=[IntPtr]$Window.Current.NativeWindowHandle
 if([Math]::Abs($r.Width-$Point.width) -gt 3 -or [Math]::Abs($r.Height-$Point.height) -gt 3){throw 'TRANSFER_WINDOW_SIZE_CHANGED'}
 Wait-TransferForeground $Window
 $x=[int]($r.Left+$r.Width*$Point.x);$y=[int]($r.Top+$r.Height*$Point.y)
 # The point must belong to the main transfer window itself, not to a notice window of the same program.
 $p=New-Object MailBridge.Point;$p.X=$x;$p.Y=$y
 if([MailBridge.Native]::GetAncestor([MailBridge.Native]::WindowFromPoint($p),2) -ne $handle){throw 'CONTROL_POINT_OCCLUDED'}
 if(-not (Set-TransferCursorPosition $x $y)){throw 'CURSOR_MOVE_FAILED'}
 [MailBridge.Native]::mouse_event(2,0,0,0,[UIntPtr]::Zero);[MailBridge.Native]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
}
function Register-TransferFile {
 param($Window,$Plus,[string]$Path)
 Invoke-TransferPoint $Window $Plus
 $deadline=[DateTime]::UtcNow.AddSeconds(15);$dialog=$null
 do{
  $handle=[MailBridge.Native]::GetForegroundWindow()
  if($handle -ne [IntPtr]$Window.Current.NativeWindowHandle -and $handle -ne [IntPtr]::Zero){
   $candidate=[System.Windows.Automation.AutomationElement]::FromHandle($handle);$info=$candidate.Current
   if($info.ProcessId -eq $Window.Current.ProcessId -and ($info.ClassName -eq '#32770' -or $info.Name -in @('파일 선택','열기','파일 열기','Open','Select File'))){$dialog=$candidate;break}
  }
  Assert-TransferAbort;Start-Sleep -Milliseconds 200
 }while([DateTime]::UtcNow -lt $deadline)
 if($null -eq $dialog){
  $front=Get-ForegroundDescription
  $script:report.Add(('No file dialog; foreground: process={0}; title={1}' -f $front.process,$front.title))
  throw 'FILE_DIALOG_NOT_OPENED'
 }
 $dialogHandle=[IntPtr]$dialog.Current.NativeWindowHandle
 try{
  Set-FileDialogProbePath $dialog $Path
  Invoke-FileDialogOpen $dialog;$deadline=[DateTime]::UtcNow.AddSeconds(10)
  while((Test-FileDialogStillVisible $dialogHandle) -and [DateTime]::UtcNow -lt $deadline){Assert-TransferAbort;Start-Sleep -Milliseconds 200}
  if(Test-FileDialogStillVisible $dialogHandle){throw 'FILE_DIALOG_DID_NOT_CLOSE'}
 }catch{
  # Never leave the dialog hanging open: cancel it so the next run starts clean. Nothing has been sent.
  if(Test-FileDialogStillVisible $dialogHandle){
   [void][MailBridge.Native]::PostMessage($dialogHandle,0x10,[IntPtr]::Zero,[IntPtr]::Zero)
   $script:report.Add('File dialog cancelled after failure')
  }
  throw
 }
 Start-Sleep -Milliseconds 500
}
function Wait-SenderReset {
 param($Window,[string]$ExpectedHash,[string]$FileName='',[bool]$FileWasListed=$false)
 $deadline=[DateTime]::UtcNow.AddSeconds(20)
 do{
  if([MailBridge.Native]::GetForegroundWindow() -eq [IntPtr]$Window.Current.NativeWindowHandle){
   $r=$Window.Current.BoundingRectangle;[void](Set-TransferCursorPosition ([int]$r.Left) ([int]$r.Top))
   Start-Sleep -Milliseconds 300
   if((Get-SenderHash $Window) -ceq $ExpectedHash){$script:report.Add('Send list reset: empty-list image matched');return}
  }
  # A notification or popup can change pixels or take focus. If the file name was visible in the list before
  # sending, its disappearance (with no file count left) is accepted as the same evidence.
  if($FileWasListed -and $FileName){
   $evidence=Get-RegistrationEvidence $Window $FileName
   if(-not $evidence.FileSeen -and -not $evidence.OneFileSeen){$script:report.Add('Send list reset: registered file name no longer listed (image differed)');return}
  }
  Assert-TransferAbort;Start-Sleep -Milliseconds 200
 }while([DateTime]::UtcNow -lt $deadline)
 throw 'TRANSFER_SUBMISSION_UNCONFIRMED'
}
function Get-TransferLayout {
 param($Window)
 $info=$Window.Current
 $version=(Get-Process -Id $info.ProcessId -ErrorAction Stop).MainModule.FileVersionInfo.FileVersion
 return [pscustomobject]@{version=$version;dpi=[MailBridge.Native]::GetDpiForWindow([IntPtr]$info.NativeWindowHandle)}
}
function Get-SendButtonHash {
 param($Window,$Point)
 $r=$Window.Current.BoundingRectangle
 $x=[int]($r.Left+$r.Width*$Point.x)-24;$y=[int]($r.Top+$r.Height*$Point.y)-10
 if($x -lt $r.Left -or $y -lt $r.Top -or ($x+48) -gt $r.Right -or ($y+20) -gt $r.Bottom){throw 'SEND_POINT_NEAR_WINDOW_EDGE'}
 $bitmap=New-Object Drawing.Bitmap(48,20);$graphics=[Drawing.Graphics]::FromImage($bitmap);$stream=New-Object IO.MemoryStream
 $sha=[Security.Cryptography.SHA256]::Create()
 try{
  $graphics.CopyFromScreen($x,$y,0,0,$bitmap.Size);$bitmap.Save($stream,[Drawing.Imaging.ImageFormat]::Png)
  return ([BitConverter]::ToString($sha.ComputeHash($stream.ToArray()))).Replace('-','')
 }finally{$sha.Dispose();$stream.Dispose();$graphics.Dispose();$bitmap.Dispose()}
}
function Move-TransferCursorAway {
 param($Window)
 Assert-TransferAbort
 Wait-TransferForeground $Window
 $r=$Window.Current.BoundingRectangle
 if(-not (Set-TransferCursorPosition ([int]$r.Left) ([int]$r.Top))){throw 'CURSOR_MOVE_FAILED'}
 Start-Sleep -Milliseconds 400
}
function Confirm-EmptyTransferList {
 [void](Read-Host '자료교환의 보내기 목록을 비워두세요. 빈 목록이면 Enter를 누르세요')
}
function Confirm-SoleTransferProbe {
 param([string]$Name)
 Write-Host ('등록 목록에는 '+$Name+' 한 개만 있어야 합니다.')
 [void](Read-Host '테스트 TXT 1개만 있으면 Enter를 누르세요. 다른 파일이면 Ctrl+C로 중단하세요')
}
function Get-TransferLaunchPath {
 param([string]$Configuration)
 return (Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Configuration))) 'transfer-launch.json')
}
function Get-TransferErrorCode {
 param($ErrorRecord)
 if($ErrorRecord.Exception.Message -cmatch '^[A-Z][A-Z0-9_]+$'){return $ErrorRecord.Exception.Message}
 return ('UNEXPECTED_'+$ErrorRecord.Exception.GetType().Name)
}
function Write-TransferHint {
 param([string]$Code)
 $hints=@{
  'TRANSFER_LAUNCH_NOT_CONFIGURED'='자료교환 실행 파일(FtcClient.exe)을 선택하지 않아 자료교환을 켤 수 없습니다.'
  'TRANSFER_WINDOW_STARTUP_TIMEOUT'='자료교환 창을 찾지 못했습니다. 로그인·오류 창이 떠 있거나 트레이에만 있으면 창을 직접 열어주세요.'
  'TRANSFER_WINDOW_NOT_FOREGROUND'='자료교환 창을 앞으로 띄우지 못했습니다. 다른 창이 가리지 않게 하고 다시 실행하세요.'
  'TRANSFER_SENDER_NOT_EMPTY_OR_LAYOUT_CHANGED'='보내기 목록이 비어 있지 않거나 화면 배치가 바뀌었습니다. 목록을 비우고 다시 실행하세요.'
  'CLIENT_VERSION_OR_DPI_CHANGED'='자료교환 버전이나 화면 배율이 바뀌어 버튼 위치를 다시 지정해야 합니다.'
  'TRANSFER_WINDOW_SIZE_CHANGED'='자료교환 창 크기가 바뀌어 버튼 위치를 다시 지정해야 합니다.'
  'TRANSFER_CALIBRATION_REQUIRED'='이 PC의 버튼 위치 설정이 없습니다.'
  'ANOTHER_TRANSFER_IS_RUNNING'='다른 전송 자동화가 실행 중입니다. 끝난 뒤 다시 실행하세요.'
  'USER_ABORTED'='ESC로 중단했습니다.'
 }
 if($hints.ContainsKey($Code)){Write-Host $hints[$Code]}
}
function Save-TransferReport {
 param($Lines,[string]$Folder,[string]$Prefix)
 [void][IO.Directory]::CreateDirectory($Folder)
 $path=Join-Path $Folder ($Prefix+'-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,6)+'.txt')
 [IO.File]::WriteAllLines($path,$Lines,(New-Object Text.UTF8Encoding($true)))
 return $path
}
function Assert-TransferLayout {
 param($Window,$Settings)
 $layout=Get-TransferLayout $Window
 if($Settings.clientVersion -cne $layout.version -or [int]$Settings.dpi -ne [int]$layout.dpi){throw 'CLIENT_VERSION_OR_DPI_CHANGED'}
 Wait-TransferForeground $Window;Move-TransferCursorAway $Window
 $r=$Window.Current.BoundingRectangle
 if([Math]::Abs($r.Width-$Settings.plus.width) -gt 3 -or [Math]::Abs($r.Height-$Settings.plus.height) -gt 3){throw 'TRANSFER_WINDOW_SIZE_CHANGED'}
 if((Get-SenderHash $Window) -cne $Settings.emptyHash){throw 'TRANSFER_SENDER_NOT_EMPTY_OR_LAYOUT_CHANGED'}
}
function Invoke-CalibratedSend {
 # Registers one existing file and presses the calibrated send button at most once.
 param($Window,$Settings,[string]$Path,[hashtable]$State)
 $name=[IO.Path]::GetFileName($Path)
 $State.stage='REGISTER_FILE'
 Register-TransferFile $Window $Settings.plus $Path
 Move-TransferCursorAway $Window
 if((Get-SenderHash $Window) -ceq $Settings.emptyHash){throw 'REGISTRATION_NOT_CONFIRMED'}
 $evidence=Get-RegistrationEvidence $Window $name
 $script:report.Add(('Registered filename evidence: {0}; one-file count evidence: {1}' -f $evidence.FileSeen,$evidence.OneFileSeen))
 if($Settings.requireFileEvidence -and -not $evidence.FileSeen){throw 'REGISTERED_FILENAME_NOT_CONFIRMED'}
 if($Settings.requireCountEvidence -and -not $evidence.OneFileSeen){throw 'ONE_REGISTERED_FILE_NOT_CONFIRMED'}
 if((Get-SendButtonHash $Window $Settings.send) -cne $Settings.sendButtonHash){throw 'SEND_BUTTON_STATE_CHANGED'}
 $State.stage='CLICK_SEND_ONCE'
 Invoke-TransferPoint $Window $Settings.send;$State.clicked=$true
 $State.stage='WAIT_EMPTY_SEND_LIST'
 Wait-SenderReset $Window $Settings.emptyHash $name $evidence.FileSeen
}
function Send-TransferFile {
 # Operational adapter: sends one existing small MailTransfer TXT through the calibrated screen.
 # Never resends by itself; a result of SUBMITTED_UI_UNCONFIRMED means the button was already pressed.
 param([string]$Path,[string]$Configuration,[int]$MaxBytes=1048576)
 Initialize-TransferDesktop
 $script:report=New-Object 'System.Collections.Generic.List[string]'
 $script:report.Add('i-oneNet screen transfer adapter')
 $script:report.Add(('Build: '+$TransferBuild))
 $script:report.Add(('Generated: {0:o}' -f (Get-Date)))
 $state=@{stage='INITIALIZE';clicked=$false};$result='FAILED';$code='';$name='';$hash=''
 $mutex=New-Object Threading.Mutex($false,$TransferMutexName);$owned=$false
 try{
  $owned=$mutex.WaitOne(0);if(-not $owned){throw 'ANOTHER_TRANSFER_IS_RUNNING'}
  $state.stage='CHECK_FILE'
  $full=[IO.Path]::GetFullPath($Path);$name=[IO.Path]::GetFileName($full)
  if($name -cnotmatch '^MailTransfer-(?:(?:Probe|Request|Result)-[a-f0-9]{32}\.txt|Attachment-[a-f0-9]{32}(?:\.[^\\/:*?"<>|\x00-\x1f]{1,20})?)$'){throw 'TRANSFER_FILENAME_INVALID'}
  $info=Get-Item -LiteralPath $full -ErrorAction Stop
  if($info.Length -lt 0 -or $info.Length -gt $MaxBytes){throw 'TRANSFER_FILE_SIZE_INVALID'}
  $hash=Get-TransferBytesHash ([IO.File]::ReadAllBytes($full))
  $script:report.Add(('File: {0}; bytes: {1}; SHA256: {2}' -f $name,$info.Length,$hash))
  $state.stage='START_TRANSFER_CLIENT'
  $window=Ensure-TransferWindow (Get-TransferLaunchPath $Configuration)
  $state.stage='CHECK_SAVED_LAYOUT'
  if(-not [IO.File]::Exists($Configuration)){throw 'TRANSFER_CALIBRATION_REQUIRED'}
  $settings=Read-TransferJson $Configuration;Test-TransferSettings $settings
  Assert-TransferLayout $window $settings
  Invoke-CalibratedSend $window $settings $full $state
  $result='SUBMITTED_UI_CONFIRMED'
 }catch{
  if($state.clicked){$result='SUBMITTED_UI_UNCONFIRMED'}
  $code=Get-TransferErrorCode $_
  $script:report.Add(('Failure stage: {0}; error code: {1}' -f $state.stage,$code))
 }finally{if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()}
 $script:report.Add(('Send click dispatched: {0}' -f $state.clicked));$script:report.Add(('Result: {0}' -f $result))
 $script:report.Add('Delivery is not confirmed by this report. Match the file ID and SHA256 on the receiving side.')
 return [pscustomobject]@{result=$result;clicked=$state.clicked;stage=$state.stage;error=$code;name=$name;hash=$hash;report=$script:report}
}
function Test-TransferCalibrationUsable {
 # True only when saved positions fit this client version, DPI, window size and the empty list image.
 param([string]$Configuration)
 if(-not [IO.File]::Exists($Configuration)){return $false}
 try{$settings=Read-TransferJson $Configuration;Test-TransferSettings $settings}catch{return $false}
 $script:report=New-Object 'System.Collections.Generic.List[string]'
 $window=Ensure-TransferWindow (Get-TransferLaunchPath $Configuration)
 $layout=Get-TransferLayout $window;$r=$window.Current.BoundingRectangle
 if($settings.clientVersion -cne $layout.version -or [int]$settings.dpi -ne [int]$layout.dpi){Write-Host '자료교환 버전 또는 화면 배율이 바뀌어 버튼 위치를 다시 지정합니다.';return $false}
 if([Math]::Abs($r.Width-$settings.plus.width) -gt 3 -or [Math]::Abs($r.Height-$settings.plus.height) -gt 3){Write-Host '자료교환 창 크기가 바뀌어 버튼 위치를 다시 지정합니다.';return $false}
 for($attempt=0;$attempt -lt 2;$attempt++){
  Wait-TransferForeground $window;Move-TransferCursorAway $window
  if((Get-SenderHash $window) -ceq $settings.emptyHash){return $true}
  if($attempt -eq 0){Confirm-EmptyTransferList}
 }
 Write-Host '빈 보내기 목록 화면이 저장된 설정과 달라 버튼 위치를 다시 지정합니다.'
 return $false
}
function Invoke-TransferCalibration {
 param([string]$Configuration,[string]$OutputFolder,[string]$ProbeId)
 $script:report=New-Object 'System.Collections.Generic.List[string]'
 $script:report.Add('i-oneNet screen transfer calibration')
 $script:report.Add(('Build: '+$TransferBuild))
 $script:report.Add(('Generated: {0:o}' -f (Get-Date)))
 $script:report.Add('Synthetic test TXT only. Desktop mouse/foreground automation; keep this Windows session unlocked.')
 $state=@{stage='INITIALIZE';clicked=$false};$probe=$null;$result='FAILED';$code=''
 try{
  $state.stage='START_TRANSFER_CLIENT'
  $window=Ensure-TransferWindow (Get-TransferLaunchPath $Configuration)
  $layout=Get-TransferLayout $window
  Confirm-EmptyTransferList
  $state.stage='CALIBRATE_PLUS'
  Set-MailOperationPhase '설정 · ＋ 위치 지정'
  $plus=Get-ControlPoint $window '첫 번째 위치: 빈 보내기 영역의 ＋ 버튼'
  Set-MailOperationPhase '설정 테스트 파일 등록 중' -Locked
  Move-TransferCursorAway $window;$emptyHash=Get-SenderHash $window
  $state.stage='CREATE_TEST_TXT'
  $probe=New-TransferProbe (Join-Path $OutputFolder 'outbox') -Id $ProbeId
  $script:report.Add(('Probe ID: {0}' -f $probe.id));$script:report.Add(('Probe filename: {0}' -f $probe.name));$script:report.Add(('Probe bytes: {0}; SHA256: {1}' -f $probe.bytes,$probe.hash))
  $state.stage='REGISTER_FILE'
  Register-TransferFile $window $plus $probe.path
  Move-TransferCursorAway $window
  $registrationDeadline=[DateTime]::UtcNow.AddSeconds(12)
  while((Get-SenderHash $window)-ceq$emptyHash-and[DateTime]::UtcNow-lt$registrationDeadline){Assert-TransferAbort;Start-Sleep -Milliseconds 200}
  if((Get-SenderHash $window) -ceq $emptyHash){throw 'REGISTRATION_NOT_CONFIRMED'}
  $evidence=Get-RegistrationEvidence $window $probe.name
  $script:report.Add(('Registered filename evidence: {0}; one-file count evidence: {1}' -f $evidence.FileSeen,$evidence.OneFileSeen))
  Set-MailOperationPhase '설정 · 등록 파일과 보내기 위치 확인'
  Confirm-SoleTransferProbe $probe.name
  $state.stage='CALIBRATE_SEND'
  $send=Get-ControlPoint $window '두 번째 위치: 등록한 테스트 TXT 한 개를 보내는 아래 보내기 버튼'
  if($send.x -le .5 -or $send.y -le .7){throw 'SEND_CALIBRATION_LOCATION_INVALID'}
  Set-MailOperationPhase '설정 테스트 전송 중' -Locked
  Move-TransferCursorAway $window;$buttonHash=Get-SendButtonHash $window $send
  $state.stage='CLICK_SEND_ONCE'
  Invoke-TransferPoint $window $send;$state.clicked=$true
  $state.stage='WAIT_EMPTY_SEND_LIST'
  Wait-SenderReset $window $emptyHash $probe.name $evidence.FileSeen
  Write-TransferJson $Configuration @{schemaVersion=1;kind='screen-transfer-test';calibrated=$true;plus=$plus;send=$send;emptyHash=$emptyHash;sendButtonHash=$buttonHash;clientVersion=$layout.version;dpi=$layout.dpi;requireFileEvidence=$evidence.FileSeen;requireCountEvidence=$evidence.OneFileSeen}
  $script:report.Add('Calibration saved: yes')
  $result='SUBMITTED_UI_CONFIRMED'
 }catch{
  if($state.clicked){$result='SUBMITTED_UI_UNCONFIRMED'}
  $code=Get-TransferErrorCode $_
  $script:report.Add(('Failure stage: {0}; error code: {1}' -f $state.stage,$code))
 }
 $script:report.Add(('Send click dispatched: {0}' -f $state.clicked));$script:report.Add(('Result: {0}' -f $result))
 $script:report.Add('Delivery is not confirmed by this report. Match Probe ID with the receiver report.')
 return [pscustomobject]@{result=$result;clicked=$state.clicked;stage=$state.stage;error=$code;probe=$probe;report=$script:report}
}
function Invoke-TransferTest {
 param([string]$RunMode,[string]$Configuration,[string]$OutputFolder,[string]$RemoteInbox,[string]$ProbeId='')
 if($RunMode -eq 'Calibrate'){
  $outcome=Invoke-TransferCalibration $Configuration $OutputFolder $ProbeId
  $probe=$outcome.probe
 }else{
  $probe=New-TransferProbe (Join-Path $OutputFolder 'outbox') -Id $ProbeId
  $outcome=Send-TransferFile $probe.path $Configuration
  $outcome.report.Add(('Probe ID: {0}' -f $probe.id))
 }
 $reportPath=Save-TransferReport $outcome.report $OutputFolder ('MailAutomation-iOneSend-'+$TransferBuild)
 if($outcome.result -eq 'SUBMITTED_UI_CONFIRMED'){Write-Host '테스트 TXT의 보내기를 실행했고 목록이 비워진 것을 확인했습니다.'}
 else{
  Write-Host ('전송 중단. 단계: '+$outcome.stage+' / '+$outcome.error)
  Write-TransferHint $outcome.error
  if($outcome.clicked){Write-Host '보내기는 이미 한 번 실행했습니다. 재전송하지 말고 수신 결과를 확인하세요.'}
 }
 Write-Host ('보고서: '+$reportPath)
 if($probe){Write-Host ('반대쪽 '+$RemoteInbox+'에서 '+$probe.name+'의 수신을 확인하세요.')}
 return [pscustomobject]@{result=$outcome.result;probe=$probe;report=$reportPath;clicked=$outcome.clicked;error=$outcome.error}
}
if($LibraryOnly){return}
Initialize-TransferDesktop
Write-Host '이번 테스트는 자료교환 창과 마우스를 실제로 조작하고 테스트 TXT를 한 개 전송합니다.'
Write-Host '자동 조작 중에는 마우스와 키보드를 사용하지 마세요. ESC를 길게 누르면 중단합니다.'
$mutex=New-Object Threading.Mutex($false,$TransferMutexName);$owned=$false
$awake=$null
try{
 $owned=$mutex.WaitOne(0);if(-not $owned){throw 'ANOTHER_TRANSFER_IS_RUNNING'}
 $awake=Start-MailKeepAwake
 $outcome=Invoke-TransferTest $Mode $SettingsPath $ReportDirectory $TargetInbox
 if($outcome.result -eq 'FAILED'){exit 1}
 if($outcome.result -eq 'SUBMITTED_UI_UNCONFIRMED'){exit 2}
}finally{try{Stop-MailKeepAwake $awake}finally{if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()}}
