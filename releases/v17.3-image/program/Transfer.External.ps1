#requires -Version 5.1
# Shared registration adapter for internal and external sender processes.
param([string]$ProgressFile)
$script:ExternalSenderProgressFile=$ProgressFile
$script:ExternalFileDialogProcessId=0
function Write-ExternalTransferProgress {
 param([string]$Stage,[string]$ErrorCode='',[string]$Result='WORKING')
 try{Write-BridgeJson $script:ExternalSenderProgressFile @{stage=$Stage;error=$ErrorCode;result=$Result;at=[DateTime]::UtcNow.ToString('o')}}catch{}
}
function Initialize-ExternalFileDialogWindows {
 if('MailTransfer.ExternalFileWindows' -as [type]){return}
 Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace MailTransfer { public class ExternalFileWindow {
 public long Handle;public uint ProcessId;public string Title,ClassName;
}
public static class ExternalFileWindows {
 delegate bool EnumProc(IntPtr h,IntPtr l);
 [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback,IntPtr l);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h,StringBuilder t,int n);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h,StringBuilder t,int n);
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
 public static ExternalFileWindow[] Find(uint pid) {
  List<ExternalFileWindow> result=new List<ExternalFileWindow>();
  EnumWindows(delegate(IntPtr h,IntPtr l) {
   uint owner;GetWindowThreadProcessId(h,out owner);
   if(owner!=pid || !IsWindowVisible(h))return true;
   StringBuilder title=new StringBuilder(256),cls=new StringBuilder(256);
   GetWindowText(h,title,title.Capacity);GetClassName(h,cls,cls.Capacity);
   string name=title.ToString();
   if(cls.ToString()=="#32770" || name=="파일 선택" || name=="열기" || name=="파일 열기" || name=="Open" || name=="Select File")
    result.Add(new ExternalFileWindow {Handle=h.ToInt64(),ProcessId=owner,Title=name,ClassName=cls.ToString()});
   return true;
  },IntPtr.Zero);return result.ToArray();
 }
}}
'@
}
function Get-ExternalFileDialogWindows {
 param([int]$ProcessId)
 Initialize-ExternalFileDialogWindows
 return @([MailTransfer.ExternalFileWindows]::Find([uint32]$ProcessId))
}
function Test-ExternalFileDialogOwner {
 param([IntPtr]$Handle,[int]$ProcessId)
 try{$owner=[uint32]0;[void][MailBridge.Native]::GetWindowThreadProcessId($Handle,[ref]$owner);return [int]$owner -eq $ProcessId}catch{return $false}
}
function Assert-FileDialogForeground {
 param([IntPtr]$Handle)
 Assert-TransferAbort
 if(-not (Test-ExternalFileDialogOwner $Handle $script:ExternalFileDialogProcessId)){throw 'FILE_DIALOG_OWNER_CHANGED'}
 if([MailBridge.Native]::GetForegroundWindow() -ne $Handle){
  if(-not [MailBridge.Native]::IsWindowVisible($Handle)){throw 'FILE_DIALOG_NOT_FOREGROUND'}
  Focus-TransferWindow ([pscustomobject]@{Current=[pscustomobject]@{NativeWindowHandle=$Handle}})
  if([MailBridge.Native]::GetForegroundWindow() -ne $Handle){throw 'FILE_DIALOG_NOT_FOREGROUND'}
  $script:report.Add('External picker restored after another window covered it')
 }
}
function Register-TransferFile {
 param($Window,$Plus,[string]$Path)
 $dialogHandle=[IntPtr]::Zero
 $script:ExternalFileDialogProcessId=[int]$Window.Current.ProcessId
 try{
  Write-ExternalTransferProgress 'CLICK_REGISTER_BUTTON'
  Invoke-TransferPoint $Window $Plus
  Write-ExternalTransferProgress 'WAIT_FILE_DIALOG'
  $deadline=[DateTime]::UtcNow.AddSeconds(15);$dialog=$null
  do{
   $windows=@(Get-ExternalFileDialogWindows $script:ExternalFileDialogProcessId | Where-Object {[IntPtr]$_.Handle -ne [IntPtr]$Window.Current.NativeWindowHandle})
   if($windows.Count -gt 1){throw 'FILE_DIALOG_NOT_UNIQUE'}
   if($windows.Count -eq 1){
    $info=$windows[0];$dialogHandle=[IntPtr]$info.Handle
    $dialog=[pscustomobject]@{Current=[pscustomobject]@{NativeWindowHandle=$dialogHandle;ProcessId=$info.ProcessId;Name=$info.Title;ClassName=$info.ClassName}}
    break
   }
   Assert-TransferAbort;Start-Sleep -Milliseconds 200
  }while([DateTime]::UtcNow -lt $deadline)
  if($null -eq $dialog){throw 'FILE_DIALOG_NOT_OPENED'}
  Assert-FileDialogForeground $dialogHandle
  Write-ExternalTransferProgress 'SET_FILE_PATH'
  Set-FileDialogProbePath $dialog $Path
  Write-ExternalTransferProgress 'FILE_PATH_VERIFIED'
  Write-ExternalTransferProgress 'OPEN_FILE'
  Invoke-FileDialogOpen $dialog
  $deadline=[DateTime]::UtcNow.AddSeconds(10)
  while((Test-FileDialogStillVisible $dialogHandle) -and [DateTime]::UtcNow -lt $deadline){Assert-TransferAbort;Start-Sleep -Milliseconds 200}
  if(Test-FileDialogStillVisible $dialogHandle){throw 'FILE_DIALOG_DID_NOT_CLOSE'}
  Write-ExternalTransferProgress 'FILE_REGISTERED'
  Start-Sleep -Milliseconds 500
 }catch{
  $code='FILE_REGISTRATION_FAILED';if($_.Exception.Message -cmatch '^[A-Z][A-Z0-9_]+$'){$code=$_.Exception.Message}
  $script:report.Add(('External registration error: '+$code))
  Write-ExternalTransferProgress 'REGISTER_FILE' $code 'FAILED'
  if($dialogHandle -ne [IntPtr]::Zero -and (Test-ExternalFileDialogOwner $dialogHandle $script:ExternalFileDialogProcessId) -and [MailBridge.Native]::IsWindowVisible($dialogHandle)){
   [void][MailBridge.Native]::PostMessage($dialogHandle,0x10,[IntPtr]::Zero,[IntPtr]::Zero)
   $script:report.Add('External picker cancelled after failure; no send clicked')
  }
  throw
 }finally{$script:ExternalFileDialogProcessId=0}
}
Write-ExternalTransferProgress 'PREPARING'

