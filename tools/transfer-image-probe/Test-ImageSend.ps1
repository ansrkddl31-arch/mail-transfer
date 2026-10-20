param()
$ErrorActionPreference='Stop'
$script:trialStage='INITIALIZE';$script:sendAttempted=$false;$script:sendClicks=0;$script:captures=0;$script:lastSnapshot=$null
$report=New-Object 'System.Collections.Generic.List[string]'
$trialMutex=$null;$owned=$false;$run=$null
function Save-TrialResult([string]$Outcome,[string]$ErrorText=''){
 if(-not$run){return}
 $record=@{at=(Get-Date).ToString('o');stage=$script:trialStage;outcome=$Outcome;error=$ErrorText;sendAttempted=$script:sendAttempted;sendClicks=$script:sendClicks;testFile=$script:trialName;receiptVerified=$false;lastSnapshot=$script:lastSnapshot;details=@($report.ToArray())}
 [IO.File]::WriteAllText((Join-Path $run 'result.json'),($record|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))
}
try{
 if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT){throw 'WINDOWS_REQUIRED'}
 $run=Join-Path (Join-Path $PSScriptRoot 'logs') ('send-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6));[void][IO.Directory]::CreateDirectory($run)
 Add-Type -AssemblyName System.Windows.Forms;Add-Type -AssemblyName System.Drawing
 Add-Type -Path (Join-Path $PSScriptRoot 'Detector.cs')
 Add-Type -Path (Join-Path $PSScriptRoot 'Trial.Native.cs')
 . (Join-Path $PSScriptRoot 'Transfer.Helpers.ps1')
 . (Join-Path $PSScriptRoot 'Trial.Flow.ps1')
 Initialize-FileDialogNative
 $trialMutex=New-Object Threading.Mutex($false,'Local\EXMailImageSendTrial')
 try{$owned=$trialMutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
 if(-not$owned){throw 'ANOTHER_IMAGE_TRIAL_RUNNING'}
 $script:trialName='EXMail-ImageTrial-'+[guid]::NewGuid().ToString('N')+'.txt'
 $script:trialPath=Join-Path $run $script:trialName
 [IO.File]::WriteAllText($script:trialPath,('EXMAIL_IMAGE_SEND_TRIAL_V1'+"`r`n"+'ID: '+$script:trialName+"`r`n"+'Image recognition transfer test only. No credentials or mail data.'),(New-Object Text.UTF8Encoding($true)))
 [void][EXMailImageTrial.Native]::SetProcessDPIAware()
 function Assert-TransferAbort {
  if(([EXMailImageTrial.Native]::GetAsyncKeyState(0x73)-band0x8001)-ne0){throw 'USER_ABORTED_F4'}
 }
 function Set-TransferCursorPosition([int]$X,[int]$Y){Assert-TransferAbort;return [TransferFileDialogV3.Native]::SetCursorPos($X,$Y)}
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
   if($script:captures-le30){$bitmap.Save((Join-Path $run ('screen-'+$script:captures+'.png')),[Drawing.Imaging.ImageFormat]::Png)}
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
  $deadline=[DateTime]::UtcNow.AddSeconds(20);$stable=0
  do{
   $frame=Get-TrialSnapshot
   if((@($frame.plus).Count-eq1-and@($frame.send).Count-eq0)-or$frame.emptyEditor){$stable++}else{$stable=0}
   if($stable-ge2){return $true}
   Start-Sleep -Milliseconds 400
  }while([DateTime]::UtcNow-lt$deadline)
  return $false
 }
 Write-Host '시험 TXT 1개를 실제 전송합니다. 자료교환 보내기 목록을 비우세요.' -ForegroundColor Yellow
 Write-Host '8초 안에 자료교환 창을 클릭한 뒤 마우스/키보드를 사용하지 마세요. F4로 중지합니다.'
 for($i=8;$i-ge1;$i--){Assert-TransferAbort;Write-Host ($i.ToString()+'...');Start-Sleep -Seconds 1}
 $script:trialWindow=[EXMailImageTrial.Native]::GetForegroundWindow()
 if(-not[EXMailImageTrial.Native]::GetTitle($script:trialWindow).Contains('자료교환')){throw 'TRANSFER_WINDOW_NOT_FOREGROUND'}
 $outcome=Invoke-ImageSendTrial -Snapshot {Get-TrialSnapshot} -Click {param($kind,$candidate) Invoke-TrialClick $kind $candidate} -Register {Register-TrialFile} -WaitReady {Wait-TrialReady} -WaitEmpty {Wait-TrialEmpty} -ResetEmptyEditor {Reset-TrialEmptyEditor} -Stage {param($name) $script:trialStage=$name;Write-Host $name;Save-TrialResult 'RUNNING'}
 Save-TrialResult $outcome
 Write-Host '보내기를 한 번 누른 뒤 빈 목록 복귀를 확인했습니다. 반대편 수신 파일까지 확인해야 전송 성공입니다.' -ForegroundColor Green
 Write-Host ('반대편에서 찾을 파일: '+$script:trialName)
}catch{
 $errorText=$_.Exception.Message;Save-TrialResult 'STOPPED_OR_UNCONFIRMED' $errorText
 Write-Host ('중지: '+$errorText) -ForegroundColor Red
 if($errorText-in@('SEND_EDITOR_VIEW_USE_CANCEL_AND_RETRY','EMPTY_EDITOR_CANCEL_NOT_FOUND_USE_CANCEL_MANUALLY','EMPTY_EDITOR_ZERO_FILES_NOT_CONFIRMED')){Write-Host '자료교환의 취소를 눌러 가운데 동그란 +가 있는 초기 화면으로 돌아온 뒤 다시 실행하세요.' -ForegroundColor Yellow}
 if($script:sendAttempted){Write-Host '이미 보내기를 시도했습니다. 반대편 수신 여부를 먼저 확인하세요. 자동 재전송하지 않습니다.'}
}finally{
 if($owned){$trialMutex.ReleaseMutex()};if($trialMutex){$trialMutex.Dispose()}
 if($run){Write-Host ('결과 폴더: '+$run);Start-Process explorer.exe -ArgumentList ('"'+$run+'"')}
}
