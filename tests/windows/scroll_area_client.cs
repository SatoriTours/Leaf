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
  public static int Main(string[] args) {
    if(args.Length!=3)return 2;output=args[1];Directory.CreateDirectory(output);
    var p=Process.Start(new ProcessStartInfo(args[0]){UseShellExecute=false});File.WriteAllText(args[2],p.Id.ToString());
    try {
      IntPtr main=IntPtr.Zero;
      Check(Wait(delegate{p.Refresh();main=p.MainWindowHandle;return main!=IntPtr.Zero;}),"actual example window starts");
      if(main==IntPtr.Zero)return 3;SetForegroundWindow(main);Thread.Sleep(300);
      var root=AutomationElement.FromHandle(main);var edit=Edit(root);if(edit==null)throw new Exception("missing native EDIT");
      var original=H(edit);var body=GetParent(GetParent(original));var view=GetParent(body);
      Check(Rect(view).B-Rect(view).T==240,"actual viewport is finite 240 pixels at 96 DPI");
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
      Check(SetWindowPos(main,IntPtr.Zero,80,80,380,450,4),"resize to narrow short window");Thread.Sleep(300);
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
