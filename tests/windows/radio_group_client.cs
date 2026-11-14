// Cross-process actual-entry checks for the native radio group. Geometry and
// pattern assertions supplement, not replace, independent visual review of the
// emitted screenshots.
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Automation;

public class RadioGroupClient {
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int L,T,R,B; }
  [StructLayout(LayoutKind.Sequential)] struct MOUSE { public int x,y; public uint data,flags,time; public UIntPtr extra; }
  [StructLayout(LayoutKind.Sequential)] struct KEY { public ushort vk,scan; public uint flags,time; public UIntPtr extra; }
  [StructLayout(LayoutKind.Explicit)] struct INPUT { [FieldOffset(0)] public uint kind;
    [FieldOffset(8)] public MOUSE mouse; [FieldOffset(8)] public KEY key; }
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h,out RECT r);
  [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr h);
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool SetCursorPos(int x,int y);
  [DllImport("user32.dll")] static extern uint SendInput(uint n,INPUT[] p,int size);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int height,uint flags);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr h);
  [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
  delegate bool EnumProc(IntPtr h,IntPtr data);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc,IntPtr data);
  static System.Collections.Generic.List<IntPtr> OwnedTopLevel(int pid) {
    var found=new System.Collections.Generic.List<IntPtr>();
    EnumWindows(delegate(IntPtr h,IntPtr data){
      uint owner;GetWindowThreadProcessId(h,out owner);
      if(owner==(uint)pid&&IsWindowVisible(h)&&GetWindowTextLength(h)>0) found.Add(h);
      return true;},IntPtr.Zero);
    return found;
  }
  static RECT Union(System.Collections.Generic.List<IntPtr> windows) {
    var u=new RECT{L=int.MaxValue,T=int.MaxValue,R=int.MinValue,B=int.MinValue};
    foreach(var h in windows){var r=Rect(h);
      u.L=Math.Min(u.L,r.L);u.T=Math.Min(u.T,r.T);
      u.R=Math.Max(u.R,r.R);u.B=Math.Max(u.B,r.B);}
    return u;
  }
  static int failures; static string output;
  static void Check(bool ok,string message) { Console.WriteLine((ok?"[OK] ":"[FAILED] ")+message); if(!ok)failures++; }
  static void Info(string message) { Console.WriteLine("[INFO] "+message); }
  static bool Wait(Func<bool> predicate) { for(int i=0;i<40;i++) { if(predicate())return true;Thread.Sleep(75); }return predicate(); }
  static AutomationElement Find(AutomationElement root,string name,ControlType type) {
    return root.FindFirst(TreeScope.Descendants,new AndCondition(new PropertyCondition(AutomationElement.NameProperty,name),new PropertyCondition(AutomationElement.ControlTypeProperty,type)));
  }
  static AutomationElement Radio(AutomationElement root,string name) { return Find(root,name,ControlType.RadioButton); }
  static IntPtr H(AutomationElement e) { return new IntPtr(e.Current.NativeWindowHandle); }
  static RECT Rect(IntPtr h) { RECT r;if(!GetWindowRect(h,out r))throw new Exception("GetWindowRect failed");return r; }
  static RECT Rect(AutomationElement e) { return Rect(H(e)); }
  static bool IsSelected(AutomationElement e) {
    return ((SelectionItemPattern)e.GetCurrentPattern(SelectionItemPattern.Pattern)).Current.IsSelected;
  }
  static void Click(AutomationElement e) {
    var r=Rect(e);SetCursorPos((r.L+r.R)/2,(r.T+r.B)/2);Thread.Sleep(80);
    var p=new INPUT[1];p[0].kind=0;p[0].mouse.flags=2;
    SendInput(1,p,Marshal.SizeOf(typeof(INPUT)));Thread.Sleep(60);
    p[0].mouse.flags=4;SendInput(1,p,Marshal.SizeOf(typeof(INPUT)));Thread.Sleep(250);
  }
  static void Key(ushort vk) {
    var p=new INPUT[1];p[0].kind=1;p[0].key.vk=vk;
    SendInput(1,p,Marshal.SizeOf(typeof(INPUT)));Thread.Sleep(60);
    p[0].key.flags=2;SendInput(1,p,Marshal.SizeOf(typeof(INPUT)));Thread.Sleep(200);
  }
  static AutomationElement Text(AutomationElement root,string name) { return Find(root,name,ControlType.Text); }
  static void DumpTexts(AutomationElement root,string label) {
    var all=root.FindAll(TreeScope.Descendants,new PropertyCondition(
      AutomationElement.ControlTypeProperty,ControlType.Text));
    var names=new System.Text.StringBuilder();
    for(int i=0;i<all.Count&&i<24;i++) names.Append("|"+all[i].Current.Name);
    Console.WriteLine("[TEXTS] "+label+names.ToString());
  }
  static int CountRadios(AutomationElement root,string name) {
    var all=root.FindAll(TreeScope.Descendants,new AndCondition(
      new PropertyCondition(AutomationElement.NameProperty,name),
      new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.RadioButton)));
    return all.Count;
  }
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
  static IntPtr TopLevel(IntPtr h) {
    for(int i=0;i<32;i++){var parent=GetParent(h);if(parent==IntPtr.Zero)return h;h=parent;}
    return h;
  }
  // The topmost ancestor that reports a native window handle identifies the
  // owning top-level window, even when a control proxy hides its own HWND.
  static int appPid;
  // The owned dialog is a separate top-level window: its controls are searched
  // inside that window's own subtree, never through the page copy of a caption.
  static IntPtr DialogWindow(IntPtr main) {
    foreach(var h in OwnedTopLevel(appPid)) if(h!=main) return h;
    return IntPtr.Zero;
  }
  static AutomationElement InDialog(string name,ControlType type,IntPtr main) {
    var dialog=DialogWindow(main);
    if(dialog==IntPtr.Zero) return null;
    var root=AutomationElement.FromHandle(dialog);
    if(root==null) return null;
    return Find(root,name,type);
  }
  // Owned modal windows are separate top-level windows: sampling only the main
  // HWND rect would crop the dialog. Capture the union of every visible owned
  // top-level window of the process instead, and assert the bounds actually
  // contain both windows.
  static void ShotUnion(string name,IntPtr main,int pid) {
    var watch=Stopwatch.StartNew();
    var element=AutomationElement.FromHandle(main);object pattern;
    bool idle=element.TryGetCurrentPattern(WindowPattern.Pattern,out pattern) &&
      ((WindowPattern)pattern).WaitForInputIdle(5000);
    Console.WriteLine("[READY] "+name+" inputIdle="+idle+" waitMs="+watch.ElapsedMilliseconds);
    Check(idle,"capture reaches bounded input-idle: "+name);
    Thread.Sleep(600);
    var windows=OwnedTopLevel(pid);
    Check(windows.Count>=2,"dialog is a second real top-level window: "+windows.Count);
    var mainRect=Rect(main);var u=Union(windows);
    Check(u.L<=mainRect.L&&u.T<=mainRect.T&&u.R>=mainRect.R&&u.B>=mainRect.B,
      "capture union contains the main window rect");
    int screenW=GetSystemMetrics(0),screenH=GetSystemMetrics(1);
    Check(u.L>=0&&u.T>=0&&u.R<=screenW&&u.B<=screenH,
      "capture union stays inside the screen bounds");
    System.Console.WriteLine("[RECT] union="+u.L+","+u.T+","+u.R+","+u.B+" windows="+windows.Count);
    using(var b=new Bitmap(u.R-u.L,u.B-u.T)) {
      using(var g=Graphics.FromImage(b))g.CopyFromScreen(u.L,u.T,0,0,b.Size);
      b.Save(Path.Combine(output,name+".png"),ImageFormat.Png);
    }
  }
  public static int Main(string[] args) {
    if(args.Length!=3)return 2;output=args[1];Directory.CreateDirectory(output);
    var p=Process.Start(new ProcessStartInfo(args[0]){UseShellExecute=false});
    File.WriteAllText(args[2],p.Id.ToString());appPid=p.Id;
    try {
      IntPtr main=IntPtr.Zero;
      Check(Wait(delegate{p.Refresh();main=p.MainWindowHandle;return main!=IntPtr.Zero;}),"actual example window starts");
      if(main==IntPtr.Zero)return 3;SetForegroundWindow(main);Thread.Sleep(400);
      var root=AutomationElement.FromHandle(main);
      // Role: every option is a real stock radio button, not a checkbox/button.
      foreach(var name in new[]{"标准配送","加急配送","门店自取","银行卡","货到付款","对公转账"})
        Check(Radio(root,name)!=null,"stock UIA RadioButton role for "+name);
      Check(Find(root,"拒绝每次选择",ControlType.CheckBox)!=null,"plain checkbox keeps CheckBox role (isolation)");
      var standard=Radio(root,"标准配送");var express=Radio(root,"加急配送");
      var pickup=Radio(root,"门店自取");var card=Radio(root,"银行卡");
      Check(standard!=null&&express!=null&&pickup!=null&&card!=null,"radio options are reachable through UIA");
      if(standard==null||express==null||pickup==null||card==null)return 4;
      Check(IsSelected(standard)&&!IsSelected(express),"initial accepted value is the only selected option");
      Check(!IsSelected(card),"an unselected group has no selected option");
      Shot("radio-light-initial",main);
      // Accepted physical click.
      Click(express);
      Check(Wait(delegate{return IsSelected(express)&&!IsSelected(standard);}),"physical click accepts the new option");
      Check(Text(root,"已接受：加急配送")!=null,"accepted change reaches the business state");
      Shot("radio-light-accepted",main);
      // Refused physical click: the accepted value and native siblings stay put.
      var refuse=Find(root,"拒绝每次选择",ControlType.CheckBox);
      ((TogglePattern)refuse.GetCurrentPattern(TogglePattern.Pattern)).Toggle();Thread.Sleep(200);
      Check(Wait(delegate{return ((TogglePattern)refuse.GetCurrentPattern(TogglePattern.Pattern)).Current.ToggleState==ToggleState.On;}),"refusal switch is on");
      Click(pickup);
      Check(Wait(delegate{return Text(root,"已拒绝：门店自取（保持已接受值）")!=null;}),"refused request still reaches the business handler");
      Check(IsSelected(express)&&!IsSelected(pickup)&&!IsSelected(standard),"refused request leaves the accepted native state intact");
      Shot("radio-light-refused",main);
      ((TogglePattern)refuse.GetCurrentPattern(TogglePattern.Pattern)).Toggle();Thread.Sleep(200);
      // UIA SelectionItem must actually select an unselected enabled option and
      // deliver one controlled request, not merely agree with the accepted value.
      Check(!IsSelected(card),"the payment option starts unselected");
      string selectError=null;
      try { ((SelectionItemPattern)card.GetCurrentPattern(SelectionItemPattern.Pattern)).Select(); }
      catch(Exception error) { selectError=error.GetType().Name; }
      Info("SelectionItemPattern.Select error="+(selectError==null?"none":selectError));
      Check(selectError==null,"SelectionItemPattern.Select is supported by the stock radio");
      Check(Wait(delegate{return IsSelected(card);}),"UIA Select selects the unselected enabled option");
      Check(Wait(delegate{return Text(root,"已接受支付：银行卡")!=null;}),
        "UIA Select delivers the controlled request to the accepted business value");
      Check(!IsSelected(Radio(root,"货到付款")),"one payment option at most is selected");
      // Keyboard: one Tab stop per group, arrows skip disabled, Space selects.
      var tabCheck=Find(root,"拒绝每次选择",ControlType.CheckBox);
      tabCheck.SetFocus();Thread.Sleep(150);
      Key(0x09); // Tab
      AutomationElement focused=AutomationElement.FocusedElement;
      Check(focused!=null&&focused.Current.ControlType==ControlType.RadioButton&&
        focused.Current.Name=="加急配送",
        "Tab enters the shipping group exactly once at its accepted option");
      Key(0x09); // Tab again: the next stop is the other group, never a sibling
      var nextStop=AutomationElement.FocusedElement;
      Check(nextStop!=null&&nextStop.Current.ControlType==ControlType.RadioButton&&
        nextStop.Current.Name=="银行卡",
        "one Tab stop per group: the next stop belongs to the payment group");
      Radio(root,"加急配送").SetFocus();Thread.Sleep(150);
      var beforeArrow="加急配送";
      Key(0x28); // Down
      var afterDown=AutomationElement.FocusedElement;
      Check(afterDown!=null&&afterDown.Current.ControlType==ControlType.RadioButton&&afterDown.Current.Name!=beforeArrow,
        "Down moves focus inside the group and skips disabled options");
      Info("arrow moved focus from "+beforeArrow+" to "+(afterDown==null?"nil":afterDown.Current.Name));
      var focusedName=afterDown==null?null:afterDown.Current.Name;
      Check(focusedName!=null&&!IsSelected(Radio(root,focusedName)),"arrow focus movement never selects");
      Key(0x20); // Space
      Check(Wait(delegate{return focusedName!=null&&IsSelected(Radio(root,focusedName));}),"Space requests the focused option");
      Check(Text(root,"已接受："+focusedName)!=null,"Space acceptance reaches the business state");
      Shot("radio-light-keyboard",main);
      // Theme switch keeps the accepted value and the native role.
      var toggleButton=Find(root,"切换主题",ControlType.Button);
      ((InvokePattern)toggleButton.GetCurrentPattern(InvokePattern.Pattern)).Invoke();Thread.Sleep(300);
      Check(Radio(root,"加急配送")!=null,"dark theme keeps the native radio role");
      Shot("radio-dark",main);
      var pid=p.Id;
      var open=Find(root,"打开对话框",ControlType.Button);
      Check(open!=null,"the page exposes the dialog trigger");
      Check(SetWindowPos(main,IntPtr.Zero,70,60,380,520,4),"resize to a narrow short window");Thread.Sleep(400);
      Shot("radio-dark-narrow",main);
      // The reported defect: sampling only the narrow host cropped the dialog.
      // Capture the union while the host is still narrow, then close it again.
      ((InvokePattern)open.GetCurrentPattern(InvokePattern.Pattern)).Invoke();Thread.Sleep(600);
      var narrowDialog=DialogWindow(main);
      Check(narrowDialog!=IntPtr.Zero,"a narrow host still opens a real dialog window");
      if(narrowDialog!=IntPtr.Zero){
        var narrowUnion=Union(OwnedTopLevel(pid));
        var narrowDialogRect=Rect(narrowDialog);
        Info("narrow dialog rect="+narrowDialogRect.L+","+narrowDialogRect.T+","+narrowDialogRect.R+","+narrowDialogRect.B+
          " union="+narrowUnion.L+","+narrowUnion.T+","+narrowUnion.R+","+narrowUnion.B);
        Check(narrowDialogRect.L>=narrowUnion.L&&narrowDialogRect.T>=narrowUnion.T&&
          narrowDialogRect.R<=narrowUnion.R&&narrowDialogRect.B<=narrowUnion.B,
          "the narrow capture union contains the whole dialog rect");
        ShotUnion("radio-dark-dialog-narrow",main,pid);
        var narrowClose=InDialog("关闭",ControlType.Button,main);
        Check(narrowClose!=null,"the narrow dialog exposes its close control");
        if(narrowClose!=null){((InvokePattern)narrowClose.GetCurrentPattern(InvokePattern.Pattern)).Invoke();Thread.Sleep(600);}
        Check(Wait(delegate{return OwnedTopLevel(pid).Count==1;}),"the narrow dialog closes cleanly");
      }
      Check(SetWindowPos(main,IntPtr.Zero,70,60,560,560,4),"restore the normal window size before the dialog");
      Thread.Sleep(400);
      var beforeDialog=OwnedTopLevel(pid).Count;
      Check(beforeDialog==1,"the page is one top-level window before the dialog");
      // Dialog + scroll area composition keeps real native radio semantics.
      ((InvokePattern)open.GetCurrentPattern(InvokePattern.Pattern)).Invoke();Thread.Sleep(600);
      Check(CountRadios(root,"标准配送")==2,"dialog scroll area hosts a second real radio group");
      Check(CountRadios(root,"银行卡")==2,"dialog payment group keeps its own radio options");
      Check(OwnedTopLevel(pid).Count==2,"the modal dialog is a second real top-level window");
      ShotUnion("radio-dark-dialog",main,pid);
      DumpTexts(root,"dialog-open");
      var dialogStandard=InDialog("标准配送",ControlType.RadioButton,main);
      // The dialog's third option is the closed-store variant: disabled there.
      var dialogPickup=InDialog("自取（暂停）",ControlType.RadioButton,main);
      var dialogExpress=InDialog("加急配送",ControlType.RadioButton,main);
      Check(dialogStandard!=null&&dialogPickup!=null&&dialogExpress!=null,
        "dialog radio options are addressable inside the owned window");
      if(dialogStandard==null||dialogPickup==null||dialogExpress==null)return 5;
      Check(IsWindowEnabled(H(dialogPickup))==false,
        "the dialog keeps the disabled closed-store option disabled");
      Check(IsSelected(dialogStandard)||IsSelected(dialogExpress)||IsSelected(dialogPickup),
        "dialog group starts from the accepted business value");
      // Real accept inside the dialog scroll area.
      Click(dialogStandard);
      Check(Wait(delegate{return IsSelected(dialogStandard);}),"physical click inside the dialog selects the option");
      Check(Text(root,"已接受：标准配送")!=null,"dialog selection reaches the accepted business value");
      Check(!IsSelected(dialogPickup)&&!IsSelected(dialogExpress),
        "dialog group keeps exactly one accepted option");
      // Real refusal inside the dialog: the accepted option stays put.
      var dialogRefuse=InDialog("拒绝对话框内选择",ControlType.CheckBox,main);
      Check(dialogRefuse!=null,"dialog owns its own refusal switch");
      if(dialogRefuse!=null){
        ((TogglePattern)dialogRefuse.GetCurrentPattern(TogglePattern.Pattern)).Toggle();Thread.Sleep(250);
        Click(dialogExpress);
        Check(Wait(delegate{return Text(root,"已拒绝：加急配送（保持已接受值）")!=null;}),
          "dialog refusal still reaches the business handler");
        Check(IsSelected(dialogStandard)&&!IsSelected(dialogExpress),
          "dialog refusal leaves the accepted option selected");
        ((TogglePattern)dialogRefuse.GetCurrentPattern(TogglePattern.Pattern)).Toggle();Thread.Sleep(250);
      }
      // Keyboard inside the dialog: focus stays in the dialog group, never the page.
      dialogStandard.SetFocus();Thread.Sleep(200);
      Key(0x28); // Down
      var dialogFocus=AutomationElement.FocusedElement;
      var dialogRect=Rect(DialogWindow(main));
      var focusRect=dialogFocus==null?new RECT():Rect(dialogFocus);
      Check(dialogFocus!=null&&dialogFocus.Current.ControlType==ControlType.RadioButton&&
        dialogFocus.Current.Name=="加急配送"&&
        focusRect.L>=dialogRect.L&&focusRect.T>=dialogRect.T&&
        focusRect.R<=dialogRect.R&&focusRect.B<=dialogRect.B,
        "arrow focus stays inside the dialog group, not the page group");
      Check(IsSelected(dialogStandard)&&!IsSelected(dialogExpress)&&!IsSelected(dialogPickup),
        "arrow focus movement inside the dialog never changes the accepted value");
      ShotUnion("radio-dark-dialog-keyboard",main,pid);
      // Re-activating the already accepted option is not a new request, so move
      // to another option and back to make the final business value explicit.
      Click(dialogExpress);
      Check(Wait(delegate{return Text(root,"已接受：加急配送")!=null;}),
        "dialog accepts a different option after the refused request");
      Click(dialogStandard);
      Check(Wait(delegate{return Text(root,"已接受：标准配送")!=null;}),
        "dialog accepts the first option again on a new request");
      var close=InDialog("关闭",ControlType.Button,main);
      Check(close!=null,"dialog exposes its close control");
      if(close!=null){((InvokePattern)close.GetCurrentPattern(InvokePattern.Pattern)).Invoke();Thread.Sleep(600);}
      Check(Wait(delegate{return CountRadios(root,"标准配送")==1;}),"dialog closes and releases its radio group");
      Check(Wait(delegate{return OwnedTopLevel(pid).Count==1;}),"closing the dialog leaves no extra top-level window");
      var acceptedNow=0;
      foreach(var name in new[]{"标准配送","加急配送","门店自取"}) if(IsSelected(Radio(root,name))) acceptedNow++;
      Check(acceptedNow==1,"exactly one shipping option stays accepted after theme, resize, dialog and close");
      Check(Text(root,"已接受：标准配送")!=null,"the dialog-accepted business value survives the close");
    } finally {
      try{if(!p.HasExited){p.Kill();p.WaitForExit(5000);}}catch(Exception){}
    }
    Console.WriteLine(failures==0?"ALL PASSED":"FAILURES="+failures);
    return failures==0?0:1;
  }
}
