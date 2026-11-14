using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
class FenceContract {
 delegate bool EnumProc(IntPtr w, IntPtr p);
 [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr w,out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr GetProp(IntPtr w,string n);
 [DllImport("user32.dll")] static extern bool PostMessage(IntPtr w,uint m,IntPtr a,IntPtr b);
 static long Read(IntPtr w,string n){return GetProp(w,n).ToInt64();}
 static int Main(string[] args) {
  Process app=null;
  try {
   var start=new ProcessStartInfo(args[0]);start.UseShellExecute=false;
   string fault=args.Length>1?args[1]:"";
   if(fault!="")start.EnvironmentVariables["LEAF_FENCE_TEST_FAULT"]=fault;
   app=Process.Start(start); IntPtr window=IntPtr.Zero;
   var clock=Stopwatch.StartNew();
   while(clock.ElapsedMilliseconds<5000 && window==IntPtr.Zero){
    EnumWindows(delegate(IntPtr w,IntPtr p){uint pid;GetWindowThreadProcessId(w,out pid);if(pid==app.Id && Read(w,"leafTurnSeq")>0)window=w;return true;},IntPtr.Zero);Thread.Sleep(20);
   }
   if(window==IntPtr.Zero)throw new Exception("fixture not ready");
   Thread.Sleep(150);
   long renders=Read(window,"leafRenderCount"), before=Read(window,"leafTurnSeq");
   if(renders<=0)throw new Exception("render telemetry missing");
   if(!PostMessage(window,0x802A,(IntPtr)73,IntPtr.Zero))throw new Exception("post failed");
   clock.Restart(); bool ack=false;
   while(clock.ElapsedMilliseconds<2000){if(Read(window,"leafFenceAck")==74 && Read(window,"leafFenceTurn")>before){ack=true;break;}Thread.Sleep(10);}
   long after=Read(window,"leafRenderCount");
   Console.WriteLine("fence ack="+ack+" renderBefore="+renders+" renderAfter="+after);
   if(fault!="") {
    if(ack)throw new Exception("failed fence was acknowledged");
    if(!app.WaitForExit(2000) || app.ExitCode==0)throw new Exception("failure was hidden");
    Console.WriteLine("FAULT CONTRACT PASSED: "+fault);return 0;
   }
   if(!ack || after!=renders)throw new Exception("fence must not refresh application state");
   // No request 74 was sent: a stale ack for 73 must never satisfy it.
   clock.Restart();while(clock.ElapsedMilliseconds<150){if(Read(window,"leafFenceAck")==75)throw new Exception("unsent request acknowledged");Thread.Sleep(10);}
   long priorAckTurn=Read(window,"leafFenceTurn");
   if(!PostMessage(window,0x802A,(IntPtr)74,IntPtr.Zero))throw new Exception("second post failed");
   clock.Restart();bool second=false;
   while(clock.ElapsedMilliseconds<2000){long id=Read(window,"leafFenceAck"), turn=Read(window,"leafFenceTurn");if(id==75 && Read(window,"leafFenceAck")==id && turn>priorAckTurn){second=true;break;}Thread.Sleep(10);}
   if(!second || Read(window,"leafRenderCount")!=renders)throw new Exception("fresh request/turn contract failed");
   Console.WriteLine("stale request rejected; fresh request matched with later turn");
   Console.WriteLine("FENCE CONTRACT PASSED");return 0;
  }catch(Exception e){Console.WriteLine("FAILED: "+e.Message);return 1;}
  finally{if(app!=null && !app.HasExited){app.CloseMainWindow();if(!app.WaitForExit(2000)){app.Kill();app.WaitForExit(2000);}}}
 }
}
