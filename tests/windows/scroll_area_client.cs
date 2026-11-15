// Cross-process actual-entry checks. Geometry assertions supplement, not replace,
// independent visual review of the emitted screenshots.
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Automation;

public class ScrollAreaClient {
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int L,T,R,B; }
  [StructLayout(LayoutKind.Sequential)] struct BAR {
    public uint size; public RECT rect; public int line,top,bottom,reserved;
    [MarshalAs(UnmanagedType.ByValArray,SizeConst=6)] public uint[] states;
  }
  [StructLayout(LayoutKind.Sequential)] struct MOUSE { public int x,y; public uint data,flags,time; public UIntPtr extra; }
  [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint kind; public MOUSE mouse; }
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h,out RECT r);
  [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr context);
  [DllImport("user32.dll")] static extern IntPtr GetThreadDpiAwarenessContext();
  [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
  [DllImport("user32.dll")] static extern IntPtr GetWindowDpiAwarenessContext(IntPtr window);
  [DllImport("user32.dll")] static extern bool AreDpiAwarenessContextsEqual(IntPtr a, IntPtr b);
  [DllImport("user32.dll")] static extern int GetAwarenessFromDpiAwarenessContext(IntPtr context);
  [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h,out RECT r);
  [DllImport("user32.dll")] static extern uint GetWindowLong(IntPtr h,int index);
  [DllImport("user32.dll")] static extern bool AdjustWindowRectExForDpi(ref RECT r,uint style,bool menu,uint exStyle,uint dpi);
  [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool SetCursorPos(int x,int y);
  [DllImport("user32.dll")] static extern uint SendInput(uint n,INPUT[] p,int size);
  [DllImport("user32.dll")] static extern bool GetScrollBarInfo(IntPtr h,int id,ref BAR bar);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int height,uint flags);
  static int failures; static string output;
  static void Check(bool ok,string message) { Console.WriteLine((ok?"[OK] ":"[FAILED] ")+message); if(!ok) failures++; }
  static bool Wait(Func<bool> predicate) { for(int i=0;i<40;i++) { if(predicate())return true;Thread.Sleep(75); }return predicate(); }
  static AutomationElement Find(AutomationElement root,string name,ControlType type) {
    return root.FindFirst(TreeScope.Descendants,new AndCondition(new PropertyCondition(AutomationElement.NameProperty,name),new PropertyCondition(AutomationElement.ControlTypeProperty,type)));
  }
  static AutomationElement Edit(AutomationElement root) { return root.FindFirst(TreeScope.Descendants,new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.Edit)); }
  static IntPtr H(AutomationElement e) { return new IntPtr(e.Current.NativeWindowHandle); }
  static RECT Rect(IntPtr h) { RECT r;if(!GetWindowRect(h,out r))throw new Exception("GetWindowRect failed");return r; }
  static void Invoke(AutomationElement root,string name) { var e=Find(root,name,ControlType.Button);if(e==null)throw new Exception("missing button "+name);((InvokePattern)e.GetCurrentPattern(InvokePattern.Pattern)).Invoke();Thread.Sleep(180); }
  static string Value(AutomationElement e) { return ((ValuePattern)e.GetCurrentPattern(ValuePattern.Pattern)).Current.Value; }
  static void Mouse(uint flags,uint data) { var p=new INPUT[1];p[0].mouse.flags=flags;p[0].mouse.data=data;if(SendInput(1,p,Marshal.SizeOf(typeof(INPUT)))!=1)throw new Exception("SendInput failed"); }
  static void Shot(string name,IntPtr h) {
    var watch=Stopwatch.StartNew();
    var element=AutomationElement.FromHandle(h);object pattern;
    bool idle=element.TryGetCurrentPattern(WindowPattern.Pattern,out pattern) &&
      ((WindowPattern)pattern).WaitForInputIdle(5000);
    Console.WriteLine("[READY] "+name+" inputIdle="+idle+" waitMs="+watch.ElapsedMilliseconds);
    Check(idle,"capture reaches bounded input-idle: "+name);
    Thread.Sleep(600);var r=Rect(h);using(var b=new Bitmap(r.R-r.L,r.B-r.T)) {
      using(var g=Graphics.FromImage(b))g.CopyFromScreen(r.L,r.T,0,0,b.Size);
      b.Save(Path.Combine(output,name+".png"),ImageFormat.Png);
    }
  }
  static void DragBottom(IntPtr view) {
    var bar=new BAR();bar.size=(uint)Marshal.SizeOf(typeof(BAR));bar.states=new uint[6];
    if(!GetScrollBarInfo(view,-5,ref bar))throw new Exception("GetScrollBarInfo failed");
    int x=bar.rect.R-(bar.rect.R-bar.rect.L)/2,y=bar.rect.T+(bar.top+bar.bottom)/2;
    SetCursorPos(x,y);Mouse(2,0);Thread.Sleep(120);
    try { for(int i=1;i<=8;i++){SetCursorPos(x,y+(bar.rect.B-bar.line-2-y)*i/8);Thread.Sleep(45);} }
    finally {Mouse(4,0);}
    Thread.Sleep(300);
  }
  // Cursor input, Win32/UIA rectangles and captured screen pixels only describe
  // one space while this driver runs in the same PerMonitorV2 context as the
  // application, so the gate requires PMv2, prints what it actually got and fails
  // closed; there is no system-aware fallback.
  const int ExitDpiApiMissing = 21;
  const int ExitNotPerMonitorV2 = 22;
  const int ExitWindowDpiUnavailable = 23;
  static readonly IntPtr PerMonitorV2Context = new IntPtr(-4);

  static string DescribeDpiContext(IntPtr context) {
    if(context==IntPtr.Zero) return "none";
    if(AreDpiAwarenessContextsEqual(context,PerMonitorV2Context)) return "per_monitor_v2";
    // This API only separates unaware/system/per-monitor; the equality check above
    // is what distinguishes PMv1 from PMv2.
    switch(GetAwarenessFromDpiAwarenessContext(context)) {
      case 0: return "unaware";
      case 1: return "system";
      case 2: return "per_monitor_v1";
      default: return "unknown";
    }
  }

  static int ReportMissingDpiApi() {
    Console.WriteLine("[DPI] unsupported: the user32 DPI awareness APIs are missing on this Windows");
    return ExitDpiApiMissing;
  }

  static int RequireProcessPerMonitorV2() {
    try {
      // false is expected when an embedded manifest already fixed the context, so
      // the effective context decides; anything but PMv2 is a hard failure.
      bool set=SetProcessDpiAwarenessContext(PerMonitorV2Context);
      IntPtr effective=GetThreadDpiAwarenessContext();
      Console.WriteLine("[DPI] setPerMonitorV2="+set+" effective="+DescribeDpiContext(effective));
      if(!AreDpiAwarenessContextsEqual(effective,PerMonitorV2Context)) return ExitNotPerMonitorV2;
      return 0;
    } catch(EntryPointNotFoundException) { return ReportMissingDpiApi(); }
    catch(DllNotFoundException) { return ReportMissingDpiApi(); }
  }

  static int RequireWindowPerMonitorV2(IntPtr window,string label) {
    IntPtr context;
    try { context=GetWindowDpiAwarenessContext(window); }
    catch(EntryPointNotFoundException) { return ReportMissingDpiApi(); }
    catch(DllNotFoundException) { return ReportMissingDpiApi(); }
    Console.WriteLine("[DPI] "+label+" window="+DescribeDpiContext(context));
    return AreDpiAwarenessContextsEqual(context,PerMonitorV2Context) ? 0 : ExitNotPerMonitorV2;
  }

  // SetWindowPos takes outer pixels. Converting the requested client DIP box once
  // keeps every DPI on the same business space instead of shrinking at high DPI.
  static RECT OuterForClientDip(int widthDip,int heightDip,uint dpi,uint style,uint exStyle) {
    var r=new RECT();
    r.R=(int)Math.Round(widthDip*dpi/96.0);
    r.B=(int)Math.Round(heightDip*dpi/96.0);
    if(!AdjustWindowRectExForDpi(ref r,style,false,exStyle,dpi)) throw new InvalidOperationException("AdjustWindowRectExForDpi failed");
    return r;
  }
  static int Pixels(int dip,uint dpi) { return (int)Math.Round(dip*dpi/96.0); }
  static int DpiCheck(bool condition, string message)
  {
      Console.WriteLine((condition ? "[DPI-OK] " : "[DPI-FAILED] ") + message);
      return condition ? 0 : 1;
  }

  // Executable contract for the gate itself. It creates no window and touches no
  // product code: only this driver's own process/thread DPI context is injected.
  static int DpiGateContract()
  {
      int failures = 0;
      IntPtr system = new IntPtr(-2);
      IntPtr perMonitorV1 = new IntPtr(-3);
      failures += DpiCheck(RequireProcessPerMonitorV2() == 0, "first gate pass enters per_monitor_v2");
      bool repeated = SetProcessDpiAwarenessContext(PerMonitorV2Context);
      failures += DpiCheck(!repeated, "a repeated SetProcessDpiAwarenessContext returns false");
      failures += DpiCheck(RequireProcessPerMonitorV2() == 0, "the gate still passes when the setter returned false");
      IntPtr previous = SetThreadDpiAwarenessContext(system);
      try
      {
          failures += DpiCheck(DescribeDpiContext(GetThreadDpiAwarenessContext()) == "system",
              "the description names the injected system context");
          failures += DpiCheck(RequireProcessPerMonitorV2() == ExitNotPerMonitorV2,
              "the gate rejects the injected system context with " + ExitNotPerMonitorV2);
          failures += DpiCheck(SetThreadDpiAwarenessContext(perMonitorV1) != IntPtr.Zero,
              "the driver can inject a per-monitor V1 context for the description check");
          failures += DpiCheck(DescribeDpiContext(GetThreadDpiAwarenessContext()) == "per_monitor_v1",
              "the description separates per-monitor V1 from per_monitor_v2");
      }
      finally
      {
          SetThreadDpiAwarenessContext(previous);
      }
      failures += DpiCheck(DescribeDpiContext(GetThreadDpiAwarenessContext()) == "per_monitor_v2",
          "the previous PerMonitorV2 context is restored");
      failures += DpiCheck(DescribeDpiContext(PerMonitorV2Context) == "per_monitor_v2",
          "the PerMonitorV2 pseudo-handle is described as per_monitor_v2");
      Console.WriteLine("[DPI] contract failures=" + failures);
      return failures == 0 ? 0 : 1;
  }

  public static int Main(string[] args) {
    if (args.Length == 1 && args[0] == "--dpi-contract") return DpiGateContract();
    int dpiGate=RequireProcessPerMonitorV2(); if(dpiGate!=0) return dpiGate;
    if(args.Length!=3)return 2;output=args[1];Directory.CreateDirectory(output);
    var p=Process.Start(new ProcessStartInfo(args[0]){UseShellExecute=false});File.WriteAllText(args[2],p.Id.ToString());
    try {
      IntPtr main=IntPtr.Zero;
      Check(Wait(delegate{p.Refresh();main=p.MainWindowHandle;return main!=IntPtr.Zero;}),"actual example window starts");
      if(main==IntPtr.Zero)return 3;SetForegroundWindow(main);Thread.Sleep(300);
      var root=AutomationElement.FromHandle(main);var edit=Edit(root);if(edit==null)throw new Exception("missing native EDIT");
      var original=H(edit);var body=GetParent(GetParent(original));var view=GetParent(body);
      int windowGate=RequireWindowPerMonitorV2(view,"viewport"); if(windowGate!=0) return windowGate;
      uint dpi=GetDpiForWindow(view);
      if(dpi==0) { Console.WriteLine("[DPI] GetDpiForWindow returned 0 for the viewport"); return ExitWindowDpiUnavailable; }
      int viewport=Rect(view).B-Rect(view).T;
      Check(viewport==Pixels(240,dpi),"actual viewport is the declared 240 DIP ("+viewport+" px at "+dpi+" DPI)");
      Shot("scroll-initial-before-edit",main);
      ((ValuePattern)edit.GetCurrentPattern(ValuePattern.Pattern)).SetValue("persistent draft");
      Check(Wait(delegate{return Value(edit)=="persistent draft";}),"State.update accepts cross-process native value");
      Shot("scroll-light-top",main);
      var start=Rect(body);var vr=Rect(view);SetCursorPos(vr.L+60,vr.T+100);edit.SetFocus();Mouse(0x800,unchecked((uint)-120));
      Check(Wait(delegate{return Rect(body).T<start.T;}),"physical wheel moves persistent content");
      DragBottom(view);
      var last=Find(root,"Last action",ControlType.Button);var lastRect=Rect(H(last));vr=Rect(view);
      Check(lastRect.T>=vr.T && lastRect.B<=vr.B,"physical scrollbar thumb drag makes last action visible");
      Check(H(edit)==original && Value(edit)=="persistent draft","drag keeps EDIT identity and accepted draft");
      SetCursorPos((lastRect.L+lastRect.R)/2,(lastRect.T+lastRect.B)/2);Mouse(2,0);Mouse(4,0);
      Check(Wait(delegate{return Find(root,"Last action reached",ControlType.Text)!=null;}),"physical bottom action click reaches business handler");
      Shot("scroll-light-bottom",main);
      Invoke(root,"Toggle theme");Shot("scroll-dark-bottom",main);
      Check(H(Edit(root))==original && Value(edit)=="persistent draft","theme switch preserves EDIT and draft");
      // examples/ui_controls/scroll_area.nim needs the 240 DIP viewport plus 20 DIP
      // padding on both sides and the label/row/checkbox/gap block above it, so the
      // narrow target stays a complete layout in DIP on every DPI instead of
      // collapsing at 150% and turning a DPI bug into a product failure.
      const int NarrowClientDipWidth=360;
      const int NarrowClientDipHeight=420;
      uint resizeDpi=GetDpiForWindow(main);
      if(resizeDpi==0) { Console.WriteLine("[DPI] GetDpiForWindow returned 0 for the page"); return ExitWindowDpiUnavailable; }
      RECT outer=OuterForClientDip(NarrowClientDipWidth,NarrowClientDipHeight,resizeDpi,
        (uint)GetWindowLong(main,-16),(uint)GetWindowLong(main,-20));
      var beforeView=Rect(view);
      int beforeWidthDip=(int)Math.Round((beforeView.R-beforeView.L)*96.0/dpi);
      Check(SetWindowPos(main,IntPtr.Zero,80,80,outer.R-outer.L,outer.B-outer.T,4),
        "resize to a narrow "+NarrowClientDipWidth+"x"+NarrowClientDipHeight+" DIP client ("+resizeDpi+" DPI)");
      // The resize is asynchronous across processes: wait, bounded, for the live
      // viewport to actually change before asserting any 240 DIP geometry. A
      // timeout fails the check instead of being absorbed by a fixed sleep.
      Check(Wait(delegate{
          uint live=GetDpiForWindow(view); if(live==0) return false;
          RECT v=Rect(view);
          int widthDip=(int)Math.Round((v.R-v.L)*96.0/live);
          return widthDip<beforeWidthDip; }),
        "the resized page reaches a narrower viewport within the bound ("+beforeWidthDip+" DIP before)");
      var resized=new RECT();
      Check(GetClientRect(main,out resized),"client rect after the resize");
      int gotWidth=(int)Math.Round((resized.R-resized.L)*96.0/resizeDpi);
      int gotHeight=(int)Math.Round((resized.B-resized.T)*96.0/resizeDpi);
      Check(Math.Abs(gotWidth-NarrowClientDipWidth)<=1 && Math.Abs(gotHeight-NarrowClientDipHeight)<=1,
        "resize lands on the requested client DIP ("+gotWidth+"x"+gotHeight+" at "+resizeDpi+" DPI)");
      Check(Wait(delegate{
          uint live=GetDpiForWindow(view);
          return live!=0 && Rect(view).B-Rect(view).T==Pixels(240,live); }),
        "the 240 DIP viewport settles within the bound after the resize");
      uint afterDpi=GetDpiForWindow(view);
      if(afterDpi==0) { Console.WriteLine("[DPI] GetDpiForWindow returned 0 after the resize"); return ExitWindowDpiUnavailable; }
      Check(Rect(view).B-Rect(view).T==Pixels(240,afterDpi),
        "the viewport stays 240 DIP after a real resize at "+afterDpi+" DPI");
      Shot("scroll-dark-narrow",main);
      var reject=Find(root,"Refuse save",ControlType.CheckBox);((TogglePattern)reject.GetCurrentPattern(TogglePattern.Pattern)).Toggle();Thread.Sleep(150);
      Invoke(root,"Open dialog");AutomationElement dialog=null;
      Check(Wait(delegate{dialog=AutomationElement.RootElement.FindFirst(TreeScope.Descendants,new AndCondition(new PropertyCondition(AutomationElement.ProcessIdProperty,p.Id),new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.Window),new PropertyCondition(AutomationElement.NameProperty,"Scrollable form")));return dialog!=null;}),"dialog opens from actual page action");
      if(dialog==null)throw new Exception("missing dialog");var dh=H(dialog);Check(!IsWindowEnabled(main),"modal disables page");
      var de=Edit(dialog);var db=GetParent(GetParent(H(de)));var dv=GetParent(db);
      var save=Find(dialog,"Save",ControlType.Button);var footer=Rect(H(save));DragBottom(dv);
      Check(Rect(H(save)).T==footer.T && IsWindowVisible(H(save)),"dialog footer stays fixed while content scrolls");
      Shot("scroll-dialog-dark",dh);
      Invoke(dialog,"Save");Check(IsWindowVisible(dh) && Value(de)=="persistent draft","refused Save keeps modal and accepted draft");
      // Standard dialog close button is reached through its native UIA Invoke.
      var close=Find(dialog,"关闭",ControlType.Button);
      if(close==null)throw new Exception("missing dialog close control");((InvokePattern)close.GetCurrentPattern(InvokePattern.Pattern)).Invoke();
      Check(Wait(delegate{return IsWindowEnabled(main);}),"closing dialog restores page input gate");
      ((TogglePattern)reject.GetCurrentPattern(TogglePattern.Pattern)).Toggle();Thread.Sleep(120);
      Invoke(root,"Open dialog");Thread.Sleep(200);dialog=AutomationElement.FromHandle(dh);Invoke(dialog,"Save");
      Check(Wait(delegate{return IsWindowEnabled(main);}),"accepted Save closes modal and restores page");
    } catch(Exception e) {Check(false,e.ToString());}
    finally {try{p.CloseMainWindow();if(!p.WaitForExit(5000)){p.Kill();p.WaitForExit(3000);}}catch(Exception e){Check(false,"cleanup: "+e.Message);}Check(p.HasExited,"owned example process exited");p.Dispose();}
    return failures==0?0:7;
  }
}
