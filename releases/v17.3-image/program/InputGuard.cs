using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

namespace MailTransfer {
 public sealed class InputPolicy {
  public volatile bool Locked, Cancelled, Scoped;
  public int[] ScopePids=new int[0]; public long[] ScopeWindows=new long[0];
  public bool BlockScopeKey(int key,bool injected,bool up,bool windowAllowed,bool alt,bool ctrl){
   if(!Scoped||Cancelled||injected||up)return false;
   return key==0x5B||key==0x5C||key==0x5D||(alt&&(key==9||key==0x1B||key==0x20||key==0x73))||(ctrl&&key==0x1B)||!windowAllowed;
  }
  public bool BlockScopeMouse(bool injected,bool move,bool up,bool windowAllowed){return Scoped&&!Cancelled&&!injected&&!move&&!up&&!windowAllowed;}
  public bool AllowsWindow(long hwnd,int pid){foreach(long h in ScopeWindows)if(h!=0&&h==hwnd)return true;foreach(int p in ScopePids)if(p>0&&p==pid)return true;return false;}
  public string Reason="", Phase="준비 중";
  public DateTime Started=DateTime.UtcNow, LockedAt;
  public TimeSpan MaxLocked=TimeSpan.FromMinutes(3);
  readonly bool[] forwarded=new bool[256];
  public bool Key(int key,bool injected,bool down,bool up) {
   if(key==0x73) return true; // F4 is handled by the emergency handler.
   if(injected) return false;
   if(key<0||key>255) return Locked&&!Cancelled;
   if(up&&forwarded[key]) {forwarded[key]=false;return false;}
   bool block=Locked&&!Cancelled;
   if(!block&&down)forwarded[key]=true;
   return block;
  }
  public void MarkHeld(int key) {if(key>=0&&key<256)forwarded[key]=true;}
  public bool Mouse(bool injected) {return Locked&&!Cancelled&&!injected;}
  public bool MouseButton(int key,bool injected,bool down,bool up) {return Key(key,injected,down,up);}
  public void SetLocked(bool value,string phase) {
   if(Cancelled)return;
   Phase=phase;
   if(value&&!Locked)LockedAt=DateTime.UtcNow;
   Locked=value;
  }
  public void Cancel(string reason) {Reason=reason;Locked=false;Scoped=false;Cancelled=true;}
  public bool Expired(DateTime now) {
   return now-Started>TimeSpan.FromMinutes(15)||(Locked&&now-LockedAt>MaxLocked);
  }
 }
 public static class InputGuard {
  const int WM_HOTKEY=0x312,WM_QUIT=0x12,WM_UPDATE=0x8001;
  delegate IntPtr HookProc(int code,IntPtr message,IntPtr data);
  [StructLayout(LayoutKind.Sequential)] struct Point {public int X,Y;}
  [StructLayout(LayoutKind.Sequential)] struct Message {public IntPtr Hwnd;public uint Msg;public UIntPtr WParam;public IntPtr LParam;public uint Time;public Point Pt;public uint Private;}
  [StructLayout(LayoutKind.Sequential)] struct KeyData {public uint Key,Scan,Flags,Time;public UIntPtr Extra;}
  [StructLayout(LayoutKind.Sequential)] struct MouseData {public Point Pt;public uint Mouse,Flags,Time;public UIntPtr Extra;}
  [StructLayout(LayoutKind.Sequential)] struct MouseInput {public int X,Y;public uint Data,Flags,Time;public UIntPtr Extra;}
  [StructLayout(LayoutKind.Sequential)] struct Input {public uint Type;public MouseInput Mouse;}
  [DllImport("user32.dll",SetLastError=true)] static extern uint SendInput(uint count,Input[] input,int size);
  [DllImport("user32.dll",SetLastError=true)] static extern IntPtr SetWindowsHookEx(int id,HookProc callback,IntPtr module,uint thread);
  [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
  [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook,int code,IntPtr message,IntPtr data);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hwnd,int id,uint modifiers,uint key);
  [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hwnd,int id);
  [DllImport("user32.dll")] static extern int GetMessage(out Message message,IntPtr hwnd,uint min,uint max);
  [DllImport("user32.dll")] static extern bool TranslateMessage(ref Message message);
  [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref Message message);
  [DllImport("user32.dll")] static extern bool PostThreadMessage(uint thread,uint message,UIntPtr w,IntPtr l);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr CreateWindowEx(uint ex,string cls,string text,uint style,int x,int y,int w,int h,IntPtr parent,IntPtr menu,IntPtr instance,IntPtr param);
  [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr hwnd);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern bool SetWindowText(IntPtr hwnd,string text);
  [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
  [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
  [DllImport("user32.dll")] static extern IntPtr OpenInputDesktop(uint flags,bool inherit,uint access);
  [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr desktop);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(Point point);
  [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hwnd,uint flags);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
  [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
  static bool AllowedWindow(IntPtr hwnd){uint pid;IntPtr root=GetAncestor(hwnd,2);GetWindowThreadProcessId(root,out pid);return policy.AllowsWindow(root.ToInt64(),(int)pid);}
  public static void SetScope(int[] processIds){if(!active||!owner||policy.Cancelled)return;policy.ScopePids=processIds;policy.ScopeWindows=new long[]{GetConsoleWindow().ToInt64()};policy.Scoped=true;SetLocked(false,"설정 전용 · 지정 창만 조작 가능");}
  public static void ClearScope(){if(policy!=null)policy.Scoped=false;}
  static InputPolicy policy;
  static HookProc keyCallback,mouseCallback;
  static IntPtr keyHook,mouseHook,banner;
  static Thread thread;
  static uint threadId;
  static ManualResetEvent ready;
  static EventWaitHandle stopEvent;
  static RegisteredWaitHandle eventWait;
  static CancellationTokenSource cancellation;
  static Timer watchdog;
  static Mutex singleton;
  static volatile bool active,owner,stopping;
  static string name="",startupError="";
  static int ownerPid;
  static long ownerStart;
  static int controllerPid,stopOnce;
  static long controllerStart;
  static DateTime cancelledAt;
  public static bool Active {get{return active;}}
  public static bool Locked {get{return active&&policy!=null&&policy.Locked&&!policy.Cancelled;}}
  public static bool Cancelled {get{return active&&policy!=null&&(policy.Cancelled||stopEvent.WaitOne(0));}}
  public static string Phase {get{return policy==null?"":policy.Phase;}}
  public static string Reason {get{return policy==null?"":policy.Reason;}}
  public static string Name {get{return name;}}
  public static int OwnerPid {get{return ownerPid;}}
  public static long OwnerStart {get{return ownerStart;}}
  public static CancellationToken Token {get{return cancellation.Token;}}
  static void RequireName(string value) {
   if(!System.Text.RegularExpressions.Regex.IsMatch(value??"",@"^Local\\MailTransferCancel-[a-f0-9]{32}$"))throw new InvalidOperationException("INPUT_GUARD_NAME_INVALID");
  }
  public static void Start(string eventName,bool locked,string phase) {
   if(active)throw new InvalidOperationException("INPUT_GUARD_ALREADY_ACTIVE");
   RequireName(eventName);name=eventName;policy=new InputPolicy();policy.Phase=phase;
   cancellation=new CancellationTokenSource();stopEvent=new EventWaitHandle(false,EventResetMode.ManualReset,eventName);
   ownerPid=Process.GetCurrentProcess().Id;ownerStart=Process.GetCurrentProcess().StartTime.ToUniversalTime().Ticks;
   ready=new ManualResetEvent(false);startupError="";stopping=false;owner=true;stopOnce=0;controllerPid=0;
   thread=new Thread(Run);thread.IsBackground=true;thread.SetApartmentState(ApartmentState.STA);thread.Start();
   if(!ready.WaitOne(5000)||startupError!="") {Stop();throw new InvalidOperationException(startupError==""?"INPUT_GUARD_START_TIMEOUT":startupError);}
   active=true;
   eventWait=ThreadPool.RegisterWaitForSingleObject(stopEvent,delegate(object state,bool timeout){Cancel("USER_ABORTED");},null,-1,true);
   watchdog=new Timer(Tick,null,250,250);
   SetLocked(locked,phase);
  }
  public static void SetTestDeadline(int seconds) {
   if(active&&owner&&seconds>=1&&seconds<=15)policy.MaxLocked=TimeSpan.FromSeconds(seconds);
  }
  public static void Attach(string eventName,int pid,long start) {
   RequireName(eventName);name=eventName;stopEvent=EventWaitHandle.OpenExisting(eventName);
   policy=new InputPolicy();cancellation=new CancellationTokenSource();owner=false;stopping=false;ownerPid=pid;ownerStart=start;active=true;stopOnce=0;
   eventWait=ThreadPool.RegisterWaitForSingleObject(stopEvent,delegate(object state,bool timeout){Cancel("USER_ABORTED");},null,-1,true);
   watchdog=new Timer(Tick,null,100,250);
  }
  static bool DesktopAvailable() {
   IntPtr desktop=OpenInputDesktop(0,false,1);
   if(desktop==IntPtr.Zero)return false;
   CloseDesktop(desktop);return true;
  }
  static void Tick(object unused) {
   if(stopping||policy==null)return;
   try {
    if(policy.Expired(DateTime.UtcNow))Cancel("INPUT_GUARD_TIMEOUT");
    // A provider can hang a PowerShell call. End only this dedicated worker
    // after input has already been released and cancellation had five seconds.
    if(policy.Cancelled&&DateTime.UtcNow-cancelledAt>TimeSpan.FromSeconds(5)) {Process.GetCurrentProcess().Kill();return;}
    if(!owner) {
     try {using(Process p=Process.GetProcessById(ownerPid)){if(p.HasExited||p.StartTime.ToUniversalTime().Ticks!=ownerStart)Cancel("INPUT_GUARD_OWNER_EXITED");}}
     catch {Cancel("INPUT_GUARD_OWNER_EXITED");}
    } else {
     if(controllerPid>0){try{using(Process p=Process.GetProcessById(controllerPid)){if(p.HasExited||p.StartTime.ToUniversalTime().Ticks!=controllerStart)Cancel("INPUT_GUARD_OWNER_EXITED");}}catch{Cancel("INPUT_GUARD_OWNER_EXITED");}}
     if(thread==null||!thread.IsAlive)Cancel("INPUT_GUARD_THREAD_EXITED");
     if((policy.Locked||policy.Scoped)&&!DesktopAvailable())Cancel("INPUT_DESKTOP_CHANGED");
     PostThreadMessage(threadId,WM_UPDATE,UIntPtr.Zero,IntPtr.Zero);
    }
   }catch {Cancel("INPUT_GUARD_ERROR");}
  }
  public static void SetLocked(bool value,string phase) {
   if(!active||!owner)return;
   policy.SetLocked(value,phase);
   PostThreadMessage(threadId,WM_UPDATE,UIntPtr.Zero,IntPtr.Zero);
  }
  public static bool MoveCursor(int x,int y) {
   if(Cancelled)return false;
   int left=GetSystemMetrics(76),top=GetSystemMetrics(77),width=GetSystemMetrics(78),height=GetSystemMetrics(79);
   if(width<2||height<2)return false;
   Input[] input=new Input[1];
   input[0].Mouse.X=(int)Math.Max(0,Math.Min(65535,((long)x-left)*65535/(width-1)));
   input[0].Mouse.Y=(int)Math.Max(0,Math.Min(65535,((long)y-top)*65535/(height-1)));
   input[0].Mouse.Flags=0xC001; // MOVE | ABSOLUTE | VIRTUALDESK; flagged as injected.
   return SendInput(1,input,Marshal.SizeOf(typeof(Input)))==1;
  }
  public static void Cancel(string reason) {
   if(policy==null)return;
   if(Interlocked.Exchange(ref stopOnce,1)!=0)return;
   // Release input immediately; do not run socket cancellation callbacks in a hook.
   cancelledAt=DateTime.UtcNow;policy.Cancel(reason);
   try{stopEvent.Set();}catch{}
   ThreadPool.QueueUserWorkItem(delegate(object state){try{cancellation.Cancel();}catch{}});
   if(owner)PostThreadMessage(threadId,WM_UPDATE,UIntPtr.Zero,IntPtr.Zero);
  }
  public static bool RequestStop(string eventName) {
   RequireName(eventName);
   try{using(EventWaitHandle handle=EventWaitHandle.OpenExisting(eventName)){return handle.Set();}}catch{return false;}
  }
  public static bool IsStopRequested(string eventName) {
   RequireName(eventName);
   try{using(EventWaitHandle handle=EventWaitHandle.OpenExisting(eventName)){return handle.WaitOne(0);}}catch{return false;}
  }
  public static void WatchController(int pid,long start) {controllerPid=pid;controllerStart=start;}
  static IntPtr Keyboard(int code,IntPtr message,IntPtr pointer) {
   if(code>=0) {
    KeyData data=(KeyData)Marshal.PtrToStructure(pointer,typeof(KeyData));
    int msg=message.ToInt32();bool down=msg==0x100||msg==0x104,up=msg==0x101||msg==0x105;
    if(data.Key==0x73){if(down)Cancel("USER_ABORTED");return new IntPtr(1);}
    bool injected=(data.Flags&0x10)!=0;
    if(policy.Scoped&&!policy.Cancelled&&!injected){
     // Always forward key-up to avoid stuck modifiers after a denied focus switch.
     bool alt=(GetAsyncKeyState(0x12)&0x8000)!=0,ctrl=(GetAsyncKeyState(0x11)&0x8000)!=0;
     if(up)return CallNextHookEx(keyHook,code,message,pointer);
     if(policy.BlockScopeKey((int)data.Key,injected,up,AllowedWindow(GetForegroundWindow()),alt,ctrl))return new IntPtr(1);
    }
    if(policy.Key((int)data.Key,(data.Flags&0x10)!=0,down,up))return new IntPtr(1);
   }
   return CallNextHookEx(keyHook,code,message,pointer);
  }
  static IntPtr Mouse(int code,IntPtr message,IntPtr pointer) {
   if(code>=0) {
    MouseData data=(MouseData)Marshal.PtrToStructure(pointer,typeof(MouseData));
    int msg=message.ToInt32(),key=0;bool down=false,up=false;
    if(msg==0x201||msg==0x202){key=1;down=msg==0x201;up=!down;}
    if(msg==0x204||msg==0x205){key=2;down=msg==0x204;up=!down;}
    if(msg==0x207||msg==0x208){key=4;down=msg==0x207;up=!down;}
    if(policy.Scoped&&!policy.Cancelled&&(data.Flags&1)==0&&msg!=0x200){
     if(up)return CallNextHookEx(mouseHook,code,message,pointer);
     if(policy.BlockScopeMouse(false,false,up,AllowedWindow(WindowFromPoint(data.Pt))))return new IntPtr(1);
    }
    bool block=key!=0?policy.MouseButton(key,(data.Flags&1)!=0,down,up):policy.Mouse((data.Flags&1)!=0);
    if(block)return new IntPtr(1);
   }
   return CallNextHookEx(mouseHook,code,message,pointer);
  }
  static void Run() {
   bool claimed=false,hotkey=false;
   try {
    threadId=GetCurrentThreadId();
    singleton=new Mutex(false,@"Local\MailTransferInteractiveGuard");
    try{claimed=singleton.WaitOne(0);}catch(AbandonedMutexException){claimed=true;}
    if(!claimed)throw new InvalidOperationException("ANOTHER_INPUT_GUARD_IS_RUNNING");
    if(!DesktopAvailable())throw new InvalidOperationException("INPUT_DESKTOP_UNAVAILABLE");
    for(int key=1;key<256;key++)if((GetAsyncKeyState(key)&0x8000)!=0)policy.MarkHeld(key);
    hotkey=RegisterHotKey(IntPtr.Zero,1,0x4000,0x73);
    if(!hotkey)throw new InvalidOperationException("F4_HOTKEY_UNAVAILABLE");
    keyCallback=Keyboard;mouseCallback=Mouse;
    keyHook=SetWindowsHookEx(13,keyCallback,GetModuleHandle(null),0);
    mouseHook=SetWindowsHookEx(14,mouseCallback,GetModuleHandle(null),0);
    if(keyHook==IntPtr.Zero||mouseHook==IntPtr.Zero)throw new InvalidOperationException("INPUT_HOOK_UNAVAILABLE");
    banner=CreateWindowEx(0x08000088,"STATIC","메일 작업 준비 중 · F4 중지",0x98000001,Math.Max(0,(GetSystemMetrics(0)-520)/2),0,520,46,IntPtr.Zero,IntPtr.Zero,GetModuleHandle(null),IntPtr.Zero);
    ready.Set();
    Message msg;
    while(GetMessage(out msg,IntPtr.Zero,0,0)>0) {
     if(msg.Msg==WM_HOTKEY)Cancel("USER_ABORTED");
     if(msg.Msg==WM_UPDATE&&banner!=IntPtr.Zero)SetWindowText(banner,(policy.Cancelled?"중지됨 · 입력 제한 해제":policy.Phase+(policy.Locked?" · 입력 제한 중":(policy.Scoped?" · 지정 창만 입력":" · 입력 가능")))+"\r\nF4: 즉시 해제·중지");
     TranslateMessage(ref msg);DispatchMessage(ref msg);
    }
   }catch(Exception e){startupError=e is InvalidOperationException?e.Message:"INPUT_GUARD_START_FAILED";if(ready!=null)ready.Set();}
   finally {
    if(policy!=null){policy.Locked=false;policy.Scoped=false;}
    if(keyHook!=IntPtr.Zero){UnhookWindowsHookEx(keyHook);keyHook=IntPtr.Zero;}
    if(mouseHook!=IntPtr.Zero){UnhookWindowsHookEx(mouseHook);mouseHook=IntPtr.Zero;}
    if(hotkey)UnregisterHotKey(IntPtr.Zero,1);
    if(banner!=IntPtr.Zero){DestroyWindow(banner);banner=IntPtr.Zero;}
    if(claimed)singleton.ReleaseMutex();
    if(singleton!=null){singleton.Dispose();singleton=null;}
   }
  }
  public static void Stop() {
   stopping=true;
   if(policy!=null){policy.Locked=false;policy.Scoped=false;}
   if(watchdog!=null){watchdog.Dispose();watchdog=null;}
   if(eventWait!=null){eventWait.Unregister(null);eventWait=null;}
   if(owner&&threadId!=0)PostThreadMessage(threadId,WM_QUIT,UIntPtr.Zero,IntPtr.Zero);
   if(owner&&thread!=null)thread.Join(2000);
   if(keyHook!=IntPtr.Zero){UnhookWindowsHookEx(keyHook);keyHook=IntPtr.Zero;}
   if(mouseHook!=IntPtr.Zero){UnhookWindowsHookEx(mouseHook);mouseHook=IntPtr.Zero;}
   active=false;
  }
 }
}
