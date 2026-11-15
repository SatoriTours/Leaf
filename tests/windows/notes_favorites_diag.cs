
using System;using System.Text;using System.IO;using System.Collections.Generic;using System.Diagnostics;using System.Threading;using System.Runtime.InteropServices;using System.Windows.Automation;using System.Drawing;

// Minimal diagnostic: fresh Notes app -> create note -> type title -> favourite ->
// snapshot BEFORE clicking the exact "已收藏" button -> real mouse click ->
// wait up to 3s for "3 份笔记" -> snapshot AFTER (always) -> natural close.
// Read-only about foreign windows; writes every observation it can before exiting.
public class FavoritesDiag {
 [StructLayout(LayoutKind.Sequential)] public struct RECT {public int left,top,right,bottom;}
 [StructLayout(LayoutKind.Sequential)] struct KI {public ushort vk,scan;public uint flags,time;public UIntPtr extra;}
 [StructLayout(LayoutKind.Sequential)] struct MI {public int x,y;public uint data,flags,time;public UIntPtr extra;}
 [StructLayout(LayoutKind.Explicit)] struct U {[FieldOffset(0)]public KI k;[FieldOffset(0)]public MI m;}
 [StructLayout(LayoutKind.Sequential)] struct INPUT {public uint type;public U u;}
 const uint INPUT_KEYBOARD=1, KEYEVENTF_KEYUP=0x0002, KEYEVENTF_UNICODE=0x0004;
 const uint WM_GETTEXT=13;
 const int GWL_STYLE=-16, ES_MULTILINE=0x0004;
 static string outDir=".";static string prefix="favorites";
 static readonly Stopwatch clock=Stopwatch.StartNew();
 [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent,EnumProc cb,IntPtr data);
 [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb,IntPtr data);
 delegate bool EnumProc(IntPtr w,IntPtr p);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr w,out uint pid);
 [DllImport("user32.dll",EntryPoint="SendMessageTimeoutW",CharSet=CharSet.Unicode)] static extern IntPtr TextMessage(IntPtr w,uint m,UIntPtr p,StringBuilder text,uint flags,uint timeout,out UIntPtr r);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr w,StringBuilder s,int n);
 [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr w,int index);
 [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr w,out RECT r);
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr w);
 [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr w);
 [DllImport("user32.dll")] static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] static extern void mouse_event(uint flags,uint x,uint y,uint data,UIntPtr extra);
 [DllImport("user32.dll")] static extern uint SendInput(uint n,INPUT[] input,int size);
 [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr w);
 static void Log(string s){try{File.AppendAllText(Path.Combine(outDir,prefix+".log"),s+"\n",new UTF8Encoding(false));}catch(Exception){}Console.WriteLine(s);}
 static void WriteJson(string name,string json){try{File.WriteAllText(Path.Combine(outDir,name),json,new UTF8Encoding(false));}catch(Exception ex){Console.WriteLine("WRITE.Failed "+name+" "+ex.Message);}}
 static string Text(IntPtr w){var s=new StringBuilder(4096);UIntPtr r;if(TextMessage(w,WM_GETTEXT,new UIntPtr(4096),s,3,300,out r)==IntPtr.Zero)return "<timeout>";return s.ToString();}
 static string ClassOf(IntPtr w){var s=new StringBuilder(256);GetClassName(w,s,256);return s.ToString();}
 static int PidOf(IntPtr w){uint p;GetWindowThreadProcessId(w,out p);return (int)p;}
 static bool Multi(IntPtr w){return (GetWindowLong(w,GWL_STYLE)&ES_MULTILINE)!=0;}
 static string RectJson(IntPtr w){RECT r;if(!GetWindowRect(w,out r))return "null";return "["+r.left+","+r.top+","+r.right+","+r.bottom+"]";}
 static List<IntPtr> Children(IntPtr root){var l=new List<IntPtr>();EnumChildWindows(root,delegate(IntPtr w,IntPtr p){if(l.Count<128)l.Add(w);return true;},IntPtr.Zero);return l;}
 static string Esc(string s){return s.Replace("\\","\\\\").Replace("\"","'").Replace("\r"," ").Replace("\n"," ");}
 static string Snapshot(IntPtr root,int appPid,string label,int waitResult){
  var sb=new StringBuilder();
  sb.Append("{\"label\":\""+label+"\",\"waitResult\":"+waitResult+",\"tMs\":"+clock.ElapsedMilliseconds+",");
  // search editor: left-most single-line EDIT
  IntPtr search=IntPtr.Zero;RECT rr;GetWindowRect(root,out rr);int middle=rr.left+(rr.right-rr.left)/2;
  foreach(var w in Children(root)){if(ClassOf(w)!="Edit")continue;RECT r;GetWindowRect(w,out r);if(r.right<=r.left||Multi(w))continue;if(r.left<middle&&(search==IntPtr.Zero||r.top<GetTop(search)))search=w;}
  sb.Append("\"searchHandle\":"+search+",\"searchText\":\""+Esc(search==IntPtr.Zero?"<none>":Text(search))+"\",");
  // breadcrumb + counts + exact favourite button identity
  string breadcrumb="<none>";int breadcrumbVisible=0;
  var counts=new StringBuilder();bool firstCount=true;
  string favText="<none>";int favVisible=0;string favRect="null";long favHandle=0;
  foreach(var w in Children(root)){
   string t;try{t=Text(w);}catch(Exception){continue;}
   if(t.IndexOf("  /  笔记",StringComparison.Ordinal)>=0){breadcrumb=t;breadcrumbVisible=IsWindowVisible(w)?1:0;}
   if(t.IndexOf("份笔记",StringComparison.Ordinal)>=0){
     if(!firstCount)counts.Append(",");
     firstCount=false;
     counts.Append("{\"text\":\""+Esc(t)+"\",\"visible\":"+(IsWindowVisible(w)?1:0)+",\"class\":\""+ClassOf(w)+"\",\"rect\":"+RectJson(w)+",\"pid\":"+PidOf(w)+"}");
   }
  }
  foreach(var w in Children(root)){
   if(ClassOf(w)!="Button")continue;string t;try{t=Text(w);}catch(Exception){continue;}
   if(t=="已收藏"&&PidOf(w)==appPid&&IsWindowVisible(w)){favText=t;favVisible=1;favRect=RectJson(w);favHandle=w.ToInt64();break;}
  }
  sb.Append("\"breadcrumb\":\""+Esc(breadcrumb)+"\",\"breadcrumbVisible\":"+breadcrumbVisible+",");
  sb.Append("\"counts\":["+counts+"],\"favoriteButton\":{\"text\":\""+Esc(favText)+"\",\"visible\":"+favVisible+",\"rect\":"+favRect+",\"handle\":"+favHandle+"},");
  sb.Append("\"oldPredicateHas3\":"+(HasText(root,"3 份笔记")?1:0)+",");
  var wins=new StringBuilder();bool firstWin=true;
  foreach(var w in Children(root)){
   string t;try{t=Text(w);}catch(Exception){t="<timeout>";}
   if(t.Length>64)t=t.Substring(0,64);
   if(!firstWin)wins.Append(",");
   firstWin=false;
   wins.Append("{\"hwnd\":"+w.ToInt64()+",\"pid\":"+PidOf(w)+",\"class\":\""+ClassOf(w)+"\",\"text\":\""+Esc(t)+"\",\"visible\":"+(IsWindowVisible(w)?1:0)+",\"multi\":"+(Multi(w)?1:0)+",\"rect\":"+RectJson(w)+"}");
  }
  sb.Append("\"windows\":["+wins+"]}");
  return sb.ToString();}
 static int GetTop(IntPtr w){RECT r;GetWindowRect(w,out r);return r.top;}
 static bool HasText(IntPtr root,string part){foreach(var w in Children(root)){string t;try{t=Text(w);}catch(Exception){continue;}if(t.IndexOf(part,StringComparison.Ordinal)>=0)return true;}return false;}
 static IntPtr Button(IntPtr root,string label,int appPid){foreach(var w in Children(root)){if(ClassOf(w)!="Button")continue;string t;try{t=Text(w);}catch(Exception){continue;}if(t==label&&PidOf(w)==appPid&&IsWindowVisible(w))return w;}return IntPtr.Zero;}
 static void Click(IntPtr w,string what){RECT r;GetWindowRect(w,out r);int x=(r.left+r.right)/2,y=(r.top+r.bottom)/2;
  SetCursorPos(x,y);mouse_event(0x0002,0,0,0,UIntPtr.Zero);mouse_event(0x0004,0,0,0,UIntPtr.Zero);Thread.Sleep(150);
  Log("CLICK "+what+" hwnd="+w.ToInt64()+" rect=["+r.left+","+r.top+","+r.right+","+r.bottom+"] at="+x+","+y);}
 static void Key(ushort vk){var i=new INPUT[2];i[0].type=INPUT_KEYBOARD;i[0].u.k.vk=vk;i[1]=i[0];i[1].u.k.flags=KEYEVENTF_KEYUP;SendInput(2,i,Marshal.SizeOf(typeof(INPUT)));Thread.Sleep(80);}
 static void Type(string s){foreach(var ch in s){var i=new INPUT[2];i[0].type=INPUT_KEYBOARD;i[0].u.k.scan=(ushort)ch;i[0].u.k.flags=KEYEVENTF_UNICODE;i[1]=i[0];i[1].u.k.flags=KEYEVENTF_UNICODE|KEYEVENTF_KEYUP;SendInput(2,i,Marshal.SizeOf(typeof(INPUT)));Thread.Sleep(20);}Thread.Sleep(100);}
 static void ClearField(IntPtr w){AutomationElement.FromHandle(w).SetFocus();Thread.Sleep(80);
  var i=new INPUT[4];i[0].type=INPUT_KEYBOARD;i[0].u.k.vk=0x11;i[1].type=INPUT_KEYBOARD;i[1].u.k.vk=0x41;i[2]=i[1];i[2].u.k.flags=KEYEVENTF_KEYUP;i[3]=i[0];i[3].u.k.flags=KEYEVENTF_KEYUP;
  SendInput(4,i,Marshal.SizeOf(typeof(INPUT)));Thread.Sleep(80);Key(0x2E);Thread.Sleep(120);}
 static void Shot(IntPtr root,string path){RECT r;GetWindowRect(root,out r);Thread.Sleep(250);
  using(var b=new Bitmap(r.right-r.left,r.bottom-r.top)){using(var g=Graphics.FromImage(b))g.CopyFromScreen(r.left,r.top,0,0,b.Size);b.Save(path,System.Drawing.Imaging.ImageFormat.Png);}}
 static int Main(string[] args){
  if(args.Length<3){Console.Error.WriteLine("usage: FavoritesDiag <exe> <db> <outDir>");return 2;}
  string exe=args[0],db=args[1];outDir=args[2];prefix="favorites";
  if(!File.Exists(exe)){WriteJson("favorites.failure.json","{\"code\":\"EXE_MISSING\"}");return 2;}
  if(File.Exists(db)){WriteJson("favorites.failure.json","{\"code\":\"DB_EXISTS\"}");return 2;}
  var app=Process.Start(new ProcessStartInfo(exe,"--database \""+db+"\" --theme light"){UseShellExecute=false});
  bool natural=false;int exitCode=-1;
  try{
   IntPtr root=IntPtr.Zero;
   for(int i=0;i<120&&root==IntPtr.Zero;i++){EnumWindows(delegate(IntPtr w,IntPtr p){if(PidOf(w)==app.Id&&Text(w)=="Leaf Notes"){root=w;return false;}return true;},IntPtr.Zero);if(root==IntPtr.Zero)Thread.Sleep(60);}
   if(root==IntPtr.Zero){WriteJson("favorites.failure.json","{\"code\":\"ROOT_MISSING\"}");return 1;}
   SetForegroundWindow(root);Thread.Sleep(400);
   if(GetForegroundWindow()!=root){WriteJson("favorites.failure.json","{\"code\":\"FOREGROUND_BLOCKED\",\"fgClass\":\""+ClassOf(GetForegroundWindow())+"\"}");return 1;}
   Log("DPI.Window="+GetDpiForWindow(root)+" tMs="+clock.ElapsedMilliseconds);
   // create a note and favourite it through real input
   var newBtn=Button(root,"＋ 新建笔记",app.Id);if(newBtn==IntPtr.Zero){WriteJson("favorites.failure.json","{\"code\":\"NEW_BUTTON_MISSING\"}");return 1;}
   Click(newBtn,"new-note");
   IntPtr title=IntPtr.Zero;for(int i=0;i<60&&title==IntPtr.Zero;i++){foreach(var w in Children(root)){if(ClassOf(w)!="Edit"||Multi(w))continue;RECT r;GetWindowRect(w,out r);if(r.left>=middleOf(root))title=w;}if(title==IntPtr.Zero)Thread.Sleep(50);}
   if(title==IntPtr.Zero){WriteJson("favorites.failure.json","{\"code\":\"TITLE_MISSING\"}");return 1;}
   Click(title,"title");ClearField(title);Type("验收笔记A");Thread.Sleep(300);
   var favBtn=Button(root,"收藏",app.Id);if(favBtn==IntPtr.Zero){WriteJson("favorites.failure.json","{\"code\":\"FAV_BUTTON_MISSING\"}");return 1;}
   Click(favBtn,"favourite");Thread.Sleep(400);
   WriteJson("snapshot-pre.json",Snapshot(root,app.Id,"pre-click-favorites",-1));
   var navFav=Button(root,"已收藏",app.Id);
   if(navFav==IntPtr.Zero){WriteJson("favorites.failure.json","{\"code\":\"NAV_FAVORITES_MISSING\"}");return 1;}
   Click(navFav,"nav-favorites");
   bool ok=false;for(int i=0;i<60;i++){if(HasText(root,"3 份笔记")){ok=true;break;}Thread.Sleep(50);}
   WriteJson("snapshot-post.json",Snapshot(root,app.Id,ok?"post-success":"post-timeout",ok?1:0));
   Shot(root,Path.Combine(outDir,"post-"+(ok?"success":"timeout")+".png"));
   if(!app.CloseMainWindow()){WriteJson("favorites.failure.json","{\"code\":\"CLOSE_REJECTED\"}");return 1;}
   if(!app.WaitForExit(8000)){WriteJson("favorites.failure.json","{\"code\":\"EXIT_TIMEOUT\"}");return 1;}
   natural=true;exitCode=app.ExitCode;Log("APP.ExitCode="+exitCode+" natural=true");
   return ok&&exitCode==0?0:1;
  }catch(Exception ex){Log("EXCEPTION "+ex.Message);WriteJson("favorites.failure.json","{\"code\":\"EXCEPTION\",\"detail\":\""+Esc(ex.ToString())+"\"}");return 1;}
  finally{if(!natural&&!app.HasExited){app.Kill();app.WaitForExit(3000);Log("APP.Cleanup=forced");}app.Dispose();}}
 static int middleOf(IntPtr root){RECT r;GetWindowRect(root,out r);return r.left+(r.right-r.left)/2;}
}
