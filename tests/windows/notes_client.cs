
using System;using System.Text;using System.IO;using System.Diagnostics;using System.Threading;using System.Runtime.InteropServices;using System.Security.Cryptography;using System.Collections.Generic;using System.Windows.Automation;using System.Drawing;

// Real-input Notes acceptance client.
// Only two modes: "main" (light/dark real keyboard+mouse) and "lock" (second-connection write lock).
// It never closes, invokes or otherwise mutates windows it does not own; an external foreground
// window is recorded read-only and reported as a blocker.
public class NotesClient {
 [StructLayout(LayoutKind.Sequential)] public struct RECT {public int left,top,right,bottom;}
 [StructLayout(LayoutKind.Sequential)] struct KI {public ushort vk,scan;public uint flags,time;public UIntPtr extra;}
 [StructLayout(LayoutKind.Sequential)] struct MI {public int x,y;public uint data,flags,time;public UIntPtr extra;}
 [StructLayout(LayoutKind.Explicit)] struct U {[FieldOffset(0)]public KI k;[FieldOffset(0)]public MI m;}
 [StructLayout(LayoutKind.Sequential)] struct INPUT {public uint type;public U u;}
 const uint INPUT_KEYBOARD=1, KEYEVENTF_KEYUP=0x0002, KEYEVENTF_UNICODE=0x0004;
 const uint WM_GETTEXT=13, WM_CLOSE=0x0010, SWP_NOSIZE=0x0001, SWP_NOMOVE=0x0002, SWP_NOACTIVATE=0x0010;
 const int GWL_STYLE=-16, ES_MULTILINE=0x0004;
 [DllImport("user32.dll")] static extern bool GetUpdateRect(IntPtr w,IntPtr r,bool erase);
 [DllImport("dwmapi.dll")] static extern int DwmFlush();
 delegate bool EnumProc(IntPtr w,IntPtr p);
 [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p,IntPtr data);
 [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent,EnumProc p,IntPtr data);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr w,out uint pid);
 [DllImport("user32.dll",EntryPoint="SendMessageTimeoutW",CharSet=CharSet.Unicode)] static extern IntPtr TextMessage(IntPtr w,uint m,UIntPtr p,StringBuilder text,uint flags,uint timeout,out UIntPtr r);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr w,StringBuilder name,int max);
 [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr w,int index);
 [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr w,out RECT r);
 [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr w);
 [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr w);
 [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr w,IntPtr after,int x,int y,int width,int height,uint flags);
 [DllImport("user32.dll")] static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] static extern void mouse_event(uint flags,uint x,uint y,uint data,UIntPtr extra);
 [DllImport("user32.dll")] static extern uint SendInput(uint n,INPUT[] input,int size);
 [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr w);
 [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint action,uint param,out RECT rect,uint flags);
 [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr w,out RECT r);

 static string prefix="notes-client";
 static void Log(string line){try{File.AppendAllText(prefix+".log",line+"\n",new UTF8Encoding(false));}catch(Exception){}
  Console.WriteLine(line);}
 static void SaveFailure(string code,string detail){
  try{File.WriteAllText(prefix+".failure.json","{\"code\":\""+code+"\",\"detail\":\""+detail.Replace("\\","\\\\").Replace("\"","'")+"\"}\n",new UTF8Encoding(false));}
  catch(Exception){}}
 static Exception Fail(string code,string detail){SaveFailure(code,detail);return new Exception(code+": "+detail);}
 static string NeedB64(string raw,string label){
  if(raw==null||raw.Length==0)throw Fail("ARGS_EMPTY",label);
  byte[] bytes;try{bytes=Convert.FromBase64String(raw);}catch(Exception){throw Fail("ARGS_BAD_BASE64",label);}
  string text;try{text=new UTF8Encoding(false,true).GetString(bytes);}catch(Exception){throw Fail("ARGS_BAD_UTF8",label);}
  if(text.Length==0)throw Fail("ARGS_EMPTY_TEXT",label);
  return text;}
 static string Sha(string s){using(var sha=SHA256.Create()){var b=sha.ComputeHash(new UTF8Encoding(false).GetBytes(s));var sb=new StringBuilder();foreach(var x in b)sb.Append(x.ToString("x2"));return sb.ToString();}}
 static string Esc(string v){return (v==null?"":v).Replace("\\","\\\\").Replace("\"","'");}
 static string Field(string raw,string decoded){
  int rawUnits=raw==null?0:raw.Length;
  int rawBytes=raw==null?0:new UTF8Encoding(false).GetByteCount(raw);
  int decUnits=decoded==null?0:decoded.Length;
  int decBytes=decoded==null?0:new UTF8Encoding(false).GetByteCount(decoded);
  string hash=decoded==null?"-":Sha(decoded);
  return "rawUnits="+rawUnits+" rawBytes="+rawBytes+" decUnits="+decUnits+" decBytes="+decBytes+" sha256="+hash;}
 const string SelfTitle="自检 标题 \"引号\" 1115h";
 const string SelfBody="第一行\r\n第二行 带 空格 \"引号\" 中文 😀 end";
 static int RunSelfCheck(string[] args){
  if(args.Length<7){Console.Error.WriteLine("selfcheck needs: <exe> <db> <prefix> selfcheck <b64title> <b64body> [--legacy]");return 2;}
  bool legacy=false;string rawTitle=null,rawBody=null;
  for(int i=5;i<args.Length;i++){if(args[i]=="--legacy")legacy=true;else if(rawTitle==null)rawTitle=args[i];else rawBody=args[i];}
  if(rawTitle==null||rawBody==null){Console.Error.WriteLine("selfcheck missing title/body");return 2;}
  string title=null,body=null;string decodeError="";
  try{title=legacy?rawTitle:NeedB64(rawTitle,"self_title");}catch(Exception ex){decodeError=ex.Message;title="";}
  try{body=legacy?rawBody:NeedB64(rawBody,"self_body");}catch(Exception ex){decodeError=ex.Message;body="";}
  bool titleOk=title==SelfTitle,bodyOk=body==SelfBody;
  var report=new StringBuilder();
  report.Append("{");
  report.Append("\"legacy\":"+(legacy?"true":"false")+",");
  report.Append("\"argc\":"+args.Length+",");
  report.Append("\"title\":{\"match\":"+(titleOk?"true":"false")+",\"metrics\":\""+Field(rawTitle,title)+"\"},");
  report.Append("\"body\":{\"match\":"+(bodyOk?"true":"false")+",\"metrics\":\""+Field(rawBody,body)+"\"},");
  report.Append("\"expectedTitleSha256\":\""+Sha(SelfTitle)+"\",\"expectedBodySha256\":\""+Sha(SelfBody)+"\",");
  report.Append("\"decodeError\":\""+Esc(decodeError)+"\"}");
  string json=report.ToString();
  try{File.WriteAllText(prefix+".selfcheck.json",json,new UTF8Encoding(false));}catch(Exception ex){Console.WriteLine("write failed "+ex.Message);}
  Console.WriteLine(json);
  if(decodeError.Length>0)return 3;
  return (titleOk&&bodyOk)?0:4;}

 static int Main(string[] args){
  Console.OutputEncoding=new UTF8Encoding(false);
  if(args.Length<5){Console.Error.WriteLine("usage: NotesClient <exe> <db> <prefix> <light|dark> <main|lock|save|reopen|selfcheck> ...");return 2;}
  string exe=args[0],db=args[1],theme=args[3],mode=args[4];
  prefix=args[2];
  try{
   if(mode=="selfcheck")return RunSelfCheck(args);
   if(!File.Exists(exe))throw Fail("EXE_MISSING",exe);
   if(theme!="light"&&theme!="dark")throw Fail("THEME_INVALID",theme);
   int inputSize=Marshal.SizeOf(typeof(INPUT));
   int expected=IntPtr.Size==8?40:28;
   if(inputSize!=expected)throw Fail("INPUT_LAYOUT_MISMATCH","size="+inputSize+" expected="+expected);
   Log("LAYOUT INPUT="+inputSize+" KEYEVENTF_UNICODE="+KEYEVENTF_UNICODE+" KEYEVENTF_KEYUP="+KEYEVENTF_KEYUP);
   if(mode=="main"){
     if(File.Exists(db))throw Fail("DB_EXISTS",db+" (acceptance clients only write a fresh database)");
     return RunMain(exe,db,theme);}
   if(mode=="lock"){
     if(args.Length<7)throw Fail("ARGS_LOCK","lock needs lockTool and marker (args.Length="+args.Length+")");
     return RunLock(exe,db,args[5],args[6]);}
   if(mode=="save"){
     if(args.Length<8)throw Fail("ARGS_SAVE","save needs 8 arguments: scratchTitleB64 finalTitleB64 bodyB64 (got "+args.Length+")");
     if(File.Exists(db))throw Fail("DB_EXISTS",db+" (save mode writes a fresh database)");
     string scratch=NeedB64(args[5],"scratch_title");
     string finalTitle=NeedB64(args[6],"final_title");
     string body=NeedB64(args[7],"body");
     if(scratch.Length>200||finalTitle.Length>200)throw Fail("ARGS_TOO_LONG","titles must be <=200 chars");
     if(body.Length>4000)throw Fail("ARGS_TOO_LONG","body must be <=4000 chars");
     return RunSave(exe,db,scratch,finalTitle,body,theme);}
   if(mode=="reopen"){
     if(args.Length<6)throw Fail("ARGS_REOPEN","reopen needs 6 arguments: finalTitleB64 [bodyB64] (got "+args.Length+")");
     if(!File.Exists(db))throw Fail("DB_MISSING",db);
     string finalTitle=NeedB64(args[5],"final_title");
     string expectedBody=args.Length>=7?NeedB64(args[6],"body"):null;
     return RunReopen(exe,db,finalTitle,theme,expectedBody);}
   throw Fail("MODE_INVALID",mode);
  }catch(Exception ex){Console.Error.WriteLine(ex.ToString());return 1;}
 }

 static string Text(IntPtr w){var s=new StringBuilder(4096);UIntPtr r;
  if(TextMessage(w,WM_GETTEXT,new UIntPtr(4096),s,3,1500,out r)==IntPtr.Zero)throw new Exception("WM_GETTEXT timeout");
  return s.ToString();}
 static string ClassName(IntPtr w){var s=new StringBuilder(256);GetClassName(w,s,256);return s.ToString();}
 static List<IntPtr> Children(IntPtr root){var l=new List<IntPtr>();EnumChildWindows(root,delegate(IntPtr w,IntPtr p){l.Add(w);return true;},IntPtr.Zero);return l;}
 static List<IntPtr> Edits(IntPtr root){var l=new List<IntPtr>();foreach(var w in Children(root))if(ClassName(w)=="Edit")l.Add(w);return l;}
 static RECT Rect(IntPtr w){RECT r;if(!GetWindowRect(w,out r))throw new Exception("bounds");return r;}
 static bool Multiline(IntPtr w){return (GetWindowLong(w,GWL_STYLE)&ES_MULTILINE)!=0;}
 static bool HasValuePattern(IntPtr w){try{AutomationElement.FromHandle(w).GetCurrentPattern(ValuePattern.Pattern);return true;}catch(Exception){return false;}}
 static IntPtr FindContains(IntPtr root,string part,bool leftSide,bool rightSide){
  RECT rr=Rect(root);int middle=rr.left+(rr.right-rr.left)/2;
  foreach(var w in Children(root)){string t;try{t=Text(w);}catch(Exception){continue;}
   if(t.IndexOf(part,StringComparison.Ordinal)<0)continue;var r=Rect(w);if(r.right<=r.left)continue;
   bool left=r.right<=middle,right=r.left>=middle;
   if(leftSide&&left&&!right)return w;
   if(rightSide&&right&&!left)return w;
   if(!leftSide&&!rightSide)return w;}
  return IntPtr.Zero;}
 static IntPtr Button(IntPtr root,string text,bool leftSide,bool rightSide){var w=FindContains(root,text,leftSide,rightSide);
  if(w==IntPtr.Zero)throw new Exception("control missing: "+text);return w;}
 static bool HasText(IntPtr root,string part){foreach(var w in Children(root)){string t;try{t=Text(w);}catch(Exception){continue;}if(t.IndexOf(part,StringComparison.Ordinal)>=0)return true;}return false;}
 static void Wait(Func<bool> predicate,string label,int rounds=60){for(int i=0;i<rounds;i++){if(predicate())return;Thread.Sleep(50);}throw new Exception("Timeout: "+label);}
 static string Counts(IntPtr root){var parts=new List<string>();foreach(var w in Children(root)){string t;try{t=Text(w);}catch(Exception){continue;}if(t.IndexOf("份笔记",StringComparison.Ordinal)>=0||t=="收藏"||t=="取消收藏"||t=="归档"||t=="移回笔记")parts.Add(t);}return string.Join("|",parts);}
 static IntPtr Focused(){return new IntPtr(AutomationElement.FocusedElement.Current.NativeWindowHandle);}
 static void Focus(IntPtr w){AutomationElement.FromHandle(w).SetFocus();Wait(delegate{return new IntPtr(AutomationElement.FocusedElement.Current.NativeWindowHandle)==w;},"focus",20);}
 static void Key(ushort vk){var input=new INPUT[2];input[0].type=INPUT_KEYBOARD;input[0].u.k.vk=vk;input[1]=input[0];input[1].u.k.flags=KEYEVENTF_KEYUP;
  if(SendInput(2,input,Marshal.SizeOf(typeof(INPUT)))!=2)throw new Exception("SendInput key failed");Thread.Sleep(90);}
 static void Type(string text){foreach(var ch in text){
   var input=new INPUT[2];input[0].type=INPUT_KEYBOARD;input[0].u.k.scan=(ushort)ch;input[0].u.k.flags=KEYEVENTF_UNICODE;
   input[1]=input[0];input[1].u.k.flags=KEYEVENTF_UNICODE|KEYEVENTF_KEYUP;
   if(SendInput(2,input,Marshal.SizeOf(typeof(INPUT)))!=2)throw new Exception("SendInput text failed");Thread.Sleep(25);}Thread.Sleep(120);}
 static void CtrlKey(ushort vk,ushort mod){var i=new INPUT[4];
  i[0].type=INPUT_KEYBOARD;i[0].u.k.vk=mod;
  i[1].type=INPUT_KEYBOARD;i[1].u.k.vk=vk;
  i[2]=i[1];i[2].u.k.flags=KEYEVENTF_KEYUP;
  i[3]=i[0];i[3].u.k.flags=KEYEVENTF_KEYUP;
  if(SendInput(4,i,Marshal.SizeOf(typeof(INPUT)))!=4)throw new Exception("SendInput ctrl failed");Thread.Sleep(120);}
 static void ClearField(IntPtr w){Focus(w);CtrlKey(0x41,0x11);Key(0x2E);
  if(Text(w).Length!=0)throw new Exception("field clear failed: "+Text(w));}
 static void Click(IntPtr w){var r=Rect(w);if(!SetCursorPos((r.left+r.right)/2,(r.top+r.bottom)/2))throw new Exception("cursor");
  mouse_event(0x0002,0,0,0,UIntPtr.Zero);mouse_event(0x0004,0,0,0,UIntPtr.Zero);Thread.Sleep(180);}
 static bool HeadingIs(IntPtr root,string label){foreach(var w in Children(root)){if(ClassName(w)!="Static")continue;string t;try{t=Text(w);}catch(Exception){continue;}if(t==label)return true;}return false;}
 static string Breadcrumb(IntPtr root){foreach(var w in Children(root)){string t;try{t=Text(w);}catch(Exception){continue;}if(t.IndexOf("  /  笔记",StringComparison.Ordinal)>=0)return t;}return "<none>";}
 static void Nav(IntPtr root,string label){
  var b=Button(root,label,true,false);var r=Rect(b);
  Click(b);
  for(int i=0;i<40;i++){if(HeadingIs(root,label))return;Thread.Sleep(50);}
  FailLive(root,"NAV_MISMATCH","label="+label+" rect=["+r.left+","+r.top+","+r.right+","+r.bottom+"]");}
 static void Shot(IntPtr root,string path){
  RECT work,actual;if(!SystemParametersInfo(0x30,0,out work,0)||!GetWindowRect(root,out actual))throw new Exception("work area");
  int attempt=0;for(;attempt<20;attempt++){bool pending=GetUpdateRect(root,IntPtr.Zero,false);
   foreach(var w in Children(root))pending=pending||GetUpdateRect(w,IntPtr.Zero,false);
   if(!pending){if(DwmFlush()!=0)throw new Exception("DwmFlush");break;}Thread.Sleep(25);}
  if(attempt>=20)throw new Exception("Paint did not settle");
  Thread.Sleep(400);var r=Rect(root);
  using(var b=new Bitmap(r.right-r.left,r.bottom-r.top)){
   using(var g=Graphics.FromImage(b))g.CopyFromScreen(r.left,r.top,0,0,b.Size);
   b.Save(path,System.Drawing.Imaging.ImageFormat.Png);}}
 static Process StartApp(string exe,string db,string theme){
  return Process.Start(new ProcessStartInfo(exe,"--database \""+db+"\" --theme "+theme){UseShellExecute=false});}
 static IntPtr Root(Process app){IntPtr root=IntPtr.Zero;
  for(int i=0;i<120&&root==IntPtr.Zero;i++){
   EnumWindows(delegate(IntPtr w,IntPtr p){uint pid;GetWindowThreadProcessId(w,out pid);
    if(pid==app.Id&&Text(w)=="Leaf Notes"){root=w;return false;}return true;},IntPtr.Zero);
   if(root==IntPtr.Zero)Thread.Sleep(60);}
  if(root==IntPtr.Zero)throw Fail("ROOT_MISSING","Leaf Notes window not found");
  return root;}
 // Read-only foreground observation plus one bounded activation attempt. Never touches the
 // foreign window; a foreign foreground owner is reported, not dismissed.
 static void RequireForeground(IntPtr root){
  IntPtr fg=GetForegroundWindow();
  if(fg!=root){SetForegroundWindow(root);Thread.Sleep(500);fg=GetForegroundWindow();}
  if(fg!=root){
   uint fpid=0;if(fg!=IntPtr.Zero)GetWindowThreadProcessId(fg,out fpid);
   string cls=fg==IntPtr.Zero?"":ClassName(fg);
   string txt="";try{txt=fg==IntPtr.Zero?"":Text(fg);}catch(Exception){txt="<unreadable>";}
   throw Fail("FOREGROUND_BLOCKED","fgPid="+fpid+" class="+cls+" text="+txt+" (foreground owned by another window)");
  }
  Log("FOREGROUND ok handle="+root);}
 static IntPtr Title(IntPtr root,out IntPtr body,out IntPtr search){
  body=IntPtr.Zero;search=IntPtr.Zero;var singles=new List<IntPtr>();
  foreach(var w in Edits(root)){var r=Rect(w);if(r.right<=r.left)continue;
   if(Multiline(w)){if(body!=IntPtr.Zero)throw Fail("EDS_MULTIPLE_MULTILINE","more than one multiline editor");body=w;}
   else{if(!HasValuePattern(w))throw Fail("EDS_NO_VALUE_PATTERN","single-line editor without ValuePattern");singles.Add(w);}}
  singles.Sort(delegate(IntPtr a,IntPtr b){return Rect(a).left.CompareTo(Rect(b).left);});
  if(singles.Count>=2)search=singles[0];
  IntPtr title=singles.Count>0?singles[singles.Count-1]:IntPtr.Zero;
  if(title==IntPtr.Zero||body==IntPtr.Zero||search==IntPtr.Zero){
   var sb=new StringBuilder();foreach(var w in Edits(root)){var r=Rect(w);sb.Append("[text="+Text(w)+" left="+r.left+" multi="+Multiline(w)+"]");}
   throw Fail("EDS_MISSING",sb.ToString());}
  return title;}
 static IntPtr SearchOnly(IntPtr root){
  RECT rr=Rect(root);int middle=rr.left+(rr.right-rr.left)/2;IntPtr best=IntPtr.Zero;
  foreach(var w in Edits(root)){var r=Rect(w);if(r.right<=r.left||Multiline(w))continue;if(r.left<middle&&(best==IntPtr.Zero||r.top<Rect(best).top))best=w;}
  if(best==IntPtr.Zero)throw Fail("SEARCH_MISSING","search editor not found before selection");
  return best;}
 static void RequireInput(IntPtr root,IntPtr probe){
  Focus(probe);Type("x");
  if(!Text(probe).EndsWith("x"))throw Fail("INPUT_NOT_READY","typing probe did not reach the focused control");
  Key(0x08);Wait(delegate{return !Text(probe).EndsWith("x");},"probe clear",20);
  Log("INPUT ready");}
 static string LiveState(IntPtr root){
  var parts=new List<string>();
  IntPtr b,q;try{Title(root,out b,out q);parts.Add("search="+Text(q));}catch(Exception ex){parts.Add("search=<"+ex.Message+">");}
  parts.Add("breadcrumb="+Breadcrumb(root));
  var counts=new List<string>();foreach(var w in Children(root)){string t;try{t=Text(w);}catch(Exception){continue;}if(t.IndexOf("份笔记",StringComparison.Ordinal)>=0)counts.Add(t+(IsWindowVisible(w)?"(vis)":"(hid)"));}
  parts.Add("counts="+string.Join("/",counts));
  var btns=new List<string>();foreach(var w in Children(root)){if(ClassName(w)!="Button")continue;string t;try{t=Text(w);}catch(Exception){continue;}if(IsWindowVisible(w))btns.Add(t);}
  parts.Add("buttons="+string.Join("|",btns));
  return string.Join(" ",parts);}
 static void FailLive(IntPtr root,string code,string detail){
  string state=LiveState(root);
  try{Shot(root,prefix+"-fail-"+code+".png");}catch(Exception ex){Log("FAILSHOT failed "+ex.Message);}
  Log("FAIL "+code+" "+detail+" | "+state);
  throw Fail(code,detail+" | "+state);}
 static void EnsureFocused(IntPtr root,IntPtr w,string label){
  if(Focused()!=w){Click(w);if(Focused()!=w)Focus(w);}
  if(Focused()!=w)FailLive(root,"FOCUS_"+label,"focused="+Focused()+" target="+w);
  if(GetForegroundWindow()!=root)FailLive(root,"FOREGROUND_"+label,"fg="+GetForegroundWindow()+" root="+root);}
 static void ReplaceText(IntPtr root,IntPtr w,string value,string label){
  EnsureFocused(root,w,label);
  ClearField(w);
  EnsureFocused(root,w,label);
  Type(value);
  if(Text(w)!=value)FailLive(root,"TYPE_"+label,"got=\""+Text(w)+"\" want=\""+value+"\"");
  Log("TYPE ok "+label+" len="+value.Length);}
 static void WaitLive(IntPtr root,Func<bool> predicate,string label,int rounds=60){
  for(int i=0;i<rounds;i++){if(predicate())return;Thread.Sleep(50);}
  FailLive(root,"TIMEOUT_"+label,"timeout after "+(rounds*50)+"ms");}
 static void Tag(IntPtr root,string label){
  var b=Button(root,"·  "+label,true,false);Click(b);
  for(int i=0;i<40;i++){if(HeadingIs(root,label))return;Thread.Sleep(50);}
  FailLive(root,"TAG_VIEW_"+label,"tag did not apply");}
 static int RunMain(string exe,string db,string theme){
  var app=StartApp(exe,db,theme);bool natural=false;
  try{
   IntPtr root=Root(app);
   Log("DPI.Window="+GetDpiForWindow(root));
   RequireForeground(root);
   RequireInput(root,SearchOnly(root));
   if(!HasText(root,"4 份笔记"))FailLive(root,"SEED_COUNT","expected 4 seeded notes");
   Shot(root,prefix+"-initial-"+theme+".png");
   Nav(root,"已收藏");WaitLive(root,delegate{return HasText(root,"2 份笔记");},"view_favorites_seed");
   Nav(root,"归档");WaitLive(root,delegate{return HasText(root,"0 份笔记")&&HasText(root,"没有找到笔记");},"view_archive_empty");
   Nav(root,"全部笔记");WaitLive(root,delegate{return HasText(root,"4 份笔记");},"view_all");
   Shot(root,prefix+"-views-"+theme+".png");
   Tag(root,"灵感");WaitLive(root,delegate{return HasText(root,"2 份笔记");},"tag_inspiration");
   Tag(root,"日常");WaitLive(root,delegate{return HasText(root,"1 份笔记");},"tag_daily");
   Tag(root,"项目");WaitLive(root,delegate{return HasText(root,"1 份笔记");},"tag_project");
   Nav(root,"全部笔记");WaitLive(root,delegate{return HasText(root,"4 份笔记");},"tag_reset");
   Click(Button(root,"新建笔记",true,false));
   WaitLive(root,delegate{return HasText(root,"5 份笔记");},"new_note_count");
   IntPtr body,search;
   var title=Title(root,out body,out search);
   if(Text(title)!="未命名笔记")FailLive(root,"NEW_NOTE_NOT_SELECTED",Text(title));
   ReplaceText(root,title,"验收笔记A","title");
   WaitLive(root,delegate{return Text(title)=="验收笔记A";},"title_typing");
   if(!HasText(root,"更改尚未保存"))FailLive(root,"DIRTY_HINT","after title typing");
   EnsureFocused(root,body,"body");Type("第一行");Key(0x0D);Type("第二行 唯一标记😀");
   if(Text(body).IndexOf("\r\n",StringComparison.Ordinal)<0)FailLive(root,"MULTILINE_CRLF","body has no CRLF");
   ReplaceText(root,search,"唯一标记","search_body");WaitLive(root,delegate{return HasText(root,"1 份笔记");},"search_body");
   ReplaceText(root,search,"😀","search_emoji");WaitLive(root,delegate{return HasText(root,"1 份笔记");},"search_emoji");
   ReplaceText(root,search,"不存在的词条","search_empty");WaitLive(root,delegate{return HasText(root,"0 份笔记")&&HasText(root,"没有找到笔记");},"search_empty");
   ClearField(search);WaitLive(root,delegate{return HasText(root,"5 份笔记");},"search_cleared");
   ReplaceText(root,search,"专注","search_focus");WaitLive(root,delegate{return HasText(root,"1 份笔记");},"search_focus");
   Nav(root,"已收藏");WaitLive(root,delegate{return HasText(root,"1 份笔记");},"query_kept_across_nav");
   IntPtr b2,q2;Title(root,out b2,out q2);
   if(Text(q2)!="专注")FailLive(root,"QUERY_LOST_ACROSS_NAV","search="+Text(q2));
   ClearField(q2);WaitLive(root,delegate{return HasText(root,"2 份笔记");},"favorites_after_clear");
   Shot(root,prefix+"-favorites-"+theme+".png");
   Nav(root,"全部笔记");WaitLive(root,delegate{return HasText(root,"5 份笔记");},"all_after_query");
   Click(Button(root,"验收笔记A",true,false));Thread.Sleep(300);
   Click(Button(root,"收藏",false,true));WaitLive(root,delegate{return HasText(root,"取消收藏");},"favorite_toggle");
   Nav(root,"已收藏");WaitLive(root,delegate{return HasText(root,"3 份笔记");},"favorites_with_new");
   Nav(root,"全部笔记");WaitLive(root,delegate{return HasText(root,"5 份笔记");},"all_before_archive");
   Click(Button(root,"归档",false,true));
   WaitLive(root,delegate{return HasText(root,"4 份笔记");},"archive_removed_from_all");
   Nav(root,"归档");WaitLive(root,delegate{return HasText(root,"1 份笔记");},"archive_view_one");
   Click(Button(root,"验收笔记A",true,false));
   WaitLive(root,delegate{return HasText(root,"移回笔记");},"select_archived");
   Click(Button(root,"移回笔记",false,true));
   WaitLive(root,delegate{return HasText(root,"0 份笔记");},"restore_leaves_archive");
   Nav(root,"全部笔记");WaitLive(root,delegate{return HasText(root,"5 份笔记");},"all_after_restore");
   Click(Button(root,"Leaf 的第一份笔记",true,false));Thread.Sleep(300);
   Click(Button(root,"验收笔记A",true,false));
   title=Title(root,out body,out search);
   WaitLive(root,delegate{return Text(title)=="验收笔记A";},"draft_across_records");
   if(!HasText(root,"更改尚未保存"))FailLive(root,"DRAFT_DIRTY","after record switch");
   ClearField(title);
   Click(Button(root,"保存",false,true));
   WaitLive(root,delegate{return HasText(root,"标题不能为空");},"blank_title_rejected");
   if(Text(title)!="")FailLive(root,"DRAFT_LOST","after rejection");
   Shot(root,prefix+"-validation-"+theme+".png");
   ReplaceText(root,title,"最终标题","final_title");
   Click(Button(root,"保存",false,true));
   WaitLive(root,delegate{return HasText(root,"所有更改已保存");},"save_ok");
   Shot(root,prefix+"-saved-"+theme+".png");
   RECT bounds=Rect(root);
   SetWindowPos(root,IntPtr.Zero,0,0,900,bounds.bottom-bounds.top,SWP_NOMOVE|SWP_NOACTIVATE);
   Thread.Sleep(600);Shot(root,prefix+"-narrow-"+theme+".png");
   SetWindowPos(root,IntPtr.Zero,0,0,bounds.right-bounds.left,bounds.bottom-bounds.top,SWP_NOMOVE|SWP_NOACTIVATE);
   if(!app.CloseMainWindow())FailLive(root,"CLOSE_REJECTED","main");
   if(!app.WaitForExit(8000))FailLive(root,"EXIT_TIMEOUT","main");
   natural=true;Log("APP.ExitCode="+app.ExitCode+" natural=true");
   if(app.ExitCode!=0)FailLive(root,"EXIT_NONZERO","exit="+app.ExitCode);
  }finally{
   if(!natural&&!app.HasExited){app.Kill();app.WaitForExit(5000);Log("APP.Cleanup=forced");}
   app.Dispose();}
  var reopened=StartApp(exe,db,"dark");bool natural2=false;
  try{
   IntPtr root=Root(reopened);IntPtr b3,q3;var t3=Title(root,out b3,out q3);
   WaitLive(root,delegate{return Text(t3)=="最终标题";},"reopen_title");
   if(Text(b3).IndexOf("第二行",StringComparison.Ordinal)<0)FailLive(root,"REOPEN_BODY","body lost");
   if(Text(b3).IndexOf("😀",StringComparison.Ordinal)<0)FailLive(root,"REOPEN_EMOJI","emoji lost");
   Shot(root,prefix+"-reopened-dark.png");
   if(!reopened.CloseMainWindow())FailLive(root,"CLOSE_REJECTED","reopen");
   if(!reopened.WaitForExit(8000))FailLive(root,"EXIT_TIMEOUT","reopen");
   natural2=true;Log("APP.ExitCode="+reopened.ExitCode+" natural=true (reopen)");
  }finally{
   if(!natural2&&!reopened.HasExited){reopened.Kill();reopened.WaitForExit(5000);Log("APP.Cleanup=forced (reopen)");}
   reopened.Dispose();}
  Log("NOTES.PASS main");
  return 0;}

 static int RunSave(string exe,string db,string scratchTitle,string finalTitle,string body,string theme){
  var app=StartApp(exe,db,theme);bool natural=false;
  try{
   IntPtr root=Root(app);
   Log("DPI.Window="+GetDpiForWindow(root));
   RequireForeground(root);
   RequireInput(root,SearchOnly(root));
   if(!HasText(root,"4 份笔记"))FailLive(root,"SEED_COUNT","expected 4 seeded notes");
   Click(Button(root,"新建笔记",true,false));
   WaitLive(root,delegate{return HasText(root,"5 份笔记");},"new_note_count");
   IntPtr bodyEd,search;
   var title=Title(root,out bodyEd,out search);
   if(Text(title)!="未命名笔记")FailLive(root,"NEW_NOTE_NOT_SELECTED",Text(title));
   ReplaceText(root,title,scratchTitle,"scratch_title");
   EnsureFocused(root,bodyEd,"body");Type(body);
   if(Text(bodyEd)!=body)FailLive(root,"BODY_MISMATCH","typed body differs from requested (len got="+Text(bodyEd).Length+" want="+body.Length+")");
   ClearField(title);
   Click(Button(root,"保存",false,true));
   WaitLive(root,delegate{return HasText(root,"标题不能为空");},"blank_title_rejected");
   if(Text(title)!="")FailLive(root,"DRAFT_LOST","title not empty after rejection");
   Shot(root,prefix+"-rejected-"+theme+".png");
   ReplaceText(root,title,finalTitle,"final_title");
   Click(Button(root,"保存",false,true));
   WaitLive(root,delegate{return HasText(root,"所有更改已保存");},"save_ok");
   Shot(root,prefix+"-saved-"+theme+".png");
   if(!app.CloseMainWindow())FailLive(root,"CLOSE_REJECTED","save");
   if(!app.WaitForExit(8000))FailLive(root,"EXIT_TIMEOUT","save");
   natural=true;Log("APP.ExitCode="+app.ExitCode+" natural=true");
   if(app.ExitCode!=0)FailLive(root,"EXIT_NONZERO","exit="+app.ExitCode);
  }finally{
   if(!natural&&!app.HasExited){app.Kill();app.WaitForExit(5000);Log("APP.Cleanup=forced");}
   app.Dispose();}
  Log("NOTES.PASS save");
  return 0;}
 static int RunReopen(string exe,string db,string finalTitle,string theme,string expectedBody=null){
  var app=StartApp(exe,db,theme);bool natural=false;
  try{
   IntPtr root=Root(app);IntPtr bodyEd,search;var title=Title(root,out bodyEd,out search);
   RequireForeground(root);
   ReplaceText(root,search,finalTitle,"reopen_search");
   WaitLive(root,delegate{return HasText(root,"1 份笔记");},"reopen_search_unique");
   Click(Button(root,finalTitle,true,false));
   WaitLive(root,delegate{return Text(title)==finalTitle;},"reopen_select_title");
   if(expectedBody!=null&&Text(bodyEd)!=expectedBody)FailLive(root,"REOPEN_BODY_MISMATCH","len got="+Text(bodyEd).Length+" want="+expectedBody.Length);
   if(expectedBody==null&&Text(bodyEd).IndexOf("😀",StringComparison.Ordinal)<0)FailLive(root,"REOPEN_EMOJI","body lost emoji");
   Shot(root,prefix+"-reopen-"+theme+".png");
   if(!app.CloseMainWindow())FailLive(root,"CLOSE_REJECTED","reopen");
   if(!app.WaitForExit(8000))FailLive(root,"EXIT_TIMEOUT","reopen");
   natural=true;Log("APP.ExitCode="+app.ExitCode+" natural=true (reopen)");
   if(app.ExitCode!=0)FailLive(root,"EXIT_NONZERO","reopen exit="+app.ExitCode);
  }finally{
   if(!natural&&!app.HasExited){app.Kill();app.WaitForExit(5000);Log("APP.Cleanup=forced (reopen)");}
   app.Dispose();}
  Log("NOTES.PASS reopen");
  return 0;}
 static int RunLock(string exe,string db,string tool,string marker){
  if(!File.Exists(tool))throw Fail("LOCK_TOOL_MISSING",tool);
  if(File.Exists(marker))throw Fail("MARKER_EXISTS",marker);
  var app=StartApp(exe,db,"light");Process holder=null;bool natural=false;bool holderNatural=false;
  try{
   IntPtr root=Root(app);RequireForeground(root);
   RequireInput(root,SearchOnly(root));
   Click(Button(root,"新建笔记",true,false));
   Wait(delegate{return HasText(root,"5 份笔记");},"lock new note");
   IntPtr body,search;var title=Title(root,out body,out search);
   ReplaceText(root,title,"锁测试标题","lock_title");
   holder=Process.Start(new ProcessStartInfo(tool,"lock \""+db+"\" 8000 \""+marker+"\""){UseShellExecute=false,RedirectStandardOutput=true,RedirectStandardError=true});
   Wait(delegate{return File.Exists(marker);},"lock marker",160);
   Log("LOCK.Holder="+holder.Id);
   Click(Button(root,"保存",false,true));
   Wait(delegate{return HasText(root,"保存失败");},"save rejected under lock",300);
   if(Text(title)!="锁测试标题")throw Fail("DRAFT_LOST_UNDER_LOCK","title changed");
   Shot(root,prefix+"-lock-error.png");
   if(!holder.WaitForExit(15000))throw Fail("LOCK_HOLDER_TIMEOUT","holder did not exit");
   holderNatural=true;
   Log("LOCK.HolderExit="+holder.ExitCode+" natural=true out="+holder.StandardOutput.ReadToEnd().Replace("\r"," ").Replace("\n"," ").Trim());
   if(holder.ExitCode!=0)throw Fail("LOCK_HOLDER_NONZERO","exit="+holder.ExitCode);
   Click(Button(root,"保存",false,true));Wait(delegate{return HasText(root,"所有更改已保存");},"save after release");
   Shot(root,prefix+"-lock-recovered.png");
   if(!app.CloseMainWindow())throw Fail("CLOSE_REJECTED","lock");
   if(!app.WaitForExit(8000))throw Fail("EXIT_TIMEOUT","lock");
   natural=true;Log("APP.ExitCode="+app.ExitCode+" natural=true (lock)");
   if(app.ExitCode!=0)throw Fail("EXIT_NONZERO","lock exit="+app.ExitCode);
  }finally{
   if(holder!=null&&!holderNatural&&!holder.HasExited){holder.Kill();holder.WaitForExit(5000);Log("LOCK.HolderCleanup=forced");}
   if(!natural&&!app.HasExited){app.Kill();app.WaitForExit(5000);Log("APP.Cleanup=forced (lock)");}
   if(holder!=null)holder.Dispose();
   app.Dispose();
   if(File.Exists(marker)){try{File.Delete(marker);Log("MARKER removed=true");}catch(Exception ex){Log("MARKER remove failed: "+ex.Message);}}}
  var reopened=StartApp(exe,db,"light");bool natural2=false;
  try{
   IntPtr root=Root(reopened);IntPtr b2,s2;var t2=Title(root,out b2,out s2);
   Wait(delegate{return Text(t2)=="锁测试标题";},"reopen after lock");
   if(!reopened.CloseMainWindow())throw Fail("CLOSE_REJECTED","lock reopen");
   if(!reopened.WaitForExit(8000))throw Fail("EXIT_TIMEOUT","lock reopen");
   natural2=true;Log("APP.ExitCode="+reopened.ExitCode+" natural=true (lock reopen)");
  }finally{
   if(!natural2&&!reopened.HasExited){reopened.Kill();reopened.WaitForExit(5000);Log("APP.Cleanup=forced (lock reopen)");}
   reopened.Dispose();}
  Log("NOTES.PASS lock");
  return 0;}
}
