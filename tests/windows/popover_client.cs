// Cross-process UI Automation acceptance for the native non-modal Popover.
//
// The client launches examples/ui_controls/popover.nim, discovers everything
// through the natural UIA tree that starts at the application's own window, and
// drives it only with patterns (Invoke/Value). It asserts: the panel is a real
// owned top-level window that is not topmost, IsModal=false, the owner stays
// enabled, the content exposes stock EDIT/Text/Button, closing and re-opening
// keeps the accepted draft, theme switch and a narrow owner keep the panel on
// screen, and a panel inside the modal dialog stays in that dialog's scope.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Automation;
using System.Windows.Forms;

public class PopoverClient
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern IntPtr GetThreadDpiAwarenessContext();
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern IntPtr GetWindowDpiAwarenessContext(IntPtr window);
    [DllImport("user32.dll")] static extern bool AreDpiAwarenessContextsEqual(IntPtr a, IntPtr b);
    [DllImport("user32.dll")] static extern int GetAwarenessFromDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out RECT rect);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr window, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    static extern IntPtr GetWindowLongPtr(IntPtr window, int index);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr window, IntPtr after,
        int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetWindowText(IntPtr window, System.Text.StringBuilder text, int length);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetClassName(IntPtr window, System.Text.StringBuilder text, int length);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr param);
    delegate bool EnumProc(IntPtr window, IntPtr param);

    const uint GW_OWNER = 4;
    const uint GA_ROOT = 2;
    const int GWL_EXSTYLE = -20;
    const int WS_EX_TOPMOST = 0x00000008;
    const uint SWP_NOZORDER = 0x0004;
    const uint SWP_NOACTIVATE = 0x0010;

    static int failures;
    static string output;

    static void Check(bool ok, string what)
    {
        Console.WriteLine((ok ? "[OK] " : "[FAILED] ") + what);
        if (!ok) failures++;
    }

    static void Note(string what) { Console.WriteLine("[NOTE] " + what); }

    static void Settle(int milliseconds) { Thread.Sleep(milliseconds); }

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

    static AutomationElement WindowByName(int processId, string name)
    {
        var condition = new AndCondition(
            new PropertyCondition(AutomationElement.ProcessIdProperty, processId),
            new PropertyCondition(AutomationElement.NameProperty, name),
            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Window));
        return AutomationElement.RootElement.FindFirst(TreeScope.Descendants, condition);
    }

    static AutomationElement ButtonByName(AutomationElement root, string name)
    {
        if (root == null) return null;
        var condition = new AndCondition(
            new PropertyCondition(AutomationElement.NameProperty, name),
            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button));
        return root.FindFirst(TreeScope.Descendants, condition);
    }

    static AutomationElement FirstOfType(AutomationElement root, ControlType type)
    {
        if (root == null) return null;
        return root.FindFirst(TreeScope.Descendants,
            new PropertyCondition(AutomationElement.ControlTypeProperty, type));
    }

    static AutomationElement TextStartingWith(AutomationElement root, string prefix)
    {
        if (root == null) return null;
        var all = root.FindAll(TreeScope.Descendants,
            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Text));
        foreach (AutomationElement element in all)
        {
            string name = element.Current.Name;
            if (name != null && name.StartsWith(prefix)) return element;
        }
        return null;
    }

    static void Invoke(AutomationElement element, string what)
    {
        if (element == null) { Check(false, "missing control " + what); return; }
        try
        {
            ((InvokePattern)element.GetCurrentPattern(InvokePattern.Pattern)).Invoke();
            Note("invoked " + what);
        }
        catch (Exception error)
        {
            Check(false, "invoke " + what + " failed: " + error.GetType().Name);
        }
    }

    static bool IsDescendantOf(AutomationElement element, AutomationElement ancestor)
    {
        if (element == null || ancestor == null) return false;
        var walker = TreeWalker.ControlViewWalker;
        var current = walker.GetParent(element);
        for (int depth = 0; current != null && depth < 32; depth++)
        {
            if (Automation.Compare(current, ancestor)) return true;
            current = walker.GetParent(current);
        }
        return false;
    }

    static AutomationElement ButtonOutside(AutomationElement root, AutomationElement excluded, string name)
    {
        if (root == null) return null;
        var condition = new PropertyCondition(AutomationElement.NameProperty, name);
        var all = root.FindAll(TreeScope.Descendants, condition);
        foreach (AutomationElement element in all)
        {
            if (element.Current.ControlType != ControlType.Button) continue;
            if (excluded != null && IsDescendantOf(element, excluded)) continue;
            return element;
        }
        return null;
    }

    // Locate the panel through the natural tree first (app/dialog element
    // subtree) and only then through the process-scoped roots; the location is
    // reported so "descendant of the app element" is never assumed.
    static AutomationElement LocatePanel(int processId, AutomationElement scope, string name,
        out string location)
    {
        location = "none";
        if (scope != null)
        {
            var condition = new AndCondition(
                new PropertyCondition(AutomationElement.NameProperty, name),
                new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Window));
            var inside = scope.FindFirst(TreeScope.Descendants, condition);
            if (inside != null) { location = "scope-subtree"; return inside; }
        }
        var found = WindowByName(processId, name);
        if (found != null) location = "process-roots";
        return found;
    }

    static void Activate(IntPtr window, string what)
    {
        // Pattern-driven acceptance does not need real keyboard or mouse focus,
        // so a refused foreground activation is recorded as an environment
        // observation instead of a product failure.
        bool requested = SetForegroundWindow(window);
        int error = Marshal.GetLastWin32Error();
        bool foreground = WaitUntil(delegate { return GetForegroundWindow() == window; }, 2000);
        Console.WriteLine("[FOREGROUND] " + what + " requested=" + requested +
            " lastError=" + error + " verified=" + foreground +
            " foregroundHwnd=" + GetForegroundWindow().ToInt64());
    }

    static void DumpWindows(int processId)
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
                IsWindowVisible(window) + " owner=" + GetWindow(window, GW_OWNER).ToInt64() +
                " root=" + GetAncestor(window, GA_ROOT).ToInt64() +
                " hwnd=" + window.ToInt64());
            return true;
        }, IntPtr.Zero);
    }

    static RECT UnionRect(List<IntPtr> windows)
    {
        var union = new RECT();
        bool first = true;
        foreach (IntPtr window in windows)
        {
            RECT rect;
            if (!IsWindow(window) || !GetWindowRect(window, out rect)) continue;
            if (first)
            {
                union = rect; first = false; continue;
            }
            union.Left = Math.Min(union.Left, rect.Left);
            union.Top = Math.Min(union.Top, rect.Top);
            union.Right = Math.Max(union.Right, rect.Right);
            union.Bottom = Math.Max(union.Bottom, rect.Bottom);
        }
        return union;
    }

    static void ShotUnion(string name, params IntPtr[] windows)
    {
        RECT rect = UnionRect(new List<IntPtr>(windows));
        int width = rect.Right - rect.Left;
        int height = rect.Bottom - rect.Top;
        if (width <= 0 || height <= 0) { Check(false, "empty capture for " + name); return; }
        using (var bitmap = new Bitmap(width, height))
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.CopyFromScreen(rect.Left, rect.Top, 0, 0, new Size(width, height));
            string path = Path.Combine(output, name + ".png");
            bitmap.Save(path, ImageFormat.Png);
            Console.WriteLine("[SHOT] " + path + " " + width + "x" + height);
        }
    }

    static void ShotStable(string name, AutomationElement element, AutomationElement panel, IntPtr hwnd)
    {
        // Capture synchronisation only: bounded idle wait + geometry stability,
        // never a product "first frame ready" claim.
        RECT before;
        GetWindowRect(hwnd, out before);
        bool idle = false;
        try
        {
            object pattern;
            if (element != null && element.TryGetCurrentPattern(WindowPattern.Pattern, out pattern))
                idle = ((WindowPattern)pattern).WaitForInputIdle(2000);
        }
        catch (Exception) { }
        Settle(600);
        RECT after;
        GetWindowRect(hwnd, out after);
        Console.WriteLine("[READY] " + name + " inputIdle=" + idle);
        Check(IsWindow(hwnd) && IsWindowVisible(hwnd), "capture target stays live and visible: " + name);
        Check(after.Left == before.Left && after.Top == before.Top &&
            (after.Right - after.Left) == (before.Right - before.Left),
            "capture target geometry is stable: " + name);
        if (panel != null)
        {
            var panelHwnd = new IntPtr(panel.Current.NativeWindowHandle);
            ShotUnion(name, hwnd, panelHwnd);
        }
        else ShotUnion(name, hwnd);
    }

    static string ValueOf(AutomationElement edit)
    {
        try { return ((ValuePattern)edit.GetCurrentPattern(ValuePattern.Pattern)).Current.Value; }
        catch (Exception) { return null; }
    }

    static void SetValue(AutomationElement edit, string text, string what)
    {
        if (edit == null) { Check(false, "missing edit for " + what); return; }
        try
        {
            ((ValuePattern)edit.GetCurrentPattern(ValuePattern.Pattern)).SetValue(text);
            Note("set " + what + " to '" + text + "'");
        }
        catch (Exception error)
        {
            Check(false, "SetValue " + what + " failed: " + error.GetType().Name);
        }
    }

    static bool PanelWindowPattern(AutomationElement panel, out bool modal)
    {
        modal = true;
        object pattern;
        if (!panel.TryGetCurrentPattern(WindowPattern.Pattern, out pattern)) return false;
        modal = ((WindowPattern)pattern).Current.IsModal;
        return true;
    }

    static void CheckPanelIdentity(string label, int processId, AutomationElement panel,
        AutomationElement scope, IntPtr scopeHwnd, string name)
    {
        string location = "none";
        var located = LocatePanel(processId, scope, name, out location);
        Check(located != null && Automation.Compare(located, panel),
            label + ": panel is discoverable through the natural tree (" + location + ")");
        // Discovery must start at the application's own element, never at the
        // desktop roots or a directly queried HWND.
        Check(location == "scope-subtree",
            label + ": panel was found as a descendant of its owner's element");
        var panelHwnd = new IntPtr(panel.Current.NativeWindowHandle);
        Check(panel.Current.ControlType == ControlType.Window, label + ": panel is a Window control");
        Check(panel.Current.IsEnabled, label + ": panel is enabled");
        Check(!panel.Current.IsOffscreen, label + ": panel is on screen");
        Check(IsWindowVisible(panelHwnd), label + ": panel HWND is visible");
        Check(GetAncestor(panelHwnd, GA_ROOT) == panelHwnd,
            label + ": panel is a top-level window, not a clipped child");
        Check(GetWindow(panelHwnd, GW_OWNER) == scopeHwnd,
            label + ": panel is owned by its scope window");
        Check((GetWindowLongPtr(panelHwnd, GWL_EXSTYLE).ToInt64() & WS_EX_TOPMOST) == 0,
            label + ": panel is not globally topmost");
        bool modal;
        Check(PanelWindowPattern(panel, out modal) && !modal,
            label + ": WindowPattern.IsModal is false (non-modal)");
        Check(IsWindowEnabled(scopeHwnd), label + ": owner window stays enabled");
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
        if (args.Length < 3)
        {
            Console.Error.WriteLine("usage: PopoverClient <exe> <outDir> <pidFile>");
            return 2;
        }
        string exe = args[0];
        output = args[1];
        Directory.CreateDirectory(output);
        var process = Process.Start(new ProcessStartInfo(exe) { UseShellExecute = false });
        File.WriteAllText(args[2], process.Id.ToString());
        try
        {
            var main = WaitFor(delegate { return WindowByName(process.Id, "Leaf — 浮层 Popover"); },
                25000, "main window");
            if (main == null) return 7;
            var mainHwnd = new IntPtr(main.Current.NativeWindowHandle);
            int windowGate = RequireWindowPerMonitorV2(mainHwnd, "page");
            if (windowGate != 0) return windowGate;
            Activate(mainHwnd, "page");
            Settle(800);
            DumpWindows(process.Id);

            // ---- page popover: natural discovery + non-modal semantics ------
            var trigger = ButtonByName(main, "筛选");
            Check(trigger != null, "page trigger is reachable by name from the app subtree");
            if (trigger == null) return 7;
            Check(trigger.Current.IsEnabled && trigger.Current.IsKeyboardFocusable,
                "page trigger is enabled and keyboard focusable");
            Invoke(trigger, "page trigger");
            string location = "none";
            var panel = WaitFor(delegate
            {
                return LocatePanel(process.Id, main, "筛选面板", out location);
            }, 8000, "page popover panel");
            if (panel == null) return 7;
            Console.WriteLine("[FOUND] page panel location=" + location);
            var panelHwnd = new IntPtr(panel.Current.NativeWindowHandle);
            CheckPanelIdentity("page panel", process.Id, panel, main, mainHwnd, "筛选面板");
            Check(panelHwnd != mainHwnd, "page panel has its own HWND");

            // ---- stock content controls inside the panel --------------------
            var edit = FirstOfType(panel, ControlType.Edit);
            Check(edit != null, "panel content exposes a stock EDIT");
            Check(TextStartingWith(panel, "名称筛选") != null, "panel content exposes the label text");
            var close = ButtonByName(panel, "应用并关闭");
            Check(close != null, "panel content exposes the close button");
            SetValue(edit, "abc123", "panel edit");
            Check(WaitUntil(delegate { return ValueOf(edit) == "abc123"; }, 1500),
                "panel EDIT reports the typed value");
            ShotStable("popover-light-open", panel, panel, mainHwnd);

            // ---- close, owner stays alive, accepted draft survives ----------
            Invoke(close, "panel close");
            // Documented contract: an accepted close HIDES the owned panel and
            // keeps its live body children; the window is destroyed only when
            // the host retires.
            Check(WaitUntil(delegate { return !IsWindowVisible(panelHwnd); }, 5000),
                "panel hides after the accepted close request");
            Check(IsWindow(panelHwnd), "panel window is kept for a later open (hide, not destroy)");
            Check(IsWindowVisible(mainHwnd) && IsWindowEnabled(mainHwnd),
                "page window is untouched by the panel close");
            Invoke(trigger, "page trigger again");
            var reopened = WaitFor(delegate
            {
                return LocatePanel(process.Id, main, "筛选面板", out location);
            }, 8000, "re-opened panel");
            if (reopened == null) return 7;
            var reopenedHwnd = new IntPtr(reopened.Current.NativeWindowHandle);
            var reopenedEdit = FirstOfType(reopened, ControlType.Edit);
            Check(reopenedEdit != null && ValueOf(reopenedEdit) == "abc123",
                "accepted draft is shown after close and re-open");

            // ---- dark theme keeps the panel and its content -----------------
            var theme = ButtonByName(main, "深色");
            Check(theme != null, "theme switch is reachable");
            Invoke(theme, "dark theme");
            Settle(1200);
            ShotStable("popover-dark-open", reopened, reopened, mainHwnd);
            ShotUnion("popover-dark-owner", mainHwnd, reopenedHwnd);
            Invoke(ButtonByName(reopened, "应用并关闭"), "close after dark");
            Check(WaitUntil(delegate { return !IsWindowVisible(reopenedHwnd); }, 5000),
                "panel hides under the dark theme");
            Invoke(ButtonByName(main, "浅色"), "light theme");
            Settle(1000);

            // ---- narrow owner: the panel still fits the work area -----------
            SetWindowPos(mainHwnd, IntPtr.Zero, 40, 40, 420, 700, SWP_NOZORDER | SWP_NOACTIVATE);
            Settle(900);
            Activate(mainHwnd, "narrow page");
            var narrowTrigger = ButtonByName(main, "筛选");
            Invoke(narrowTrigger, "narrow trigger");
            var narrow = WaitFor(delegate
            {
                return LocatePanel(process.Id, main, "筛选面板", out location);
            }, 8000, "panel in a narrow owner");
            if (narrow == null) return 7;
            var narrowHwnd = new IntPtr(narrow.Current.NativeWindowHandle);
            RECT narrowRect;
            GetWindowRect(narrowHwnd, out narrowRect);
            var work = Screen.FromHandle(mainHwnd).WorkingArea;
            Check(narrowRect.Left >= work.Left && narrowRect.Top >= work.Top &&
                narrowRect.Right <= work.Right && narrowRect.Bottom <= work.Bottom,
                "narrow-owner panel stays inside the monitor work area");
            Check((narrowRect.Right - narrowRect.Left) > 0 && (narrowRect.Bottom - narrowRect.Top) > 0,
                "narrow-owner panel has a real size");
            ShotStable("popover-narrow-open", narrow, narrow, mainHwnd);
            Invoke(ButtonByName(narrow, "应用并关闭"), "close narrow panel");
            Check(WaitUntil(delegate { return !IsWindowVisible(narrowHwnd); }, 5000),
                "narrow-owner panel hides");
            SetWindowPos(mainHwnd, IntPtr.Zero, 40, 40, 620, 760, SWP_NOZORDER | SWP_NOACTIVATE);
            Settle(800);

            // ---- modal dialog scope: the inner panel belongs to the dialog --
            Activate(mainHwnd, "page before dialog");
            var openDialog = ButtonByName(main, "打开对话框");
            Check(openDialog != null, "dialog trigger is reachable");
            Invoke(openDialog, "open dialog");
            var dialog = WaitFor(delegate { return WindowByName(process.Id, "浮层中的表单"); },
                8000, "modal dialog");
            if (dialog == null) return 7;
            var dialogHwnd = new IntPtr(dialog.Current.NativeWindowHandle);
            bool dialogModal;
            Check(PanelWindowPattern(dialog, out dialogModal) && dialogModal,
                "dialog is modal while the popover panel is not");
            Check(main.Current.IsEnabled == false, "page window is disabled while the dialog is open");
            var inner = WaitFor(delegate
            {
                return LocatePanel(process.Id, dialog, "更多选项面板", out location);
            }, 8000, "dialog-hosted panel");
            if (inner == null) return 7;
            Console.WriteLine("[FOUND] dialog panel location=" + location);
            var innerHwnd = new IntPtr(inner.Current.NativeWindowHandle);
            CheckPanelIdentity("dialog panel", process.Id, inner, dialog, dialogHwnd, "更多选项面板");
            Check(GetWindow(innerHwnd, GW_OWNER) == dialogHwnd,
                "dialog panel is owned by the dialog, not by the page");
            Check(FirstOfType(inner, ControlType.Edit) != null,
                "dialog panel exposes its own stock EDIT");
            ShotStable("popover-in-dialog", dialog, inner, dialogHwnd);
            ShotUnion("popover-in-dialog-context", mainHwnd, dialogHwnd, innerHwnd);

            // ---- close the dialog: both the panel and the dialog retire -----
            var dialogClose = ButtonOutside(dialog, inner, "关闭");
            Check(dialogClose != null, "dialog footer close button is reachable outside the panel");
            Invoke(dialogClose, "dialog close");
            Check(WaitUntil(delegate { return !IsWindowVisible(dialogHwnd); }, 6000),
                "dialog window hides on its accepted close request");
            Check(WaitUntil(delegate { return !IsWindowVisible(innerHwnd); }, 6000),
                "dialog-hosted panel hides together with its owner");
            Check(WaitUntil(delegate { return main.Current.IsEnabled; }, 4000),
                "page window is enabled again after the dialog closes");
        }
        catch (Exception error)
        {
            Check(false, "client error: " + error);
        }
        finally
        {
            try { process.CloseMainWindow(); process.WaitForExit(5000); } catch (Exception) { }
            try { if (!process.HasExited) process.Kill(); } catch (Exception) { }
        }
        Console.WriteLine(failures == 0 ? "POPOVER OBSERVATIONS PASSED"
            : failures + " POPOVER FAILURES");
        return failures == 0 ? 0 : 7;
    }
}