# Both network roles load these overrides after the original sender library.
$script:ExternalOriginalRegistrationEvidence=${function:Get-RegistrationEvidence}
function Get-RegistrationEvidence {
 param($Window,[string]$FileName)
 $evidence=& $script:ExternalOriginalRegistrationEvidence $Window $FileName
 if($evidence.FileSeen -or $FileName -cnotmatch '^MailTransfer-(?:(?:Probe|Request|Result)-[a-f0-9]{32}\.txt|Attachment-[a-f0-9]{32}(?:\.[^\\/:*?"<>|\x00-\x1f]{1,20})?)$'){return $evidence}
 # FTC may hide the .txt extension, but the entire unique request ID must match.
 $stem=[IO.Path]::GetFileNameWithoutExtension($FileName)
 $pattern='(?<![A-Za-z0-9_-])'+[regex]::Escape($stem)+'(?:'+[regex]::Escape([IO.Path]::GetExtension($FileName))+')?(?![A-Za-z0-9_.-])'
 try{
  $rect=$Window.Current.BoundingRectangle
  $all=$Window.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
  foreach($element in $all){try{
   $info=$element.Current;$box=$info.BoundingRectangle
   if($info.IsOffscreen -or $box.IsEmpty -or $box.Left -lt $rect.Left -or $box.Right -gt $rect.Right -or $box.Top -lt $rect.Top -or $box.Bottom -gt $rect.Bottom){continue}
   if([regex]::IsMatch([string]$info.Name,$pattern)){$evidence.FileSeen=$true;break}
   $value=$null
   if($element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$value) -and [regex]::IsMatch([string]$value.Current.Value,$pattern)){$evidence.FileSeen=$true;break}
  }catch{}}
 }catch{}
 return $evidence
}
function Wait-ExternalRegistration {
 param($Window,$Settings,[string]$FileName,[int]$TimeoutSeconds=12)
 $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
 $failure='REGISTRATION_NOT_CONFIRMED';$observations=0
 do{
  Assert-TransferAbort
  Move-TransferCursorAway $Window
  $observations++
  $evidence=Get-RegistrationEvidence $Window $FileName
  $hash=Get-SenderHash $Window
  $changed=$hash -cne $Settings.emptyHash
  # An exact, unique filename and one-file count are stronger than an image hash.
  # If accessibility does not expose the filename, retain calibrated image checks.
  $registered=$changed -or ($evidence.FileSeen -and $evidence.OneFileSeen)
  if(-not$registered){$failure='REGISTRATION_NOT_CONFIRMED'}
  elseif($Settings.requireFileEvidence -and -not$evidence.FileSeen){$failure='REGISTERED_FILENAME_NOT_CONFIRMED'}
  elseif($Settings.requireCountEvidence -and -not$evidence.OneFileSeen){$failure='ONE_REGISTERED_FILE_NOT_CONFIRMED'}
  elseif((Get-SendButtonHash $Window $Settings.send) -cne $Settings.sendButtonHash){$failure='SEND_BUTTON_STATE_CHANGED'}
  else{
   $script:report.Add(('External registration confirmed after {0} observations; imageChanged={1}; filename={2}; oneFile={3}' -f $observations,$changed,$evidence.FileSeen,$evidence.OneFileSeen))
   Write-ExternalTransferProgress 'REGISTRATION_CONFIRMED'
   return $evidence
  }
  Write-ExternalTransferProgress 'WAIT_REGISTRATION' $failure
  Start-Sleep -Milliseconds 200
 }while([DateTime]::UtcNow -lt $deadline)
 $script:report.Add(('External registration not confirmed after {0} observations; imageChanged={1}; filename={2}; oneFile={3}; error={4}' -f $observations,$changed,$evidence.FileSeen,$evidence.OneFileSeen,$failure))
 throw $failure
}
function Invoke-CalibratedSend {
 param($Window,$Settings,[string]$Path,[hashtable]$State)
 $name=[IO.Path]::GetFileName($Path)
 $State.stage='REGISTER_FILE'
 Register-TransferFile $Window $Settings.plus $Path
 $State.stage='WAIT_REGISTRATION'
 $evidence=Wait-ExternalRegistration $Window $Settings $name
 # Preserve the original one-click send and reset confirmation behavior.
 $State.stage='CLICK_SEND_ONCE'
 Invoke-TransferPoint $Window $Settings.send;$State.clicked=$true
 $State.stage='WAIT_EMPTY_SEND_LIST'
 Wait-SenderReset $Window $Settings.emptyHash $name $evidence.FileSeen
}
