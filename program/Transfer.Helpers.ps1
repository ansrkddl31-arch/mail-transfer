function Initialize-FileDialogNative {
 if('TransferFileDialogV3.Native' -as [type]){return}
 Add-Type -AssemblyName System.Windows.Forms
 Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
namespace TransferFileDialogV3 {
 [StructLayout(LayoutKind.Sequential)] public struct Rect {public int Left,Top,Right,Bottom;}
 [StructLayout(LayoutKind.Sequential)] public struct Point {public int X,Y;}
 [StructLayout(LayoutKind.Sequential)] public struct GuiInfo {
  public uint Size,Flags;public IntPtr Active,Focus,Capture,MenuOwner,MoveSize,Caret;public Rect CaretRect;
 }
 public static class Native {
  public delegate bool EnumProc(IntPtr handle,IntPtr data);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent,EnumProc callback,IntPtr data);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool IsChild(IntPtr parent,IntPtr handle);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr handle);
  [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr handle);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr handle,out uint process);
  [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint thread,ref GuiInfo info);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr handle,out Rect rect);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr handle,StringBuilder text,int length);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(Point p);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags,uint x,uint y,uint data,UIntPtr extra);
  [DllImport("user32.dll",EntryPoint="SendMessageTimeoutW",CharSet=CharSet.Unicode)] public static extern IntPtr SetText(IntPtr handle,uint message,IntPtr wparam,string text,uint flags,uint timeout,out UIntPtr result);
  [DllImport("user32.dll",EntryPoint="SendMessageTimeoutW",CharSet=CharSet.Unicode)] public static extern IntPtr ReadText(IntPtr handle,uint message,IntPtr length,StringBuilder text,uint flags,uint timeout,out UIntPtr result);
  public static IntPtr FocusedControl(IntPtr dialog){
   uint process;uint thread=GetWindowThreadProcessId(dialog,out process);
   GuiInfo info=new GuiInfo();info.Size=(uint)Marshal.SizeOf(typeof(GuiInfo));
   return thread!=0&&GetGUIThreadInfo(thread,ref info)?info.Focus:IntPtr.Zero;
  }
  public static Rect Bounds(IntPtr handle){Rect rect;if(!GetWindowRect(handle,out rect))throw new InvalidOperationException("WINDOW_BOUNDS_UNAVAILABLE");return rect;}
 }
}
'@
}
function Assert-FileDialogForeground {
 param([IntPtr]$Handle)
 Assert-TransferAbort
 if([TransferFileDialogV3.Native]::GetForegroundWindow() -ne $Handle){throw 'FILE_DIALOG_NOT_FOREGROUND'}
}
function Get-NativeClass {
 param([IntPtr]$Handle)
 $text=New-Object Text.StringBuilder 256
 [void][TransferFileDialogV3.Native]::GetClassName($Handle,$text,$text.Capacity)
 return $text.ToString()
}
function Test-FileNameRegion {
 param($DialogRect,$FieldRect)
 $width=$DialogRect.Right-$DialogRect.Left;$height=$DialogRect.Bottom-$DialogRect.Top
 if($width -lt 200 -or $height -lt 200 -or ($FieldRect.Right-$FieldRect.Left) -lt 80 -or ($FieldRect.Bottom-$FieldRect.Top) -lt 10){return $false}
 if($FieldRect.Left -lt $DialogRect.Left -or $FieldRect.Right -gt $DialogRect.Right -or $FieldRect.Top -lt $DialogRect.Top -or $FieldRect.Bottom -gt $DialogRect.Bottom){return $false}
 $x=(($FieldRect.Left+$FieldRect.Right)/2-$DialogRect.Left)/$width
 $y=(($FieldRect.Top+$FieldRect.Bottom)/2-$DialogRect.Top)/$height
 return ($x -gt .05 -and $x -lt .8 -and $y -gt .83 -and $y -lt .98 -and ($FieldRect.Bottom-$FieldRect.Top) -lt ($height*.15))
}
function Get-FileDialogChildren {
 param([IntPtr]$Handle)
 $items=New-Object 'System.Collections.Generic.List[System.IntPtr]'
 $callback=[TransferFileDialogV3.Native+EnumProc]{param($child,$data) $items.Add($child);return ($items.Count -lt 256)}
 [void][TransferFileDialogV3.Native]::EnumChildWindows($Handle,$callback,[IntPtr]::Zero)
 return @($items.ToArray())
}
function Test-FileNameHandle {
 param([IntPtr]$DialogHandle,[IntPtr]$FieldHandle)
 if($FieldHandle -eq [IntPtr]::Zero -or -not [TransferFileDialogV3.Native]::IsChild($DialogHandle,$FieldHandle) -or -not [TransferFileDialogV3.Native]::IsWindowVisible($FieldHandle) -or -not [TransferFileDialogV3.Native]::IsWindowEnabled($FieldHandle)){return $false}
 if((Get-NativeClass $FieldHandle) -notmatch '^(Edit|WindowsForms10\.EDIT(?:\..*)?)$'){return $false}
 return (Test-FileNameRegion ([TransferFileDialogV3.Native]::Bounds($DialogHandle)) ([TransferFileDialogV3.Native]::Bounds($FieldHandle)))
}
function Invoke-DialogControlClick {
 param([IntPtr]$DialogHandle,[IntPtr]$ControlHandle)
 Assert-FileDialogForeground $DialogHandle
 if(-not [TransferFileDialogV3.Native]::IsChild($DialogHandle,$ControlHandle)){throw 'CONTROL_OUTSIDE_FILE_DIALOG'}
 $r=[TransferFileDialogV3.Native]::Bounds($ControlHandle)
 $p=New-Object TransferFileDialogV3.Point;$p.X=[int](($r.Left+$r.Right)/2);$p.Y=[int](($r.Top+$r.Bottom)/2)
 $hit=[TransferFileDialogV3.Native]::WindowFromPoint($p)
 if($hit -ne $ControlHandle -and -not [TransferFileDialogV3.Native]::IsChild($ControlHandle,$hit)){throw 'FILE_DIALOG_CONTROL_OCCLUDED'}
 if(-not (Set-TransferCursorPosition $p.X $p.Y)){throw 'CURSOR_MOVE_FAILED'}
 Assert-FileDialogForeground $DialogHandle
 [TransferFileDialogV3.Native]::mouse_event(2,0,0,0,[UIntPtr]::Zero);[TransferFileDialogV3.Native]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
 Start-Sleep -Milliseconds 200
}
function Read-FileDialogText {
 param([IntPtr]$Handle,[int]$Capacity=1024,[int]$Timeout=1000)
 $buffer=New-Object Text.StringBuilder $Capacity;$result=[UIntPtr]::Zero
 if([TransferFileDialogV3.Native]::ReadText($Handle,13,[IntPtr]$buffer.Capacity,$buffer,2,$Timeout,[ref]$result) -eq [IntPtr]::Zero){throw 'FILE_DIALOG_TEXT_READ_FAILED'}
 return $buffer.ToString()
}
function Set-FileDialogProbePath {
 param($Dialog,[string]$Path)
 Initialize-FileDialogNative
 $handle=[IntPtr]$Dialog.Current.NativeWindowHandle
 Assert-FileDialogForeground $handle
 $report.Add(('File dialog native class: {0}' -f (Get-NativeClass $handle)))
 Write-Host '파일 선택창을 찾았습니다. 파일 이름 칸을 확인합니다.'
 # The dialog can appear before it finishes loading its folder view. Wait for the footer Edit instead of
 # giving up on the first look, which used to leave the dialog open with no path entered.
 $field=[IntPtr]::Zero;$candidates=@();$deadline=[DateTime]::UtcNow.AddSeconds(10)
 do{
  Assert-FileDialogForeground $handle
  $focused=[TransferFileDialogV3.Native]::FocusedControl($handle)
  if(Test-FileNameHandle $handle $focused){$field=$focused;break}
  # Custom WinForms dialogs need not expose standard dialog IDs or UIA names.
  # Select only a visible native Edit in the filename footer, never Search.
  $candidates=@(Get-FileDialogChildren $handle|Where-Object{Test-FileNameHandle $handle $_})
  if($candidates.Count -eq 1){$field=[IntPtr]$candidates[0];Invoke-DialogControlClick $handle $field;break}
  Start-Sleep -Milliseconds 300
 }while([DateTime]::UtcNow -lt $deadline)
 $report.Add(('Filename footer edit candidates: {0}' -f $candidates.Count))
 if($field -eq [IntPtr]::Zero){throw 'FILENAME_FOOTER_EDIT_NOT_FOUND'}
 Assert-FileDialogForeground $handle
 $focused=[TransferFileDialogV3.Native]::FocusedControl($handle)
 if($focused -ne $field -or -not (Test-FileNameHandle $handle $focused)){throw 'FILENAME_FOCUS_NOT_CONFIRMED'}
 $report.Add(('Focused filename control class: {0}' -f (Get-NativeClass $field)))
 Write-Host '보낼 TXT의 전체 경로를 입력합니다.'
 $entered=$false
 for($attempt=1;$attempt -le 3 -and -not $entered;$attempt++){
  # A busy dialog does not answer within the timeout; give it a moment and try again.
  $result=[UIntPtr]::Zero
  if([TransferFileDialogV3.Native]::SetText($field,12,[IntPtr]::Zero,$Path,2,2000,[ref]$result) -ne [IntPtr]::Zero){
   try{$entered=((Read-FileDialogText $field ($Path.Length+64) 2000) -ceq $Path)}catch{}
  }
  if(-not $entered){$report.Add(('Filename entry attempt {0} not confirmed' -f $attempt));Assert-TransferAbort;Start-Sleep -Seconds 1}
 }
 if(-not $entered){throw 'FILE_PATH_SET_VERIFICATION_FAILED'}
 $report.Add('Filename text entry: focused footer Edit; exact path verified')
 Write-Host '파일 이름 칸의 경로 입력을 확인했습니다.'
}
function Test-FileDialogStillVisible {
 param([IntPtr]$Handle)
 return [TransferFileDialogV3.Native]::IsWindowVisible($Handle)
}
function Invoke-FileDialogOpen {
 param($Dialog)
 $handle=[IntPtr]$Dialog.Current.NativeWindowHandle
 Assert-FileDialogForeground $handle
 Write-Host '열기를 실행합니다.'
 # The filename edit was validated immediately before this call.
 [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
 $deadline=[DateTime]::UtcNow.AddSeconds(2)
 do{if(-not (Test-FileDialogStillVisible $handle)){$report.Add('File dialog accepted via Enter');return};Assert-TransferAbort;Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow -lt $deadline)
 Assert-FileDialogForeground $handle
 $rect=[TransferFileDialogV3.Native]::Bounds($handle);$found=New-Object 'System.Collections.Generic.List[System.IntPtr]'
 foreach($child in @(Get-FileDialogChildren $handle)){
  if(-not [TransferFileDialogV3.Native]::IsWindowVisible($child) -or -not [TransferFileDialogV3.Native]::IsWindowEnabled($child)){continue}
  $r=[TransferFileDialogV3.Native]::Bounds($child)
  $x=(($r.Left+$r.Right)/2-$rect.Left)/($rect.Right-$rect.Left);$y=(($r.Top+$r.Bottom)/2-$rect.Top)/($rect.Bottom-$rect.Top)
  if($x -lt .72 -or $y -lt .8){continue}
  try{$caption=(Read-FileDialogText $child 64 100).Trim().Replace('&','')}catch{continue}
  if($caption -match '^(열기|Open)(\([A-Za-z]\))?$'){$found.Add($child)}
 }
 $report.Add(('Named Open controls in dialog footer: {0}' -f $found.Count))
 if($found.Count -ne 1){throw 'FILE_DIALOG_OPEN_NOT_UNIQUE'}
 Invoke-DialogControlClick $handle $found[0]
 $report.Add('Named footer Open control clicked')
}

function Get-RegistrationEvidence {
    param($Window, [string]$FileName)
    $all = $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)
    $fileSeen = $false
    $oneFileSeen = $false
    $sendSeen = $false
    $insideCount = 0
    $rect = $Window.Current.BoundingRectangle
    foreach ($element in $all) {
        try {
            $info = $element.Current
            $box = $info.BoundingRectangle
            # i-oneNet also exposes panes shifted outside its window.
            if ($info.IsOffscreen -or $box.IsEmpty -or $box.Left -lt $rect.Left -or
                $box.Right -gt $rect.Right -or $box.Top -lt $rect.Top -or $box.Bottom -gt $rect.Bottom) { continue }
            $insideCount++
            if ($info.Name.Contains($FileName)) { $fileSeen = $true }
            if ($info.Name -match '총\s*1\s*개\s*파일') { $oneFileSeen = $true }
            if ($info.Name.Trim() -eq '보내기') { $sendSeen = $true }
            $value = $null
            if ($element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$value)) {
                if ($value.Current.Value.Contains($FileName)) { $fileSeen = $true }
            }
        }
        catch { continue }
    }
    return [pscustomobject]@{
        FileSeen = $fileSeen; OneFileSeen = $oneFileSeen; SendSeen = $sendSeen; InsideElements = $insideCount
    }
}

