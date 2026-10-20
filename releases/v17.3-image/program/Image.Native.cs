using System;
using System.Text;
using System.Runtime.InteropServices;
namespace EXMailImageTrial {
 public static class Native {
  [StructLayout(LayoutKind.Sequential)]public struct Rect{public int Left,Top,Right,Bottom;}
  [StructLayout(LayoutKind.Sequential)]public struct Point{public int X,Y;}
  [DllImport("user32.dll")]public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")]public static extern short GetAsyncKeyState(int key);
  [DllImport("user32.dll")]public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")]public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")]public static extern bool GetClientRect(IntPtr h,out Rect r);
  [DllImport("user32.dll")]public static extern bool ClientToScreen(IntPtr h,ref Point p);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)]static extern int GetWindowText(IntPtr h,StringBuilder text,int size);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)]static extern int GetClassName(IntPtr h,StringBuilder text,int size);
  [DllImport("user32.dll")]static extern IntPtr GetWindow(IntPtr h,uint command);
  [DllImport("user32.dll")]static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
  public static string GetTitle(IntPtr h){var b=new StringBuilder(512);GetWindowText(h,b,b.Capacity);return b.ToString();}
  public static string GetClass(IntPtr h){var b=new StringBuilder(256);GetClassName(h,b,b.Capacity);return b.ToString();}
  public static bool OwnedBy(IntPtr dialog,IntPtr window){
   uint a,b;GetWindowThreadProcessId(dialog,out a);GetWindowThreadProcessId(window,out b);
   if(a==0||a!=b)return false;
   for(int i=0;i<16;i++){dialog=GetWindow(dialog,4);if(dialog==window)return true;if(dialog==IntPtr.Zero)return false;}
   return false;
  }
 }
}

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