#requires -Version 5.1
function Initialize-MailPowerRequests {
 if('MailTransfer.PowerRequest' -as [type]){return}
 Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace MailTransfer {
 public sealed class PowerHandle : SafeHandleZeroOrMinusOneIsInvalid {
  public PowerHandle() : base(true) {}
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  protected override bool ReleaseHandle() { return CloseHandle(handle); }
 }
 public static class PowerRequest {
  [DllImport("kernel32.dll",SetLastError=true)] static extern PowerHandle PowerCreateRequest(IntPtr context);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool PowerSetRequest(PowerHandle h,int requestType);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool PowerClearRequest(PowerHandle h,int requestType);
  public static PowerHandle Begin() {
   IntPtr reason=Marshal.StringToHGlobalUni("Mail transfer is running");
   // REASON_CONTEXT: Version, Flags, followed by the union. Allocate room for its largest member on either architecture.
   IntPtr context=Marshal.AllocHGlobal(64);
   PowerHandle handle=null;
   try {
    for(int i=0;i<64;i++) Marshal.WriteByte(context,i,0);
    Marshal.WriteInt32(context,0,0);Marshal.WriteInt32(context,4,1);Marshal.WriteIntPtr(context,8,reason);
    handle=PowerCreateRequest(context);
    if(handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
    if(!PowerSetRequest(handle,1)) throw new Win32Exception(Marshal.GetLastWin32Error());
    if(!PowerSetRequest(handle,0)) throw new Win32Exception(Marshal.GetLastWin32Error());
    return handle;
   } catch { if(handle!=null) handle.Dispose();throw; }
   finally { Marshal.FreeHGlobal(context);Marshal.FreeHGlobal(reason); }
  }
  public static void End(PowerHandle handle) {
   if(handle==null || handle.IsClosed) return;
   try { if(!handle.IsInvalid) {PowerClearRequest(handle,0);PowerClearRequest(handle,1);} }
   finally {handle.Dispose();}
  }
 }
}
'@
}
function Start-MailKeepAwake {
 if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'WINDOWS_REQUIRED'}
 Initialize-MailPowerRequests
 $handle=[MailTransfer.PowerRequest]::Begin()
 Write-Host '실행 중 화면 꺼짐·절전 방지를 요청했습니다. 종료하면 자동 해제됩니다.'
 Write-Host '수동 잠금과 회사 정책에 따른 자동 잠금은 이 기능으로 막을 수 없습니다.'
 return $handle
}
function Stop-MailKeepAwake {
 param($Handle)
 if($null -ne $Handle){[MailTransfer.PowerRequest]::End($Handle)}
}
