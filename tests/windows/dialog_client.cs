// Cross-process UI Automation acceptance for the native Dialog/AlertDialog.
//
// The client launches the example application, drives it only through UIA
// patterns (Invoke/Value), and captures real screen pixels. It asserts the
// modal semantics that must hold across processes: a separate top-level
// window, the page disabled while the level is open and enabled again after it
// closes, nesting that closes only the top level, and an AlertDialog that keeps
// its cancel control as focus target.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Automation;

public class DialogClient
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern IntPtr GetThreadDpiAwarenessContext();
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern IntPtr GetWindowDpiAwarenessContext(IntPtr window);
    [DllImport("user32.dll")] static extern bool AreDpiAwarenessContextsEqual(IntPtr a, IntPtr b);
    [DllImport("user32.dll")] static extern int GetAwarenessFromDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hWnd, IntPtr after,
        int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
    [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr param);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr window, System.Text.StringBuilder text, int length);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr window, System.Text.StringBuilder text, int length);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT point);
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr window, uint command);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    delegate bool EnumProc(IntPtr window, IntPtr param);

    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern uint SendInput(uint count, MousePacket[] inputs, int size);
    [StructLayout(LayoutKind.Sequential)] struct MouseInput
    { public int x, y; public uint data, flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct MousePacket
    { public uint kind; public MouseInput mouse; }

    static void ActivateForInput(IntPtr window)
    {
        SetForegroundWindow(window);
        if (GetForegroundWindow() != window)
        {
            RECT rect;
            if (!IsWindowVisible(window) || !IsWindowEnabled(window) || !GetWindowRect(window, out rect))
                throw new InvalidOperationException("activation target is not a live enabled window");
            var point = new POINT { X = rect.Left + Math.Min(80, (rect.Right - rect.Left) / 2), Y = rect.Top + 12 };
            if (GetAncestor(WindowFromPoint(point), 2) != window)
                throw new InvalidOperationException("activation target is covered; refusing to click another window");
            if (!SetCursorPos(point.X, point.Y)) throw new InvalidOperationException("cursor placement failed");
            var inputs = new MousePacket[2];
            inputs[0].mouse.flags = 0x0002; inputs[1].mouse.flags = 0x0004;
            if (SendInput(2, inputs, Marshal.SizeOf(typeof(MousePacket))) != 2)
                throw new InvalidOperationException("activation input was not fully submitted");
        }
        if (!WaitUntil(delegate { return GetForegroundWindow() == window; }, 1500))
            throw new InvalidOperationException("input target did not become foreground");
        Console.WriteLine("[FOREGROUND] verified=" + window);
    }

    static void DumpProcessWindows(int processId)
    {
        EnumWindows(delegate (IntPtr window, IntPtr param)
        {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner != processId) return true;
            var title = new System.Text.StringBuilder(256);
            var cls = new System.Text.StringBuilder(256);
            GetWindowText(window, title, 256);
            GetClassName(window, cls, 256);
            Console.WriteLine("[WIN] class='" + cls + "' title='" + title + "' visible=" +
                IsWindowVisible(window) + " hwnd=" + window.ToInt64());
            try
            {
                var element = AutomationElement.FromHandle(window);
                Console.WriteLine("[FROMHANDLE] type=" + element.Current.ControlType.ProgrammaticName +
                    " name='" + element.Current.Name + "' enabled=" + element.Current.IsEnabled);
            }
            catch (Exception error) { Console.WriteLine("[FROMHANDLE] failed " + error.GetType().Name); }
            return true;
        }, IntPtr.Zero);
    }

    static int failures;
    static string output;

    static void Check(bool ok, string what)
    {
        Console.WriteLine((ok ? "[OK] " : "[FAILED] ") + what);
        if (!ok) failures++;
    }

    static void Note(string what) { Console.WriteLine("[NOTE] " + what); }

    static AutomationElement WaitFor(Func<AutomationElement> probe, int milliseconds, string what)
    {
        var watch = Stopwatch.StartNew();
        while (watch.ElapsedMilliseconds < milliseconds)
        {
            var found = probe();
            if (found != null) return found;
            Thread.Sleep(120);
        }
        Check(false, "timed out waiting for " + what);
        return null;
    }

    static AutomationElement ByName(AutomationElement root, TreeScope scope, string name)
    {
        if (root == null) return null;
        var condition = new AndCondition(
            new PropertyCondition(AutomationElement.NameProperty, name),
            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button));
        return root.FindFirst(scope, condition);
    }

    static AutomationElement WindowByName(AutomationElement root, int processId, string name)
    {
        var condition = new AndCondition(
            new PropertyCondition(AutomationElement.ProcessIdProperty, processId),
            new PropertyCondition(AutomationElement.NameProperty, name),
            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Window));
        return root.FindFirst(TreeScope.Descendants, condition);
    }

    static void Invoke(AutomationElement element, string what)
    {
        if (element == null) { Check(false, "missing control " + what); return; }
        try
        {
            var pattern = (InvokePattern)element.GetCurrentPattern(InvokePattern.Pattern);
            pattern.Invoke();
        }
        catch (Exception error)
        {
            Check(false, "invoke " + what + " failed: " + error.GetType().Name);
        }
    }



    [StructLayout(LayoutKind.Sequential)]
    struct GUITHREADINFO
    {
        public int cbSize;
        public int flags;
        public IntPtr hwndActive;
        public IntPtr hwndFocus;
        public IntPtr hwndCapture;
        public IntPtr hwndMenuOwner;
        public IntPtr hwndMoveSize;
        public IntPtr hwndCaret;
        public RECT rcCaret;
    }

    [DllImport("user32.dll")]
    static extern bool GetGUIThreadInfo(uint threadId, ref GUITHREADINFO info);

    static IntPtr FocusedHwnd(IntPtr anyWindowInThread)
    {
        uint pid;
        uint thread = GetWindowThreadProcessId(anyWindowInThread, out pid);
        var info = new GUITHREADINFO();
        info.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
        if (!GetGUIThreadInfo(thread, ref info)) return IntPtr.Zero;
        return info.hwndFocus;
    }

    static bool FocusInsideSurface(IntPtr surface, IntPtr focus)
    {
        if (surface == IntPtr.Zero || focus == IntPtr.Zero) return false;
        return focus == surface || GetAncestor(focus, 2) == surface;
    }

    static bool WaitUntil(Func<bool> predicate, int milliseconds)
    {
        var watch = Stopwatch.StartNew();
        while (watch.ElapsedMilliseconds < milliseconds)
        {
            if (predicate()) return true;
            Thread.Sleep(60);
        }
        return predicate();
    }

    static bool TargetFocused(IntPtr surface, AutomationElement target)
    {
        IntPtr hwnd = new IntPtr(target.Current.NativeWindowHandle);
        return hwnd != IntPtr.Zero && FocusInsideSurface(surface, hwnd) && FocusedHwnd(surface) == hwnd;
    }

    static System.Collections.Generic.HashSet<IntPtr> verifiedFocus = new System.Collections.Generic.HashSet<IntPtr>();

    static void FocusPositive(IntPtr surface, AutomationElement target, AutomationElement alternate)
    {
        if (target == null || alternate == null) throw new InvalidOperationException("focus control missing");
        IntPtr hwnd = new IntPtr(target.Current.NativeWindowHandle);
        ActivateForInput(surface);
        alternate.SetFocus();
        if (!WaitUntil(delegate () { return TargetFocused(surface, alternate); }, 1200) || TargetFocused(surface, target))
            throw new InvalidOperationException("focus positive control did not start away from EDIT");
        target.SetFocus();
        if (!WaitUntil(delegate () { return TargetFocused(surface, target); }, 1200))
            throw new InvalidOperationException("SetFocus did not reach target EDIT");
        verifiedFocus.Add(hwnd);
        Console.WriteLine("[FOCUS] exact target=" + hwnd + " observed=" + FocusedHwnd(surface));
    }

    static string GateOne(string label, Action action, AutomationElement disabledTarget = null, bool focus = false)
    {
        try
        {
            action();
            return "returned-without-exception";
        }
        catch (Exception error)
        {
            // Missing/stale elements, patterns, transport errors and local bugs
            // are failures, not evidence of modal rejection.
            if (disabledTarget == null) throw;
            IntPtr hwnd = new IntPtr(disabledTarget.Current.NativeWindowHandle);
            uint pid;
            bool liveDisabled = hwnd != IntPtr.Zero && GetWindowThreadProcessId(hwnd, out pid) != 0 &&
                !disabledTarget.Current.IsEnabled;
            bool expected = error is ElementNotEnabledException ||
                (focus && error.GetType() == typeof(InvalidOperationException) && verifiedFocus.Contains(hwnd));
            if (!liveDisabled || !expected) throw;
            int hr = Marshal.GetHRForException(error);
            return "disabled-rejection " + error.GetType().Name + " hr=0x" + hr.ToString("X8");
        }
    }


    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr GetProp(IntPtr hwnd, string name);

    [DllImport("user32.dll")]
    static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);

    const uint FenceMessage = 0x8000 + 0x2A;
    static int nextFenceId = 1;

    static long FenceProp(IntPtr hwnd, string name) { return (long)GetProp(hwnd, name); }

    static bool WaitFence(IntPtr hwnd, int requestId, long beforeTurn, uint expectedPid)
    {
        var watch = Stopwatch.StartNew();
        while (watch.ElapsedMilliseconds < 4000)
        {
            uint pid;
            if (GetWindowThreadProcessId(hwnd, out pid) == 0 || pid != expectedPid) return false;
            // Data is written before the acknowledgement id, so a matching id
            // means the turn field read right after it belongs to this fence.
            if (FenceProp(hwnd, "leafFenceAck") == requestId + 1)
            {
                long ackTurn = FenceProp(hwnd, "leafFenceTurn");
                return ackTurn > beforeTurn &&
                    FenceProp(hwnd, "leafFenceAck") == requestId + 1;
            }
            Thread.Sleep(50);
        }
        return false;
    }
    static bool GateStep(string phase, string label, Action action, IntPtr topSurface,
        Func<bool> stateUnchanged, IntPtr fenceWindow, AutomationElement target)
    {
        uint fixturePid, topPid;
        if (GetWindowThreadProcessId(fenceWindow, out fixturePid) == 0 ||
            GetWindowThreadProcessId(topSurface, out topPid) == 0 || fixturePid != topPid)
            throw new InvalidOperationException("fence window identity mismatch");
        long beforeTurn = FenceProp(fenceWindow, "leafTurnSeq");
        if (beforeTurn <= 0) throw new InvalidOperationException("fixture has no safe-turn telemetry");
        int requestId = nextFenceId++;
        if (target == null) throw new InvalidOperationException("gate target missing");
        IntPtr targetHwnd = new IntPtr(target.Current.NativeWindowHandle);
        uint targetPid;
        if (GetWindowThreadProcessId(targetHwnd, out targetPid) == 0 || targetPid != fixturePid)
            throw new InvalidOperationException("gate target is not a live fixture control");
        string outcome = GateOne(label, action, target, label.EndsWith("SetFocus"));
        // Immediate observation: what the action did before any later turn.
        bool stateNow = stateUnchanged();
        bool focusNow = FocusInsideSurface(topSurface, FocusedHwnd(topSurface));
        // Ask the app for one ordinary safe turn and wait for its fence ack.
        bool fenced = PostMessage(fenceWindow, FenceMessage, (IntPtr)requestId, IntPtr.Zero)
            && WaitFence(fenceWindow, requestId, beforeTurn, fixturePid);
        bool stateAfter = fenced && stateUnchanged();
        bool focusAfter = fenced && FocusInsideSurface(topSurface, FocusedHwnd(topSurface));
        Console.WriteLine("[GATE] " + phase + " " + label + " -> " + outcome +
            " req=" + requestId + " beforeTurn=" + beforeTurn + " ackTurn=" + FenceProp(fenceWindow, "leafFenceTurn") + " fenced=" + fenced +
            " stateNow=" + stateNow + " stateAfter=" + stateAfter +
            " focusNow=" + focusNow + " focusAfter=" + focusAfter);
        return fenced && stateNow && stateAfter && focusNow && focusAfter;
    }
    static void GatedAttempt(string label, Action action)
    {
        try
        {
            action();
            Console.WriteLine("[GATE] " + label + " allowed");
        }
        catch (Exception error)
        {
            int hr = System.Runtime.InteropServices.Marshal.GetHRForException(error);
            Console.WriteLine("[GATE] " + label + " blocked " + error.GetType().Name +
                " hr=0x" + hr.ToString("X8"));
        }
    }

    static string TextByPrefix(AutomationElement root, string prefix)
    {
        var all = root.FindAll(TreeScope.Descendants, new PropertyCondition(
            AutomationElement.ControlTypeProperty, ControlType.Text));
        foreach (AutomationElement element in all)
        {
            string name = element.Current.Name;
            if (name != null && name.StartsWith(prefix)) return name;
        }
        return null;
    }
    static bool Gone(Func<AutomationElement> probe)
    {
        var watch = Stopwatch.StartNew();
        while (watch.ElapsedMilliseconds < 4000)
        {
            if (probe() == null) return true;
            Thread.Sleep(120);
        }
        return false;
    }

    static void Shot(string name, IntPtr hwnd)
    {
        RECT rect;
        if (!GetWindowRect(hwnd, out rect)) { Check(false, "window rect for " + name); return; }
        int width = rect.Right - rect.Left;
        int height = rect.Bottom - rect.Top;
        if (width <= 0 || height <= 0) { Check(false, "empty capture for " + name); return; }
        using (var bitmap = new Bitmap(width, height))
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.CopyFromScreen(rect.Left, rect.Top, 0, 0, new Size(width, height));
            bitmap.Save(Path.Combine(output, name + ".png"), ImageFormat.Png);
        }
        Console.WriteLine("[SHOT] " + name + ".png " + width + "x" + height);
    }

    static void Settle(int milliseconds = 450) { Thread.Sleep(milliseconds); }

    static void ShotStable(string name, IntPtr hwnd, AutomationElement element)
    {
        // Acceptance-client capture synchronisation only; not a product
        // first-frame-ready API. UIA discovery plus a bounded idle window makes
        // the capture representative of the natural settled state.
        RECT before;
        GetWindowRect(hwnd, out before);
        bool idle = false;
        try
        {
            object pattern;
            if (element != null &&
                element.TryGetCurrentPattern(WindowPattern.Pattern, out pattern))
            {
                idle = ((WindowPattern)pattern).WaitForInputIdle(2000);
            }
        }
        catch (Exception) { }
        Console.WriteLine("[READY] " + name + " inputIdle=" + idle);
        Settle(600);
        RECT after;
        GetWindowRect(hwnd, out after);
        Check(IsWindow(hwnd), "capture target is still a live window: " + name);
        Check(IsWindowVisible(hwnd), "capture target is still visible: " + name);
        Check(!element.Current.IsOffscreen, "capture target is on screen: " + name);
        Check(after.Left == before.Left && after.Top == before.Top &&
            (after.Right - after.Left) == (before.Right - before.Left) &&
            (after.Bottom - after.Top) == (before.Bottom - before.Top),
            "capture target geometry is stable before shooting: " + name);
        Shot(name, hwnd);
    }

    static AutomationElement FindSurface(int processId, string title)
    {
        AutomationElement found = null;
        EnumWindows(delegate (IntPtr window, IntPtr param)
        {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner != processId) return true;
            var cls = new System.Text.StringBuilder(256);
            GetClassName(window, cls, 256);
            if (!cls.ToString().StartsWith("LeafOverlaySurface")) return true;
            if (!IsWindowVisible(window)) return true;
            var text = new System.Text.StringBuilder(256);
            GetWindowText(window, text, 256);
            if (text.ToString() != title) return true;
            found = AutomationElement.FromHandle(window);
            return false;
        }, IntPtr.Zero);
        return found;
    }

    static int RunCold(string exe, string outputDir, string pidFile)
    {
        output = outputDir;
        var process = Process.Start(new ProcessStartInfo(exe) { UseShellExecute = false });
        File.WriteAllText(pidFile, process.Id.ToString());
        try
        {
            var main = WaitFor(() => WindowByName(AutomationElement.RootElement,
                process.Id, "Leaf — 模态对话框"), 20000, "main window");
            if (main == null) return 7;
            var mainHwnd = new IntPtr(main.Current.NativeWindowHandle);
            int windowGate = RequireWindowPerMonitorV2(mainHwnd, "page");
            if (windowGate != 0) return windowGate;
            SetWindowPos(mainHwnd, IntPtr.Zero, 40, 40, 520, 700, 0x0004 | 0x0010);
            ActivateForInput(mainHwnd);
            Settle(600);
            Invoke(ByName(main, TreeScope.Descendants, "打开对话框"), "打开对话框");
            var dialog = WaitFor(delegate () { return FindSurface(process.Id, "编辑联系人"); },
                6000, "outer dialog window");
            if (dialog == null) return 7;
            Invoke(ByName(dialog, TreeScope.Descendants, "打开内层对话框"), "inner trigger");
            var inner = WaitFor(delegate () { return FindSurface(process.Id, "内层对话框"); },
                6000, "inner dialog window");
            if (inner == null) return 7;
            var innerRect = new RECT();
            GetWindowRect(new IntPtr(inner.Current.NativeWindowHandle), out innerRect);
            Console.WriteLine("[TIMING] cold-inner-first at " + DateTime.Now.ToString("HH:mm:ss.fff") +
                " rect=" + innerRect.Left + "," + innerRect.Top + " " +
                (innerRect.Right - innerRect.Left) + "x" + (innerRect.Bottom - innerRect.Top));
            Shot("cold-inner-first", mainHwnd);
            Settle(500);
            Console.WriteLine("[TIMING] cold-inner-settled at " + DateTime.Now.ToString("HH:mm:ss.fff"));
            ShotStable("cold-inner-settled", mainHwnd, inner);
            Check(main.Current.IsEnabled == false, "page disabled in cold nesting run");
        }
        catch (Exception error)
        {
            Check(false, "cold run error: " + error);
        }
        finally
        {
            try { process.CloseMainWindow(); process.WaitForExit(5000); } catch (Exception) { }
            try { if (!process.HasExited) process.Kill(); } catch (Exception) { }
        }
        Console.WriteLine(failures == 0 ? "COLD OBSERVATIONS PASSED" : failures + " COLD FAILURES");
        return failures == 0 ? 0 : 7;
    }

    static int GateFailureContract()
    {
        int failures = 0;
        foreach (Exception error in new Exception[] {
            new NullReferenceException("local bug"), new ElementNotAvailableException(),
            new NotSupportedException("missing pattern"), new InvalidOperationException("not a disabled focus") })
        {
            bool rejected = false;
            try { GateOne("unexpected", delegate () { throw error; }); }
            catch (Exception) { rejected = true; }
            Console.WriteLine("unexpected " + error.GetType().Name + " rejected=" + rejected);
            if (!rejected) failures++;
        }
        return failures == 0 ? 0 : 1;
    }

    // Cursor input, Win32/UIA rectangles and captured screen pixels only describe
    // one space while this driver runs in the same PerMonitorV2 context as the
    // application, so the gate requires PMv2, prints what it actually got and
    // fails closed; there is no system-aware fallback.
    const int ExitDpiApiMissing = 21;
    const int ExitNotPerMonitorV2 = 22;
    const int ExitWindowDpiUnavailable = 23;
    static readonly IntPtr PerMonitorV2Context = new IntPtr(-4);

    static string DescribeDpiContext(IntPtr context)
    {
        if (context == IntPtr.Zero) return "none";
        if (AreDpiAwarenessContextsEqual(context, PerMonitorV2Context)) return "per_monitor_v2";
        // This API only separates unaware/system/per-monitor; the equality check
        // above is what distinguishes PMv1 from PMv2.
        switch (GetAwarenessFromDpiAwarenessContext(context))
        {
            case 0: return "unaware";
            case 1: return "system";
            case 2: return "per_monitor_v1";
            default: return "unknown";
        }
    }

    static int ReportMissingDpiApi()
    {
        Console.WriteLine("[DPI] unsupported: the user32 DPI awareness APIs are missing on this Windows");
        return ExitDpiApiMissing;
    }

    static int RequireProcessPerMonitorV2()
    {
        try
        {
            // false is expected when an embedded manifest already fixed the context,
            // so the effective context decides; anything but PMv2 is a hard failure.
            bool set = SetProcessDpiAwarenessContext(PerMonitorV2Context);
            IntPtr effective = GetThreadDpiAwarenessContext();
            Console.WriteLine("[DPI] setPerMonitorV2=" + set + " effective=" + DescribeDpiContext(effective));
            if (!AreDpiAwarenessContextsEqual(effective, PerMonitorV2Context)) return ExitNotPerMonitorV2;
            return 0;
        }
        catch (EntryPointNotFoundException) { return ReportMissingDpiApi(); }
        catch (DllNotFoundException) { return ReportMissingDpiApi(); }
    }

    static int RequireWindowPerMonitorV2(IntPtr window, string label)
    {
        IntPtr context;
        try { context = GetWindowDpiAwarenessContext(window); }
        catch (EntryPointNotFoundException) { return ReportMissingDpiApi(); }
        catch (DllNotFoundException) { return ReportMissingDpiApi(); }
        Console.WriteLine("[DPI] " + label + " window=" + DescribeDpiContext(context));
        return AreDpiAwarenessContextsEqual(context, PerMonitorV2Context) ? 0 : ExitNotPerMonitorV2;
    }

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

    public static int Main(string[] args)
    {
        if (args.Length == 1 && args[0] == "--dpi-contract") return DpiGateContract();
        int dpiGate = RequireProcessPerMonitorV2();
        if (dpiGate != 0) return dpiGate;
        if (args.Length == 1 && args[0] == "--gate-contract") return GateFailureContract();
        if (args.Length < 3) { Console.Error.WriteLine("usage: DialogClient <exe> <outDir> <pidFile> [cold]"); return 2; }
        if (args.Length > 3 && args[3] == "cold") return RunCold(args[0], args[1], args[2]);
        string exe = args[0];
        output = args[1];
        Directory.CreateDirectory(output);
        var process = Process.Start(new ProcessStartInfo(exe) { UseShellExecute = false });
        File.WriteAllText(args[2], process.Id.ToString());
        try
        {
            var main = WaitFor(() => WindowByName(AutomationElement.RootElement,
                process.Id, "Leaf — 模态对话框"), 20000, "main window");
            if (main == null) return 7;
            var mainHwnd = new IntPtr(main.Current.NativeWindowHandle);
            int windowGate = RequireWindowPerMonitorV2(mainHwnd, "page");
            if (windowGate != 0) return windowGate;
            ActivateForInput(mainHwnd);
            Settle(600);
            var openDialog = ByName(main, TreeScope.Descendants, "打开对话框");
            Check(openDialog != null, "page trigger is reachable by name");
            string dialogTitle = "编辑联系人";

            // --- UIA gating: positive control while no modal is open ----------
            var bgButton = ByName(main, TreeScope.Descendants, "打开危险确认");
            var bgEdit = main.FindFirst(TreeScope.Descendants, new PropertyCondition(
                AutomationElement.ControlTypeProperty, ControlType.Edit));
            Check(bgButton != null, "background action is present");
            Check(bgEdit != null, "background editor is present");
            var bgValue = (ValuePattern)bgEdit.GetCurrentPattern(ValuePattern.Pattern);
            string baseValue = bgValue.Current.Value;
            Console.WriteLine("[GATE] base value='" + baseValue + "'");
            string positiveInvoke = GateOne("positive Invoke", delegate () {
                ((InvokePattern)bgButton.GetCurrentPattern(InvokePattern.Pattern)).Invoke(); });
            var positiveAlert = WaitFor(delegate () { return FindSurface(process.Id, "删除联系人"); },
                5000, "alert after a non-modal Invoke");
            Console.WriteLine("[GATE] positive Invoke -> " + positiveInvoke + " alertOpened=" +
                (positiveAlert != null));
            Check(positiveAlert != null, "non-modal Invoke really runs its handler");
            if (positiveAlert != null)
                Invoke(ByName(positiveAlert, TreeScope.Descendants, "保留"), "alert cancel");
            Check(Gone(delegate () { return FindSurface(process.Id, "删除联系人"); }),
                "alert closed after cancel");
            string positiveValue = GateOne("positive SetValue", delegate () { bgValue.SetValue("TopOK"); });
            Check(WaitUntil(delegate () { return bgValue.Current.Value == "TopOK"; }, 1200),
                "non-modal SetValue applies");
            ActivateForInput(mainHwnd);
            openDialog.SetFocus();
            Check(WaitUntil(delegate () { return FocusedHwnd(mainHwnd) == new IntPtr(openDialog.Current.NativeWindowHandle); }, 1200), "focus starts on a different control");
            Check(!TargetFocused(mainHwnd, bgEdit), "a different page control is not the target EDIT");
            string positiveFocus = GateOne("positive SetFocus", delegate () { bgEdit.SetFocus(); });
            bool positiveFocusInside = WaitUntil(delegate () {
                return TargetFocused(mainHwnd, bgEdit); }, 1500);
            Console.WriteLine("[GATE] positive focus -> " + positiveFocus + " insidePage=" +
                positiveFocusInside);
            Check(positiveFocusInside, "non-modal SetFocus moves native focus inside the page");
            if (positiveFocusInside) verifiedFocus.Add(new IntPtr(bgEdit.Current.NativeWindowHandle));
            // --- light Dialog -------------------------------------------------
            Invoke(openDialog, "打开对话框");
            Thread.Sleep(1200);
            var tops = AutomationElement.RootElement.FindAll(TreeScope.Children,
                new PropertyCondition(AutomationElement.ProcessIdProperty, process.Id));
            DumpProcessWindows(process.Id);
            Console.WriteLine("[TOPS] count=" + tops.Count);
            foreach (AutomationElement element in tops)
                Console.WriteLine("[TOP] " + element.Current.ControlType.ProgrammaticName +
                    " name='" + element.Current.Name + "' class='" + element.Current.ClassName +
                    "' enabled=" + element.Current.IsEnabled + " hwnd=" + element.Current.NativeWindowHandle);
            var dialog = WaitFor(delegate () { return FindSurface(process.Id, dialogTitle); },
                6000, "dialog window");
            if (dialog == null) return 7;
            var dialogHwnd = new IntPtr(dialog.Current.NativeWindowHandle);
            Check(dialogHwnd != mainHwnd, "dialog is a separate top-level window");
            Check(main.Current.IsEnabled == false, "page window is disabled while the modal is open");
            Check(dialog.Current.IsEnabled, "dialog window is enabled");
            Check(GetAncestor(dialogHwnd, 2) == dialogHwnd,
                "dialog HWND is a root window, not a clipped child of the page");
            Check(IsWindowEnabled(dialogHwnd), "dialog HWND is enabled");
            // Required modal semantics: a real Window control type with a
            // WindowPattern, and IsModal tracking the real disabled owner.
            // A missing pattern is a failure, never a "false observation".
            Check(dialog.Current.ControlType == ControlType.Window,
                "dialog control type is Window");
            object patternObject;
            Check(dialog.TryGetCurrentPattern(WindowPattern.Pattern, out patternObject),
                "dialog exposes WindowPattern");
            bool modal = false;
            if (patternObject != null)
            {
                var window = (WindowPattern)patternObject;
                modal = window.Current.IsModal;
                Check(!window.Current.IsTopmost, "dialog is not topmost");
                Check(!window.Current.CanMaximize, "dialog is not resizable/maximizable");
            }
            Check(modal, "IsModal is true while the owning window is disabled");
            // --- UIA gating: background actions under the real modal -----------
            string modalCounters = TextByPrefix(main, "已保存");
            Func<bool> backgroundUnchanged = delegate () {
                return TextByPrefix(main, "已保存") == modalCounters &&
                    FindSurface(process.Id, "删除联系人") == null; };
            foreach (Exception injected in new Exception[] {
                new NullReferenceException("action bug"), new ElementNotAvailableException(),
                new NotSupportedException("missing pattern"), new InvalidOperationException("unexpected Value failure") })
            {
                bool rejected = false;
                try {
                    GateStep("negative", "background SetValue", delegate () { throw injected; },
                        dialogHwnd, backgroundUnchanged, mainHwnd, bgEdit);
                } catch (Exception actual) { rejected = Object.ReferenceEquals(actual, injected); }
                Check(rejected, "GateStep rejects unexpected " + injected.GetType().Name + " on a live disabled target");
            }
            bool gateInvoke = GateStep("modal", "background Invoke", delegate () {
                ((InvokePattern)bgButton.GetCurrentPattern(InvokePattern.Pattern)).Invoke();
            }, dialogHwnd, backgroundUnchanged, mainHwnd, bgButton);
            bool gateValue = GateStep("modal", "background SetValue", delegate () {
                bgValue.SetValue("Blocked");
            }, dialogHwnd, delegate () {
                return bgValue.Current.Value == "TopOK" &&
                    FindSurface(process.Id, "删除联系人") == null; }, mainHwnd, bgEdit);
            bool gateFocus = GateStep("modal", "background SetFocus", delegate () {
                bgEdit.SetFocus();
            }, dialogHwnd, backgroundUnchanged, mainHwnd, bgEdit);
            Check(gateInvoke, "gated Invoke has no effect and keeps native focus inside the modal");
            Check(gateValue, "gated SetValue does not change the background editor");
            Check(gateFocus, "gated SetFocus keeps native focus inside the modal");
            Check(dialog.Current.NativeWindowHandle == dialogHwnd.ToInt32(),
                "the top surface identity is unchanged by the gated actions");

            var edit = dialog.FindFirst(TreeScope.Descendants, new PropertyCondition(
                AutomationElement.ControlTypeProperty, ControlType.Edit));
            Check(edit != null, "dialog exposes its native editor");
            if (edit != null)
            {
                var value = (ValuePattern)edit.GetCurrentPattern(ValuePattern.Pattern);
                value.SetValue("Grace Hopper");
                Settle();
                Check(value.Current.Value == "Grace Hopper", "native editor keeps the typed value");
                Shot("dialog-light-edited", dialogHwnd);
            }
            // Dynamic title: the surface window name must follow the render.
            Invoke(ByName(dialog, TreeScope.Descendants, "重命名标题"), "rename title");
            var renamed = WaitFor(delegate ()
            {
                return FindSurface(process.Id, "编辑联系人（已重命名）");
            }, 4000, "renamed dialog surface");
            Check(renamed != null, "surface name follows the rendered title");
            if (renamed != null)
            {
                Check(renamed.Current.ControlType == ControlType.Window,
                    "renamed surface keeps the Window control type");
                dialog = renamed;
                dialogTitle = "编辑联系人（已重命名）";
            }
            Invoke(ByName(dialog, TreeScope.Descendants, "关闭"), "dialog close control");
            Check(Gone(delegate () { return FindSurface(process.Id, dialogTitle); }),
                "dismiss request closed the accepted level");
            Check(main.Current.IsEnabled, "page window is enabled again after the close");
            Check(IsWindowEnabled(mainHwnd), "native page window is enabled again");
            // --- UIA gating: same elements usable again after the close --------
            string recoveredValue = GateOne("recovered SetValue", delegate () { bgValue.SetValue("AfterClose"); });
            Check(WaitUntil(delegate () { return bgValue.Current.Value == "AfterClose"; }, 1200),
                "background editor accepts input after the close");
            FocusPositive(mainHwnd, bgEdit, openDialog);
            string recoveredFocus = GateOne("recovered SetFocus", delegate () { bgEdit.SetFocus(); });
            bool recoveredInside = WaitUntil(delegate () {
                return TargetFocused(mainHwnd, bgEdit); }, 1500);
            Console.WriteLine("[GATE] recovered -> " + recoveredValue + " / " + recoveredFocus +
                " insidePage=" + recoveredInside);
            Check(recoveredInside, "background focus works again after the close");

            // --- AlertDialog: WindowPattern and IsModal -----------------------
            var positiveAlertAgain = GateOne("alert Invoke", delegate () {
                ((InvokePattern)bgButton.GetCurrentPattern(InvokePattern.Pattern)).Invoke(); });
            var alertSurface = WaitFor(delegate () { return FindSurface(process.Id, "删除联系人"); },
                5000, "alert surface");
            Check(alertSurface != null, "alert is a real surface window");
            if (alertSurface != null)
            {
                object alertPattern;
                Check(alertSurface.TryGetCurrentPattern(WindowPattern.Pattern, out alertPattern),
                    "alert exposes WindowPattern");
                bool alertModal = alertPattern != null &&
                    ((WindowPattern)alertPattern).Current.IsModal;
                Console.WriteLine("[GATE] alert modal=" + alertModal + " invoke=" + positiveAlertAgain);
                Check(alertModal, "alert IsModal is true while its owner is disabled");
                Invoke(ByName(alertSurface, TreeScope.Descendants, "保留"), "alert cancel");
                Check(Gone(delegate () { return FindSurface(process.Id, "删除联系人"); }),
                    "alert cancel closes only the alert");
                Check(main.Current.IsEnabled, "page is enabled again after the alert");
            }
            // --- dark theme --------------------------------------------------
            Invoke(ByName(main, TreeScope.Descendants, "切换浅色/深色"), "theme toggle");
            Settle(700);
            Invoke(ByName(main, TreeScope.Descendants, "打开对话框"), "打开");
            var darkDialog = WaitFor(delegate () { return FindSurface(process.Id, dialogTitle); },
                6000, "dark dialog window");
            if (darkDialog != null)
            {
                Shot("dialog-dark-page", mainHwnd);
                Shot("dialog-dark-surface", new IntPtr(darkDialog.Current.NativeWindowHandle));
                Invoke(ByName(darkDialog, TreeScope.Descendants, "关闭"), "dark close control");
                Check(Gone(delegate () { return FindSurface(process.Id, dialogTitle); }),
                    "dark level closed by its own control");
            }

            // --- narrow window ----------------------------------------------
            SetWindowPos(mainHwnd, IntPtr.Zero, 40, 40, 520, 700, 0x0004 | 0x0010);
            Settle(600);
            Invoke(ByName(main, TreeScope.Descendants, "打开对话框"), "打开");
            var narrow = WaitFor(delegate () { return FindSurface(process.Id, dialogTitle); },
                6000, "narrow dialog window");
            if (narrow != null)
            {
                Shot("dialog-narrow-page", mainHwnd);
                RECT dialogRect, pageRect;
                GetWindowRect(new IntPtr(narrow.Current.NativeWindowHandle), out dialogRect);
                GetWindowRect(mainHwnd, out pageRect);
                Check(dialogRect.Left >= pageRect.Left - 8 && dialogRect.Right <= pageRect.Right + 8,
                    "narrow dialog stays within the owning window");
                // Nesting: open the inner level from the outer dialog.
                var currentOuterEdit = narrow.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit));
                var currentOuterButton = ByName(narrow, TreeScope.Descendants, "打开内层对话框");
                FocusPositive(new IntPtr(narrow.Current.NativeWindowHandle), currentOuterEdit, currentOuterButton);
                Invoke(ByName(narrow, TreeScope.Descendants, "打开内层对话框"), "inner trigger");
                var inner = WaitFor(delegate () { return FindSurface(process.Id, "内层对话框"); },
                    6000, "inner dialog window");
                if (inner != null)
                {
                    Check(new IntPtr(inner.Current.NativeWindowHandle) !=
                        new IntPtr(narrow.Current.NativeWindowHandle), "inner level is its own window");
                    Check(narrow.Current.IsEnabled == false, "outer level is disabled by the inner modal");
                    Check(main.Current.IsEnabled == false, "page stays disabled while nested levels are open");
                    Check(inner.Current.ControlType == ControlType.Window,
                        "inner level control type is Window");
                    object innerPattern;
                    Check(inner.TryGetCurrentPattern(WindowPattern.Pattern, out innerPattern),
                        "inner level exposes WindowPattern");
                    if (innerPattern != null)
                    {
                        Check(((WindowPattern)innerPattern).Current.IsModal,
                            "inner level IsModal is true");
                // --- UIA gating: the outer level is gated too -----------------
                var outerSurfaceNow = FindSurface(process.Id, dialogTitle);
                Check(outerSurfaceNow != null, "outer surface is still discoverable");
                var outerButton = outerSurfaceNow == null ? null :
                    ByName(outerSurfaceNow, TreeScope.Descendants, "保存");
                var outerEdit = outerSurfaceNow == null ? null : outerSurfaceNow.FindFirst(
                    TreeScope.Descendants, new PropertyCondition(
                    AutomationElement.ControlTypeProperty, ControlType.Edit));
                Check(outerButton != null, "outer save action exists while the inner level is top");
                Check(outerEdit != null, "outer editor exists while the inner level is top");
                IntPtr innerTopHwnd = new IntPtr(inner.Current.NativeWindowHandle);
                string outerTextBefore = outerEdit == null ? "" :
                    ((ValuePattern)outerEdit.GetCurrentPattern(ValuePattern.Pattern)).Current.Value;
                string outerCounters = TextByPrefix(main, "已保存");
                Func<bool> outerUnchanged = delegate () {
                    var again = FindSurface(process.Id, dialogTitle);
                    if (again == null || outerEdit == null) return false;
                    if (TextByPrefix(main, "已保存") != outerCounters) return false;
                    return ((ValuePattern)outerEdit.GetCurrentPattern(ValuePattern.Pattern)).Current.Value == outerTextBefore; };
                bool gateOuterInvoke = GateStep("inner", "outer Invoke", delegate () {
                    ((InvokePattern)outerButton.GetCurrentPattern(InvokePattern.Pattern)).Invoke();
                }, innerTopHwnd, outerUnchanged, mainHwnd, outerButton);
                bool gateOuterFocus = GateStep("inner", "outer SetFocus", delegate () {
                    outerEdit.SetFocus(); }, innerTopHwnd, outerUnchanged, mainHwnd, outerEdit);
                bool gateOuterValue = GateStep("inner", "outer SetValue", delegate () {
                    ((ValuePattern)outerEdit.GetCurrentPattern(ValuePattern.Pattern)).SetValue("OuterBlocked");
                }, innerTopHwnd, outerUnchanged, mainHwnd, outerEdit);
                Check(gateOuterInvoke, "outer Invoke is gated while the inner level is top");
                Check(gateOuterFocus, "outer focus stays gated while the inner level is top");
                Check(gateOuterValue, "outer editor cannot be edited while the inner level is top");

                    }
                    Check(narrow.Current.IsEnabled == false,
                        "outer level is disabled while the inner modal is open");
                    // Real hit test across processes: every point inside the inner
                    // surface must resolve to the inner level's own window tree,
                    // never to the outer level underneath it.
                    var innerHwnd = new IntPtr(inner.Current.NativeWindowHandle);
                    RECT innerRect;
                    GetWindowRect(innerHwnd, out innerRect);
                    int inside = 0, own = 0;
                    for (int gx = 1; gx <= 3; gx++)
                    {
                        for (int gy = 1; gy <= 3; gy++)
                        {
                            var probe = new POINT();
                            probe.X = innerRect.Left + (innerRect.Right - innerRect.Left) * gx / 4;
                            probe.Y = innerRect.Top + (innerRect.Bottom - innerRect.Top) * gy / 4;
                            var hit = WindowFromPoint(probe);
                            inside++;
                            while (hit != IntPtr.Zero && hit != innerHwnd) hit = GetParent(hit);
                            if (hit == innerHwnd) own++;
                        }
                    }
                    Check(inside == own, "every sampled point inside the inner surface belongs to it (" +
                        own + "/" + inside + ")");
                    Check(GetWindow(innerHwnd, 2) != IntPtr.Zero,
                        "inner surface has a window below it in z-order");
                    Check(GetParent(innerHwnd) == new IntPtr(narrow.Current.NativeWindowHandle),
                        "inner surface is owned by the outer surface");
                    // Capture timing evidence: the frame right after the HWND is
                    // discoverable, then the same window after a bounded idle
                    // window. No forced repaint of any kind.
                    Console.WriteLine("[TIMING] inner-first at " + DateTime.Now.ToString("HH:mm:ss.fff") +
                        " rect=" + innerRect.Left + "," + innerRect.Top + " " +
                        (innerRect.Right - innerRect.Left) + "x" + (innerRect.Bottom - innerRect.Top));
                    Shot("seq-inner-first", mainHwnd);
                    Settle(500);
                    Console.WriteLine("[TIMING] inner-settled at " + DateTime.Now.ToString("HH:mm:ss.fff"));
                    ShotStable("seq-inner-settled", mainHwnd, inner);
                    ShotStable("dialog-nested-page", mainHwnd, inner);
                    Invoke(ByName(inner, TreeScope.Descendants, "关闭内层"), "inner close control");
                    Check(Gone(delegate () { return FindSurface(process.Id, "内层对话框"); }),
                        "inner level closed");
                    Settle();
                    Check(narrow.Current.IsEnabled, "outer level is enabled again");
                    FocusPositive(new IntPtr(narrow.Current.NativeWindowHandle), currentOuterEdit, currentOuterButton);
                    var recoveredOuterValue = (ValuePattern)currentOuterEdit.GetCurrentPattern(ValuePattern.Pattern);
                    recoveredOuterValue.SetValue("OuterAfterClose");
                    Check(WaitUntil(delegate () { return recoveredOuterValue.Current.Value == "OuterAfterClose"; }, 1200), "same outer EDIT Value works after inner close");
                    Check(main.Current.IsEnabled == false, "page is not re-enabled with the outer level open");
                }
                Invoke(ByName(narrow, TreeScope.Descendants, "关闭"), "outer close control");
                Check(Gone(delegate () { return FindSurface(process.Id, dialogTitle); }),
                    "outer level closed");
                Check(main.Current.IsEnabled, "page enabled after both levels closed");
            }

            // --- AlertDialog -------------------------------------------------
            Invoke(ByName(main, TreeScope.Descendants, "打开危险确认"), "打开危险确认");
            var alert = WaitFor(delegate () { return FindSurface(process.Id, "删除联系人"); },
                6000, "alert dialog window");
            if (alert != null)
            {
                var alertHwnd = new IntPtr(alert.Current.NativeWindowHandle);
                Shot("alert-page", mainHwnd);
                Shot("alert-surface", alertHwnd);
                var cancel = ByName(alert, TreeScope.Descendants, "保留");
                Check(cancel != null, "alert dialog exposes its cancel control");
                var focused = AutomationElement.FocusedElement;
                Check(focused != null && focused.Current.Name == "保留",
                    "alert dialog focuses the safe cancel control");
                Invoke(cancel, "保留");
                Check(Gone(delegate () { return FindSurface(process.Id, "删除联系人"); }),
                    "alert dialog closed by its cancel control");
                Check(main.Current.IsEnabled, "page enabled after the alert dialog closed");
            }
        }
        catch (Exception error)
        {
            Check(false, "unhandled client error: " + error);
        }
        finally
        {
            try { process.CloseMainWindow(); process.WaitForExit(5000); }
            catch (Exception) { }
            try { if (!process.HasExited) process.Kill(); } catch (Exception) { }
        }
        Console.WriteLine(failures == 0 ? "ALL OBSERVATIONS PASSED" : failures + " OBSERVATIONS FAILED");
        return failures == 0 ? 0 : 7;
    }
}
