using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Automation;
public class SpinnerClient {
 [ComImport,Guid("d22108aa-8ac5-49a5-837b-37bbb3d7591e"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
 public interface NativeElement {
  [PreserveSig]int SetFocus();
  [PreserveSig]int GetRuntimeId(out IntPtr array);
  [PreserveSig]int FindFirst(int scope,IntPtr condition,out IntPtr e);
  [PreserveSig]int FindAll(int scope,IntPtr condition,out IntPtr e);
  [PreserveSig]int FindFirstBuildCache(int scope,IntPtr c,IntPtr cache,out IntPtr e);
  [PreserveSig]int FindAllBuildCache(int scope,IntPtr c,IntPtr cache,out IntPtr e);
  [PreserveSig]int BuildUpdatedCache(IntPtr cache,out IntPtr e);
  [PreserveSig]int GetCurrentPropertyValue(int id,[MarshalAs(UnmanagedType.Struct)]out object value);
  [PreserveSig]int GetCurrentPropertyValueEx(int id,[MarshalAs(UnmanagedType.Bool)]bool ignoreDefault,[MarshalAs(UnmanagedType.Struct)]out object value);
 }

 [ComImport,Guid("30cbe57d-d9d0-452a-ab13-7ac5ac4825ee"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
 public interface NativeAutomation {
  [PreserveSig]int CompareElements(IntPtr a,IntPtr b,out int same);
  [PreserveSig]int CompareRuntimeIds(IntPtr a,IntPtr b,out int same);
  [PreserveSig]int GetRootElement(out NativeElement e);
  [PreserveSig]int ElementFromHandle(IntPtr hwnd,out NativeElement e);
  // Unused public SDK vtable slots 7..31; never invoked. See IUIAutomationVtbl.
  [PreserveSig]int UnusedSlot7();
  [PreserveSig]int UnusedSlot8();
  [PreserveSig]int UnusedSlot9();
  [PreserveSig]int UnusedSlot10();
  [PreserveSig]int UnusedSlot11();
  [PreserveSig]int UnusedSlot12();
  [PreserveSig]int UnusedSlot13();
  [PreserveSig]int UnusedSlot14();
  [PreserveSig]int UnusedSlot15();
  [PreserveSig]int UnusedSlot16();
  [PreserveSig]int UnusedSlot17();
  [PreserveSig]int UnusedSlot18();
  [PreserveSig]int UnusedSlot19();
  [PreserveSig]int UnusedSlot20();
  [PreserveSig]int UnusedSlot21();
  [PreserveSig]int UnusedSlot22();
  [PreserveSig]int UnusedSlot23();
  [PreserveSig]int UnusedSlot24();
  [PreserveSig]int UnusedSlot25();
  [PreserveSig]int UnusedSlot26();
  [PreserveSig]int UnusedSlot27();
  [PreserveSig]int UnusedSlot28();
  [PreserveSig]int UnusedSlot29();
  [PreserveSig]int UnusedSlot30();
  [PreserveSig]int UnusedSlot31();

  [PreserveSig]int AddAutomationEventHandler(int id,NativeElement element,int scope,IntPtr cache,EventsHandler handler);
  [PreserveSig]int RemoveAutomationEventHandler(int id,NativeElement element,EventsHandler handler);
  [PreserveSig]int AddPropertyChangedEventHandlerNativeArray(NativeElement element,int scope,IntPtr cache,PropertiesHandler handler,[MarshalAs(UnmanagedType.LPArray,SizeParamIndex=5)]int[] ids,int count);
  [PreserveSig]int UnusedSlot35();
  [PreserveSig]int RemovePropertyChangedEventHandler(NativeElement element,PropertiesHandler handler);
  [PreserveSig]int UnusedSlot37();
  [PreserveSig]int UnusedSlot38();
  [PreserveSig]int UnusedSlot39();
  [PreserveSig]int UnusedSlot40();
  [PreserveSig]int RemoveAllEventHandlers();
 }
 [ComVisible(true),Guid("146c3c17-f12e-4e22-8c27-f894b9b79c69"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
 public interface EventsHandler {[PreserveSig]int HandleAutomationEvent(NativeElement sender,int id);}
 [ComVisible(true),Guid("40cd37d4-c756-4b0c-8c6f-bddfeeb13b50"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
 public interface PropertiesHandler {[PreserveSig]int HandlePropertyChangedEvent(NativeElement sender,int id,[MarshalAs(UnmanagedType.Struct)]object value);}
 [ComVisible(true),ClassInterface(ClassInterfaceType.None)]
 public class Observer:EventsHandler,PropertiesHandler {
  public readonly object Sync=new object();public readonly List<string> Live=new List<string>();
  public readonly List<string> Properties=new List<string>();public string Error;
  public int HandleAutomationEvent(NativeElement sender,int id){try{object v;Marshal.ThrowExceptionForHR(sender.GetCurrentPropertyValue(30005,out v));lock(Sync){Live.Add(Convert.ToString(v));}Console.WriteLine("LiveRegionChanged="+v);return 0;}catch(Exception e){lock(Sync){Error=e.ToString();}return Marshal.GetHRForException(e);}}
  public int HandlePropertyChangedEvent(NativeElement sender,int id,object value){lock(Sync){Properties.Add(id+"="+value);}Console.WriteLine("PropertyChanged="+id+"="+value);return 0;}
  public int Count{get{lock(Sync){return Live.Count;}}}
  public void WaitFor(string name,int count){var clock=Stopwatch.StartNew();while(clock.ElapsedMilliseconds<6000){lock(Sync){if(Error!=null)throw new Exception(Error);if(Live.Count==count&&Live[count-1]==name)return;}Thread.Sleep(25);}throw new Exception("Missing/excess live event: "+name+", count="+Count);}
  public void Quiet(int count){Thread.Sleep(700);Require(Count==count,"duplicate/rejected live event; expected="+count+" actual="+Count);}
  public bool PropertySeen(string value){lock(Sync){return Properties.Contains(value);}}
 }
 static void Require(bool ok,string why){if(!ok)throw new Exception(why);}
 static object Value(NativeElement e,int id){object value;Marshal.ThrowExceptionForHR(e.GetCurrentPropertyValueEx(id,true,out value));return value;}
 static void Number(NativeElement e,int id,int expected){object value=Value(e,id);Require(value is int&&(int)value==expected,"UIA property "+id+" expected "+expected+", got "+value);}
 static AutomationElement Find(AutomationElement root,string name){var e=root.FindFirst(TreeScope.Descendants,new PropertyCondition(AutomationElement.NameProperty,name));Require(e!=null,"Missing element: "+name);return e;}
 static void Invoke(AutomationElement root,string name){((InvokePattern)Find(root,name).GetCurrentPattern(InvokePattern.Pattern)).Invoke();}
 [MTAThread] public static int Main(string[] args){
  NativeAutomation u=null;NativeElement status=null;Observer observer=new Observer();
  try {
   var process=Process.GetProcessById(int.Parse(args[0]));IntPtr hwnd=IntPtr.Zero;
   for(int i=0;i<100&&hwnd==IntPtr.Zero;i++){process.Refresh();hwnd=process.MainWindowHandle;if(hwnd==IntPtr.Zero)Thread.Sleep(50);}
   Require(hwnd!=IntPtr.Zero,"Missing app window");
   var root=AutomationElement.FromHandle(hwnd);var element=Find(root,"Loading");
   u=(NativeAutomation)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("ff48dba4-60ef-4201-aa87-54103eef594e")));
   Marshal.ThrowExceptionForHR(u.ElementFromHandle(new IntPtr(element.Current.NativeWindowHandle),out status));
   Number(status,30135,1);Number(status,30003,50017);
   Require(!element.Current.IsKeyboardFocusable,"Spinner must not take focus");
   Marshal.ThrowExceptionForHR(u.AddAutomationEventHandler(20024,status,1,IntPtr.Zero,observer));
   observer.Quiet(0);Invoke(root,"Update status");observer.WaitFor("Loading next",1);observer.Quiet(1);
   Require((string)Value(status,30005)=="Loading next","Name did not update");
   Invoke(root,"Toggle theme");observer.Quiet(1);
   Require((string)Value(status,30005)=="Loading next","Theme changed semantics");
   Invoke(root,"Toggle spinner");Thread.Sleep(500);
   object removed;int hr=status.GetCurrentPropertyValueEx(30005,true,out removed);
   Require(hr<0,"Removed spinner still queryable");
   Invoke(root,"Toggle spinner");Thread.Sleep(400);Require(Find(root,"Loading next")!=null,"Remount missing");
   Console.WriteLine("PASS Spinner role/live/name/events/theme/removal/remount");return 0;
  }catch(Exception e){Console.Error.WriteLine(e);return 1;}
  finally{if(u!=null){u.RemoveAllEventHandlers();Marshal.ReleaseComObject(u);}if(status!=null)Marshal.ReleaseComObject(status);}
 }
}
