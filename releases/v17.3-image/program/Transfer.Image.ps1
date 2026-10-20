#requires -Version 5.1
# Native window discovery + validated image matcher. No coordinate calibration or UI Automation.
function Initialize-ImageTransfer {
 if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT){throw 'WINDOWS_REQUIRED'}
 Add-Type -AssemblyName System.Windows.Forms
 Add-Type -AssemblyName System.Drawing
 if(-not('EXMailImageProbe.Detector'-as[type])){Add-Type -Path (Join-Path $PSScriptRoot 'Image.Detector.cs')}
 if(-not('EXMailImageTrial.Native'-as[type])){Add-Type -Path (Join-Path $PSScriptRoot 'Image.Native.cs')}
 Initialize-FileDialogNative
 Initialize-TransferWindowNative
 [void][EXMailImageTrial.Native]::SetProcessDPIAware()
 [void][MailBridge.Native]::SetThreadDpiAwarenessContext([IntPtr](-4))
}
function Get-TransferLaunchPath {
 param([string]$Configuration)
 return (Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Configuration))) 'transfer-launch.json')
}
function Get-TransferWindow {
 $found=@(foreach($process in @(Get-TransferProcesses)){
  foreach($handle in @([MailTransfer.TopWindows]::Find([uint32]$process.Id,'자료교환'))){
   if([MailTransfer.TopWindows]::IsWindowVisible($handle)){[pscustomobject]@{Current=[pscustomobject]@{NativeWindowHandle=$handle;ProcessId=$process.Id}}}
  }
 })
 if($found.Count-ne1){throw 'ONE_TRANSFER_WINDOW_REQUIRED'}
 return $found[0]
}
function Save-TransferReport {
 param($Lines,[string]$Folder,[string]$Prefix)
 [void][IO.Directory]::CreateDirectory($Folder)
 $path=Join-Path $Folder ($Prefix+'-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)+'.txt')
 [IO.File]::WriteAllLines($path,[string[]]$Lines,(New-Object Text.UTF8Encoding($true)))
 return $path
}
function Send-ImageTransferFile {
 param([string]$Path,[string]$Configuration,[int]$MaxBytes=67108864)
 $script:trialStage='INITIALIZE';$script:sendAttempted=$false;$script:sendClicks=0;$script:captures=0;$script:lastSnapshot=$null
 $script:report=New-Object 'System.Collections.Generic.List[string]';$report=$script:report
 $script:trialName='';$script:trialPath='';$hash='';$mutex=$null;$owned=$false
 function Save-TrialResult([string]$Outcome,[string]$ErrorText=''){
  if(Get-Command Write-ExternalTransferProgress -ErrorAction SilentlyContinue){Write-ExternalTransferProgress $script:trialStage $ErrorText $Outcome}
 }
 function Assert-TransferAbort {
  Assert-MailOperationContinue
  if(([EXMailImageTrial.Native]::GetAsyncKeyState(0x73)-band0x8001)-ne0){throw 'USER_ABORTED_F4'}
 }
 function Assert-TrialWindow {
  Assert-TransferAbort
  if([EXMailImageTrial.Native]::GetForegroundWindow()-ne$script:trialWindow){throw 'TRANSFER_WINDOW_NOT_FOREGROUND'}
  if([EXMailImageTrial.Native]::IsIconic($script:trialWindow)){throw 'TRANSFER_WINDOW_MINIMIZED'}
 }
 function Get-TrialSnapshot {
  Assert-TrialWindow
  $rect=New-Object EXMailImageTrial.Native+Rect;$point=New-Object EXMailImageTrial.Native+Point
  if(-not[EXMailImageTrial.Native]::GetClientRect($script:trialWindow,[ref]$rect)-or-not[EXMailImageTrial.Native]::ClientToScreen($script:trialWindow,[ref]$point)){throw 'WINDOW_RECT_FAILED'}
  $w=$rect.Right-$rect.Left;$h=$rect.Bottom-$rect.Top
  if($w-lt150-or$h-lt200-or$w-gt2000-or$h-gt2500){throw 'WINDOW_SIZE_UNSUPPORTED'}
  $area=New-Object Drawing.Rectangle($point.X,$point.Y,$w,$h)
  if(-not[Windows.Forms.SystemInformation]::VirtualScreen.Contains($area)){throw 'WINDOW_NOT_FULLY_ON_SCREEN'}
  $bitmap=New-Object Drawing.Bitmap($w,$h,[Drawing.Imaging.PixelFormat]::Format24bppRgb);$g=$null;$lock=$null
  try{
   $g=[Drawing.Graphics]::FromImage($bitmap);$g.CopyFromScreen($point.X,$point.Y,0,0,$bitmap.Size);$g.Dispose();$g=$null
   $script:captures++
   $bounds=New-Object Drawing.Rectangle(0,0,$w,$h)
   $lock=$bitmap.LockBits($bounds,[Drawing.Imaging.ImageLockMode]::ReadOnly,[Drawing.Imaging.PixelFormat]::Format24bppRgb)
   $pixels=New-Object byte[] ($w*$h*3);$row=New-Object byte[] ($w*3)
   for($y=0;$y-lt$h;$y++){
    Assert-TransferAbort
    [Runtime.InteropServices.Marshal]::Copy([IntPtr]::Add($lock.Scan0,$y*$lock.Stride),$row,0,$row.Length)
    for($x=0;$x-lt$w;$x++){$j=($y*$w+$x)*3;$pixels[$j]=$row[$x*3+2];$pixels[$j+1]=$row[$x*3+1];$pixels[$j+2]=$row[$x*3]}
   }
   $bitmap.UnlockBits($lock);$lock=$null
   $found=@([EXMailImageProbe.Detector]::Find($pixels,$w,$h));Assert-TrialWindow
   $emptyEditor=Test-EmptyEditorEvidence @(Get-TrialControlTexts)
   $frame=@{plus=@($found|Where-Object{$_.Kind-eq'PLUS'});send=@($found|Where-Object{$_.Kind-eq'SEND'});originX=$point.X;originY=$point.Y;emptyEditor=$emptyEditor}
   $script:lastSnapshot=@{capture=$script:captures;plusCount=$frame.plus.Count;sendCount=$frame.send.Count;emptyEditor=$emptyEditor;candidates=$found}
   $report.Add(('Capture {0}: PLUS={1}; SEND={2}; nativeZeroFiles={3}' -f $script:captures,$frame.plus.Count,$frame.send.Count,$emptyEditor))
   return $frame
  }finally{if($lock){$bitmap.UnlockBits($lock)};if($g){$g.Dispose()};$bitmap.Dispose()}
 }
 function Get-TrialControlTexts {
  $windowRect=[TransferFileDialogV3.Native]::Bounds($script:trialWindow)
  foreach($child in @(Get-FileDialogChildren $script:trialWindow)){
   Assert-TransferAbort
   if(-not[TransferFileDialogV3.Native]::IsWindowVisible($child)){continue}
   if((Get-NativeClass $child)-match'^(Edit|WindowsForms10\.EDIT)'){continue}
   $r=[TransferFileDialogV3.Native]::Bounds($child)
   if($r.Left-lt$windowRect.Left-or$r.Right-gt$windowRect.Right-or$r.Top-lt($windowRect.Top+($windowRect.Bottom-$windowRect.Top)*.65)-or$r.Bottom-gt$windowRect.Bottom){continue}
   try{Read-FileDialogText $child 256 100}catch{}
  }
 }
 function Reset-TrialEmptyEditor {
  Assert-TrialWindow
  if(-not(Test-EmptyEditorEvidence @(Get-TrialControlTexts))){throw 'EMPTY_EDITOR_ZERO_FILES_NOT_CONFIRMED'}
  $windowRect=[TransferFileDialogV3.Native]::Bounds($script:trialWindow)
  $buttons=New-Object 'System.Collections.Generic.List[System.IntPtr]'
  foreach($child in @(Get-FileDialogChildren $script:trialWindow)){
   if(-not[TransferFileDialogV3.Native]::IsWindowVisible($child)-or-not[TransferFileDialogV3.Native]::IsWindowEnabled($child)){continue}
   if((Get-NativeClass $child)-notmatch'^(Button|WindowsForms10\.BUTTON(?:\..*)?)$'){continue}
   try{$text=(Read-FileDialogText $child 64 100).Trim().Replace('&','')}catch{continue}
   if($text-notmatch'^(취소|Cancel)(\([A-Za-z]\))?$'){continue}
   $r=[TransferFileDialogV3.Native]::Bounds($child)
   if($r.Left-lt$windowRect.Left-or$r.Right-gt$windowRect.Right-or$r.Top-lt($windowRect.Top+($windowRect.Bottom-$windowRect.Top)*.8)-or$r.Bottom-gt$windowRect.Bottom){continue}
   $buttons.Add($child)
  }
  if($buttons.Count-ne1){throw 'EMPTY_EDITOR_CANCEL_NOT_FOUND_USE_CANCEL_MANUALLY'}
  Invoke-DialogControlClick $script:trialWindow $buttons[0]
  $deadline=[DateTime]::UtcNow.AddSeconds(8)
  do{$frame=Get-TrialSnapshot;if(@($frame.plus).Count-eq1-and@($frame.send).Count-eq0){return};Start-Sleep -Milliseconds 250}while([DateTime]::UtcNow-lt$deadline)
  throw 'EMPTY_EDITOR_RESET_NOT_CONFIRMED'
 }
 function Test-TrialFileRegistered {
  # Native control text, not UI Automation. Never send if the unique test filename cannot be read back.
  foreach($child in @(Get-FileDialogChildren $script:trialWindow)){
   if(-not[TransferFileDialogV3.Native]::IsWindowVisible($child)){continue}
   try{$text=Read-FileDialogText $child 2048 100;if($text.Trim()-ceq$script:trialName){return $true}}catch{}
  }
  return $false
 }
 function Invoke-TrialClick([string]$Kind,$Expected){
  $fresh=Get-TrialSnapshot;$items=if($Kind-eq'PLUS'){@($fresh.plus)}else{@($fresh.send)}
  if($items.Count-ne1){throw 'CLICK_TARGET_NOT_UNIQUE'}
  if(($Kind-eq'PLUS'-and@($fresh.send).Count-ne0)-or($Kind-eq'SEND'-and@($fresh.plus).Count-ne0)){throw 'CLICK_SCREEN_STATE_CHANGED'}
  $target=$items[0]
  if([Math]::Abs($target.X-$Expected.X)-gt3-or[Math]::Abs($target.Y-$Expected.Y)-gt3-or[Math]::Abs($target.Width-$Expected.Width)-gt3-or[Math]::Abs($target.Height-$Expected.Height)-gt3){throw 'CLICK_TARGET_MOVED'}
  if($Kind-eq'SEND'){
   if($script:sendAttempted){throw 'SEND_ALREADY_ATTEMPTED'}
   if($fresh.emptyEditor){throw 'SEND_LIST_STILL_ZERO_FILES'}
   if(-not(Test-TrialFileRegistered)){throw 'TEST_FILENAME_NOT_VERIFIED'}
  }
  $p=New-Object TransferFileDialogV3.Point;$p.X=$fresh.originX+$target.X+[int]($target.Width/2);$p.Y=$fresh.originY+$target.Y+[int]($target.Height/2)
  $hit=[TransferFileDialogV3.Native]::WindowFromPoint($p)
  if($hit-ne$script:trialWindow-and-not[TransferFileDialogV3.Native]::IsChild($script:trialWindow,$hit)){throw 'CLICK_TARGET_OCCLUDED'}
  [void](Set-TransferCursorPosition $p.X $p.Y);Assert-TrialWindow
  if($Kind-eq'SEND'){$script:sendAttempted=$true;Save-TrialResult 'SEND_ATTEMPT_STARTED'}
  [TransferFileDialogV3.Native]::mouse_event(2,0,0,0,[UIntPtr]::Zero);[TransferFileDialogV3.Native]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
  if($Kind-eq'SEND'){$script:sendClicks++;Save-TrialResult 'SEND_CLICKED_ONCE'}
  Start-Sleep -Milliseconds 400
 }
 function Register-TrialFile {
  $dialog=[IntPtr]::Zero;$deadline=[DateTime]::UtcNow.AddSeconds(12)
  do{
   Assert-TransferAbort;$front=[EXMailImageTrial.Native]::GetForegroundWindow()
   if($front-ne$script:trialWindow){
    $class=[EXMailImageTrial.Native]::GetClass($front)
    if(($class-ne'#32770'-and$class-notlike'WindowsForms10.Window.*')-or-not[EXMailImageTrial.Native]::OwnedBy($front,$script:trialWindow)){throw 'UNEXPECTED_FOREGROUND_WINDOW'}
    $dialog=$front;break
   }
   Start-Sleep -Milliseconds 200
  }while([DateTime]::UtcNow-lt$deadline)
  if($dialog-eq[IntPtr]::Zero){throw 'FILE_DIALOG_NOT_FOUND'}
  $wrapper=[pscustomobject]@{Current=[pscustomobject]@{NativeWindowHandle=$dialog}}
  Set-FileDialogProbePath $wrapper $script:trialPath
  Invoke-FileDialogOpen $wrapper
  $deadline=[DateTime]::UtcNow.AddSeconds(10)
  while(Test-FileDialogStillVisible $dialog){Assert-TransferAbort;if([DateTime]::UtcNow-ge$deadline){throw 'FILE_DIALOG_STILL_OPEN'};Start-Sleep -Milliseconds 200}
 }
 function Wait-TrialReady {
  $deadline=[DateTime]::UtcNow.AddSeconds(15)
  do{$frame=Get-TrialSnapshot;$frame.registered=Test-TrialFileRegistered;if($frame.registered-and-not$frame.emptyEditor-and@($frame.send).Count-eq1){return $frame};Start-Sleep -Milliseconds 300}while([DateTime]::UtcNow-lt$deadline)
  throw 'TEST_FILE_REGISTRATION_NOT_CONFIRMED'
 }
 function Wait-TrialEmpty {
  $deadline=[DateTime]::UtcNow.AddSeconds(90);$stable=0
  do{
   $frame=Get-TrialSnapshot
   if((@($frame.plus).Count-eq1-and@($frame.send).Count-eq0)-or$frame.emptyEditor){$stable++}else{$stable=0}
   if($stable-ge2){return $true}
   Start-Sleep -Milliseconds 400
  }while([DateTime]::UtcNow-lt$deadline)
  return $false
 }

 try{
  $script:trialStage='CHECK_FILE'
  $full=[IO.Path]::GetFullPath($Path);$script:trialName=[IO.Path]::GetFileName($full);$script:trialPath=$full
  if($script:trialName-cnotmatch'^MailTransfer-(?:(?:Probe|Request|Result)-[a-f0-9]{32}\.txt|Attachment-[a-f0-9]{32}(?:\.[^\\/:*?"<>|\x00-\x1f]{1,20})?)$'){throw 'TRANSFER_FILENAME_INVALID'}
  $info=Get-Item -LiteralPath $full -ErrorAction Stop
  if(($info.Attributes-band[IO.FileAttributes]::ReparsePoint)-or$info.Length-lt0-or$info.Length-gt$MaxBytes){throw 'TRANSFER_FILE_SIZE_INVALID'}
  $hash=Get-TransferBytesHash ([IO.File]::ReadAllBytes($full))
  $report.Add('Image sender v17.3; file='+$script:trialName+'; sha256='+$hash)
  Initialize-ImageTransfer
  $mutex=New-Object Threading.Mutex($false,'Local\MailTransferScreenSender');$owned=$mutex.WaitOne(0)
  if(-not$owned){throw 'ANOTHER_TRANSFER_IS_RUNNING'}
  Set-MailOperationPhase '자료교환 창 준비'
  $script:trialStage='START_TRANSFER_CLIENT'
  $window=Ensure-TransferWindow (Get-TransferLaunchPath $Configuration)
  Focus-TransferWindow $window
  $script:trialWindow=[IntPtr]$window.Current.NativeWindowHandle
  Set-MailOperationPhase '자료교환 이미지 인식·전송 중' -Locked
  $outcome=Invoke-ImageSendTrial -Snapshot {Get-TrialSnapshot} -Click {param($kind,$candidate) Invoke-TrialClick $kind $candidate} -Register {Register-TrialFile} -WaitReady {Wait-TrialReady} -WaitEmpty {Wait-TrialEmpty} -ResetEmptyEditor {Reset-TrialEmptyEditor} -Stage {param($name) $script:trialStage=$name;Save-TrialResult 'WORKING'}
  $result='SUBMITTED_UI_CONFIRMED';$code=''
 }catch{
  $result=if($script:sendAttempted){'SUBMITTED_UI_UNCONFIRMED'}else{'FAILED'}
  $code=$_.Exception.Message
  if($code-eq'USER_ABORTED_F4'){$code='USER_ABORTED'}
  if($code-cnotmatch'^[A-Z][A-Z0-9_]+$'){$code='IMAGE_TRANSFER_FAILED'}
  $report.Add('Failure stage='+$script:trialStage+'; code='+$code)
 }finally{
  if($owned){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}
  if($script:lastSnapshot){$report.Add('Last image: '+($script:lastSnapshot|ConvertTo-Json -Depth 5 -Compress))}
 }
 $report.Add('Send attempts='+$script:sendClicks+'; receipt must be verified on receiving PC')
 return [pscustomobject]@{result=$result;clicked=$script:sendAttempted;stage=$script:trialStage;error=$code;name=$script:trialName;hash=$hash;report=$report}
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

function Resolve-TransferExecutable {
 param([string]$Configuration)
 if([IO.File]::Exists($Configuration)){
  try{$saved=Read-TransferJson $Configuration;if($saved.schemaVersion-eq1-and$saved.kind-ceq'transfer-launch'){return (Test-TransferExecutable ([string]$saved.executable))}}catch{}
 }
 $found=@(Find-TransferExecutable)
 if($found.Count-ne1){throw 'TRANSFER_LAUNCH_NOT_CONFIGURED'}
 Save-TransferExecutable $found[0] $Configuration
 return (Test-TransferExecutable $found[0])
}
