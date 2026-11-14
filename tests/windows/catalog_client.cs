using System;using System.Text;using System.Diagnostics;using System.Threading;using System.Runtime.InteropServices;using System.Collections.Generic;using System.Windows.Automation;using System.Drawing;
public class CatalogClient {
 [StructLayout(LayoutKind.Sequential)] public struct RECT {public int left,top,right,bottom;}
 [StructLayout(LayoutKind.Sequential)] struct KI {public ushort vk,scan;public uint flags,time;public UIntPtr extra;}
 [StructLayout(LayoutKind.Sequential)] struct MI {public int x,y;public uint data,flags,time;public UIntPtr extra;}
 [StructLayout(LayoutKind.Explicit)] struct U {[FieldOffset(0)]public KI k;[FieldOffset(0)]public MI m;}
 [StructLayout(LayoutKind.Sequential)] struct INPUT {public uint type;public U u;}
 [DllImport("user32.dll")] static extern bool GetUpdateRect(IntPtr w,IntPtr r,bool erase);
 [DllImport("dwmapi.dll")] static extern int DwmFlush();
 delegate bool EnumProc(IntPtr w,IntPtr p);
 [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p,IntPtr data);
 [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr w,EnumProc p,IntPtr data);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr w,out uint pid);
 [DllImport("user32.dll",EntryPoint="SendMessageTimeoutW",CharSet=CharSet.Unicode)] static extern IntPtr TextMessage(IntPtr w,uint m,UIntPtr p,StringBuilder text,uint flags,uint timeout,out UIntPtr r);
 [DllImport("user32.dll",EntryPoint="SendMessageTimeoutW")] static extern IntPtr ValueMessage(IntPtr w,uint m,UIntPtr p,IntPtr l,uint flags,uint timeout,out UIntPtr r);
 [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr w,out RECT r);
 [DllImport("user32.dll")] static extern bool RedrawWindow(IntPtr w,IntPtr rect,IntPtr region,uint flags);
 [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr w);
 [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr w,IntPtr after,int x,int y,int width,int height,uint flags);
 [DllImport("user32.dll")] static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] static extern void mouse_event(uint flags,uint x,uint y,uint data,UIntPtr extra);
 [DllImport("user32.dll")] static extern uint SendInput(uint n,INPUT[] input,int size);
 [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr w);
 static void Need(bool ok,string text){if(!ok)throw new Exception(text);}
 static void Wait(Func<bool> predicate,string label){for(int i=0;i<30;i++){if(predicate())return;Thread.Sleep(40);}throw new Exception("Timeout: "+label);}
 static string Text(IntPtr w){var s=new StringBuilder(1024);UIntPtr r;Need(TextMessage(w,13,new UIntPtr(1024),s,3,1500,out r)!=IntPtr.Zero,"WM_GETTEXT timeout");return s.ToString();}
 static int Checked(IntPtr w){UIntPtr r;Need(ValueMessage(w,0xf0,UIntPtr.Zero,IntPtr.Zero,3,1500,out r)!=IntPtr.Zero,"BM_GETCHECK timeout");return (int)r.ToUInt64();}
 static IntPtr Find(IntPtr root,string text){IntPtr found=IntPtr.Zero;EnumChildWindows(root,delegate(IntPtr w,IntPtr p){if(Text(w)==text){found=w;return false;}return true;},IntPtr.Zero);return found;}
 static AutomationElement Element(IntPtr w){return AutomationElement.FromHandle(w);}
 static TogglePattern Toggle(IntPtr w){return (TogglePattern)Element(w).GetCurrentPattern(TogglePattern.Pattern);}
 static void Focus(IntPtr w){Element(w).SetFocus();Wait(delegate{return AutomationElement.FocusedElement.Current.NativeWindowHandle==w.ToInt32();},"focus");}
 static void Key(ushort key){var input=new INPUT[2];input[0].type=1;input[0].u.k.vk=key;input[1]=input[0];input[1].u.k.flags=2;Need(SendInput(2,input,Marshal.SizeOf(typeof(INPUT)))==2,"SendInput failed");Thread.Sleep(120);}
 static void ClickLabel(IntPtr w){RECT r;Need(GetWindowRect(w,out r),"click bounds");Need(SetCursorPos(r.right-5,(r.top+r.bottom)/2),"cursor move");mouse_event(2,0,0,0,UIntPtr.Zero);mouse_event(4,0,0,0,UIntPtr.Zero);Thread.Sleep(150);}
 static bool PendingPaint(IntPtr root){bool pending=GetUpdateRect(root,IntPtr.Zero,false);EnumChildWindows(root,delegate(IntPtr w,IntPtr p){pending=pending||GetUpdateRect(w,IntPtr.Zero,false);return true;},IntPtr.Zero);return pending;}
 [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint action,uint param,out RECT rect,uint flags);
 static void Shot(IntPtr root,string path){RECT work=new RECT(),actual=new RECT();Need(SystemParametersInfo(0x30,0,out work,0)&&GetWindowRect(root,out actual),"Work area missing");Need(actual.left>=work.left&&actual.top>=work.top&&actual.right<=work.right&&actual.bottom<=work.bottom,"Window exceeds usable desktop");Thread.Sleep(150);int attempt=0;for(;attempt<20;attempt++){if(!PendingPaint(root)){Need(DwmFlush()==0,"DwmFlush failed");if(!PendingPaint(root))break;}Thread.Sleep(25);}Need(attempt<20,"Paint did not settle");RECT r;Need(GetWindowRect(root,out r),"Screenshot bounds missing");using(var b=new Bitmap(r.right-r.left,r.bottom-r.top)){using(var g=Graphics.FromImage(b))g.CopyFromScreen(r.left,r.top,0,0,b.Size);b.Save(path,System.Drawing.Imaging.ImageFormat.Png);}}
 static void Invoke(IntPtr w){((InvokePattern)Element(w).GetCurrentPattern(InvokePattern.Pattern)).Invoke();}
 [MTAThread]public static int Main(string[] args){
  Console.OutputEncoding=new UTF8Encoding(false);Process app=null;
  try{
   app=Process.Start(new ProcessStartInfo(args[0]){UseShellExecute=false,RedirectStandardError=true});System.IO.File.WriteAllText(args[1],app.Id.ToString());IntPtr root=IntPtr.Zero;
   for(int i=0;i<80 && root==IntPtr.Zero;i++){
    EnumWindows(delegate(IntPtr w,IntPtr unused){uint pid;GetWindowThreadProcessId(w,out pid);if(pid==app.Id && Text(w)=="Leaf — 标准组件目录"){root=w;return false;}return true;},IntPtr.Zero);
    if(root==IntPtr.Zero)Thread.Sleep(50);
   }
   Need(root!=IntPtr.Zero,"Owned catalog root missing");Need(SetForegroundWindow(root),"Foreground activation");
   var mode=Find(root,"切换到深色");var form=Find(root,"表单");var groups=Find(root,"组合");var feedback=Find(root,"反馈");var animation=Find(root,"动画");var empty=Find(root,"空态");
   Need(mode!=IntPtr.Zero&&form!=IntPtr.Zero&&groups!=IntPtr.Zero&&feedback!=IntPtr.Zero&&animation!=IntPtr.Zero&&empty!=IntPtr.Zero,"Navigation missing");
   Console.WriteLine("DPI.Window="+GetDpiForWindow(root));
   Shot(root,args[1]+"-form-light.png");
   var edit=Find(root,"Leaf 用户");Need(edit!=IntPtr.Zero,"Name editor missing");Focus(edit);Key(35);Key(65);Wait(delegate{return Text(edit)=="Leaf 用户a";},"name typing");
   ClickLabel(mode);Wait(delegate{return Text(mode)=="切换到浅色";},"dark mode");Need(Find(root,"Leaf 用户a")==edit,"Theme rebuilt EDIT");Shot(root,args[1]+"-form-dark.png");
   var check=Find(root,"接收更新");Focus(check);Key(32);Wait(delegate{return Checked(check)==1;},"checkbox Space");
   var toggle=Find(root,"启用通知");Toggle(toggle).Toggle();Wait(delegate{return Checked(toggle)==0;},"switch toggle");
   ((ValuePattern)Element(edit).GetCurrentPattern(ValuePattern.Pattern)).SetValue("");Invoke(Find(root,"保存"));Wait(delegate{return Find(root,"名称不能为空。")!=IntPtr.Zero;},"required validation");Shot(root,args[1]+"-form-error-dark.png");
   ((ValuePattern)Element(edit).GetCurrentPattern(ValuePattern.Pattern)).SetValue("Leaf 用户a");Invoke(Find(root,"保存"));Wait(delegate{return Find(root,"已保存到内存")!=IntPtr.Zero;},"save");
   Focus(edit);Key(35);Key(66);Wait(delegate{return Text(edit)=="Leaf 用户ab";},"unsaved edit");Invoke(Find(root,"取消"));Wait(delegate{return Text(edit)=="Leaf 用户a";},"cancel");
   ClickLabel(groups);Wait(delegate{return Find(root,"站点地址组合")!=IntPtr.Zero;},"groups page");
   var address=Find(root,"leaf");Focus(address);Key(35);Key(65);Wait(delegate{return Text(address)=="leafa";},"address typing");
   var plus=Find(root,"增加");Focus(plus);Key(32);Wait(delegate{return Find(root,"计数：1")!=IntPtr.Zero;},"Space increment");Shot(root,args[1]+"-groups-dark.png");
   Invoke(feedback);Wait(delegate{return Find(root,"推进25%")!=IntPtr.Zero;},"feedback page");
   Shot(root,args[1]+"-feedback-dark-0.png");
   var next=Find(root,"推进25%");for(int i=1;i<=4;i++){Invoke(next);int expected=i*25;Wait(delegate{return Find(root,"进度："+expected+"%")!=IntPtr.Zero;},"progress step");Shot(root,args[1]+"-feedback-dark-"+expected+".png");}Wait(delegate{return Find(root,"进度：100%")!=IntPtr.Zero;},"progress complete");Need(!Element(next).Current.IsEnabled,"Completed progress action enabled");
   Shot(root,args[1]+"-feedback-dark.png");
   Invoke(mode);Wait(delegate{return Text(mode)=="切换到深色";},"feedback light");Shot(root,args[1]+"-feedback-light-after-update.png");
   Invoke(mode);Wait(delegate{return Text(mode)=="切换到浅色";},"feedback dark");Need(RedrawWindow(root,IntPtr.Zero,IntPtr.Zero,0x185),"full repaint");Shot(root,args[1]+"-feedback-dark-repaint.png");Invoke(empty);Wait(delegate{return Find(root,"创建示例")!=IntPtr.Zero;},"empty page");Invoke(Find(root,"创建示例"));Wait(delegate{return Find(root,"已创建示例项目")!=IntPtr.Zero;},"create feedback");Shot(root,args[1]+"-empty-dark.png");
   Invoke(animation);Wait(delegate{return Find(root,"加载完成")!=IntPtr.Zero;},"animation page");Shot(root,args[1]+"-animation-dark.png");
   Invoke(Find(root,"加载完成"));Wait(delegate{return Find(root,"内容已加载")!=IntPtr.Zero;},"unload animation");
   Shot(root,args[1]+"-animation-loaded.png");
   Focus(form);Key(32);Wait(delegate{return Find(root,"Leaf 用户a")!=IntPtr.Zero;},"form draft retained");Need(Checked(Find(root,"接收更新"))==1&&Checked(Find(root,"启用通知"))==0,"Boolean state lost");
   Invoke(groups);Wait(delegate{return Find(root,"leafa")!=IntPtr.Zero;},"address draft retained");
   RECT bounds;Need(GetWindowRect(root,out bounds),"bounds");Need(SetWindowPos(root,IntPtr.Zero,0,0,496,bounds.bottom-bounds.top,0x16),"narrow");Shot(root,args[1]+"-groups-narrow.png");
   Invoke(mode);Wait(delegate{return Text(mode)=="切换到深色";},"light mode");Invoke(form);Shot(root,args[1]+"-form-narrow.png");
   Invoke(feedback);Shot(root,args[1]+"-feedback-narrow.png");
   Invoke(empty);Shot(root,args[1]+"-empty-narrow.png");Invoke(animation);Shot(root,args[1]+"-animation-narrow.png");
   Focus(form);Key(9);Wait(delegate{return AutomationElement.FocusedElement.Current.NativeWindowHandle==groups.ToInt32();},"Tab navigation");
   Console.WriteLine("CATALOG Navigation/Mouse/Space/Tab/Drafts/Validation/Save/Cancel/Booleans/Theme/Progress/Empty/Animation=PASS");return 0;
  }catch(Exception ex){Console.Error.WriteLine(ex.ToString());return 1;}
  finally{if(app!=null){if(!app.HasExited){app.CloseMainWindow();Need(app.WaitForExit(5000),"Owned app exit timeout");}Console.WriteLine("APP.Exited=true ExitCode="+app.ExitCode);Console.Error.Write(app.StandardError.ReadToEnd());Need(app.ExitCode==0,"App nonzero exit");app.Dispose();}}
 }
}

