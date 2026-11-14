using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Automation;

// Strict natural-discovery acceptance entry point.
//
// Each case runs in a fresh process against a fresh application instance and its
// FIRST subtree operation is the one under test: A = FindFirst, B = subtree
// handlers then FindFirst, C = TreeWalker. No case pre-connects the Select by
// HWND or by reading a pattern first. A missing/unresponsive/timeout result is a
// non-zero exit; the N case is a deliberate negative control that must fail.
static class DiscoveryClient
{
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr wp, IntPtr lp,
        uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr data);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    delegate bool EnumProc(IntPtr hwnd, IntPtr data);

    const uint WmClose = 0x0010;
    const string ExpectedSelectName = "颜色: 选择一个颜色";
    const string StockButtonName = "打开含下拉的对话框";
    const string MissingSelectName = "不存在的选择器";

    static readonly List<string> failures = new List<string>();
    static readonly List<string> steps = new List<string>();
    static string caseName = "A-sta";
    static IntPtr appWindow = IntPtr.Zero;
    static Process app;
    static string outputPath;
    static bool negativeControlOk;

    static void Log(string text)
    {
        Console.WriteLine("[" + DateTime.Now.ToString("HH:mm:ss.fff") + "] " + text);
        Console.Out.Flush();
    }
    static void Fail(string message)
    {
        failures.Add(message);
        Log("[FAILED] " + message);
    }
    static void Ok(string message) { Log("[OK] " + message); }
    static bool Responsive(IntPtr hwnd)
    {
        IntPtr result;
        return SendMessageTimeout(hwnd, 0, IntPtr.Zero, IntPtr.Zero, 0x0002, 1500, out result) != IntPtr.Zero;
    }
    static string Name(AutomationElement e)
    {
        try { return e.Current.Name; } catch { return "?"; }
    }
    static string TypeName(AutomationElement e)
    {
        try { return e.Current.ControlType.ProgrammaticName; } catch { return "?"; }
    }
    static bool TryPattern(AutomationElement e, AutomationPattern pattern, out object value)
    {
        value = null;
        try { return e.TryGetCurrentPattern(pattern, out value); }
        catch { return false; }
    }

    // A watchdog enforces the deadline and turns a hung COM call into a bounded,
    // recorded failure instead of a client that never returns.
    static bool Step(string name, Action body, int deadlineMs)
    {
        var watch = Stopwatch.StartNew();
        var fired = false;
        var watchdog = new Thread(delegate ()
        {
            Thread.Sleep(deadlineMs);
            fired = true;
            Log("[FAILED] step-timeout " + name + " deadlineMs=" + deadlineMs);
            failures.Add("step-timeout:" + name);
            Flush();
            Environment.Exit(5);
        });
        watchdog.IsBackground = true;
        watchdog.Start();
        try { body(); }
        catch (Exception error)
        {
            Fail(name + " exception=" + error.GetType().Name + ": " + error.Message);
            return false;
        }
        finally { watchdog.Abort(); }
        if (fired) return false;
        steps.Add(name + "=" + watch.ElapsedMilliseconds + "ms");
        Log("[STEP] " + name + " " + watch.ElapsedMilliseconds + "ms");
        return true;
    }

    static void Flush()
    {
        try
        {
            var lines = new List<string>();
            lines.Add("case=" + caseName);
            lines.Add("apartment=" + Thread.CurrentThread.GetApartmentState());
            lines.Add("appPid=" + (app != null ? app.Id.ToString() : "-"));
            lines.Add("appExe=" + (app != null ? app.StartInfo.FileName : "-"));
            lines.Add("failures=" + string.Join(" | ", failures.ToArray()));
            lines.AddRange(steps);
            if (negativeControlOk) lines.Add("NEGATIVE CONTROL OK");
            lines.Add(failures.Count == 0 ? "DISCOVERY PASSED" : "DISCOVERY FAILED");
            File.WriteAllLines(outputPath, lines.ToArray(), new UTF8Encoding(false));
        }
        catch { }
    }

    static AutomationElement WaitAppRoot(int pid, int deadlineMs)
    {
        var watch = Stopwatch.StartNew();
        while (watch.ElapsedMilliseconds < deadlineMs)
        {
            foreach (AutomationElement element in AutomationElement.RootElement.FindAll(
                TreeScope.Children, new PropertyCondition(
                    AutomationElement.ControlTypeProperty, ControlType.Window)))
            {
                try { if (element.Current.ProcessId == pid) return element; }
                catch { }
            }
            Thread.Sleep(150);
        }
        return null;
    }

    // Bounded retry around a single UIA search: a transient empty result right
    // after a structure change is recorded with its attempt count instead of
    // being mistaken for a missing control.
    static AutomationElement FindWithWait(AutomationElement root, Condition condition,
        string label, int deadlineMs)
    {
        var watch = Stopwatch.StartNew();
        int attempts = 0;
        while (watch.ElapsedMilliseconds < deadlineMs)
        {
            attempts++;
            AutomationElement found = null;
            try { found = root.FindFirst(TreeScope.Descendants, condition); }
            catch (Exception error) { Fail(label + " search exception=" + error.GetType().Name); return null; }
            Log("[TRY] " + label + " attempt=" + attempts + " elapsed=" + watch.ElapsedMilliseconds +
                "ms result=" + (found != null ? "found" : "empty"));
            if (found != null)
            {
                steps.Add(label + "Attempts=" + attempts);
                return found;
            }
            Thread.Sleep(250);
        }
        steps.Add(label + "Attempts=" + attempts);
        return null;
    }

    static AutomationElement FindStockButton(AutomationElement root)
    {
        var condition = new AndCondition(
            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button),
            new PropertyCondition(AutomationElement.NameProperty, StockButtonName));
        return FindWithWait(root, condition, "stockButton", 8000);
    }

    static void CheckTriggerSemantics(AutomationElement trigger)
    {
        Ok("found Select: " + Name(trigger) + " type=" + TypeName(trigger));
        if (Name(trigger) != ExpectedSelectName) Fail("Select name mismatch: " + Name(trigger));
        object expand, value;
        if (!TryPattern(trigger, ExpandCollapsePattern.Pattern, out expand)) Fail("trigger has no ExpandCollapsePattern");
        if (!TryPattern(trigger, ValuePattern.Pattern, out value)) Fail("trigger has no ValuePattern");
        try { if (!trigger.Current.IsEnabled) Fail("trigger reports IsEnabled=false"); } catch { Fail("trigger IsEnabled unreadable"); }
    }

    static void CheckPopupReachable(AutomationElement trigger)
    {
        object expand;
        if (!TryPattern(trigger, ExpandCollapsePattern.Pattern, out expand)) return;
        Step("expand", delegate () { ((ExpandCollapsePattern)expand).Expand(); }, 15000);
        AutomationElement list = null;
        Step("popup-subtree-list", delegate ()
        {
            list = trigger.FindFirst(TreeScope.Subtree,
                new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.List));
        }, 15000);
        if (list == null) { Fail("popup List is not reachable through the trigger subtree"); return; }
        Ok("popup reachable naturally: " + Name(list) + " handle=" + list.Current.NativeWindowHandle.ToString("X"));
        var items = list.FindAll(TreeScope.Children,
            new PropertyCondition(AutomationElement.IsControlElementProperty, true));
        if (items.Count < 6) Fail("popup lists " + items.Count + " items, expected 6");
        bool disabled = false;
        foreach (AutomationElement item in items)
            try { if (!item.Current.IsEnabled) disabled = true; } catch { }
        if (!disabled) Fail("no disabled candidate reported by UIA");
        Step("collapse", delegate () { ((ExpandCollapsePattern)expand).Collapse(); }, 15000);
    }

    static void CheckDialogSelectReachable(AutomationElement root)
    {
        var button = FindStockButton(root);
        if (button == null) { Fail("stock positive control not found naturally"); return; }
        Ok("stock positive control found: " + Name(button));
        object invoke;
        if (!TryPattern(button, InvokePattern.Pattern, out invoke)) { Fail("stock button has no InvokePattern"); return; }
        Step("open-dialog", delegate () { ((InvokePattern)invoke).Invoke(); }, 15000);
        Thread.Sleep(700);
        AutomationElement inner = null;
        Step("dialog-select-find", delegate ()
        {
            var watch = Stopwatch.StartNew();
            while (watch.ElapsedMilliseconds < 15000 && inner == null)
            {
                var all = root.FindAll(TreeScope.Descendants,
                    new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.ComboBox));
                foreach (AutomationElement element in all)
                    if (Name(element).StartsWith("内层颜色")) { inner = element; break; }
                if (inner == null) Thread.Sleep(250);
            }
        }, 20000);
        if (inner == null) Fail("dialog select is not reachable naturally");
        else Ok("dialog select reachable naturally: " + Name(inner));
    }

    static int Main(string[] args)
    {
        outputPath = args.Length > 0 ? args[0] : "discovery.json";
        string appPath = args.Length > 1 ? args[1] : "";
        caseName = args.Length > 2 ? args[2] : "A-sta";
        bool sta = caseName.IndexOf("sta", StringComparison.Ordinal) >= 0;
        int code = 5;
        var thread = new Thread(delegate () { code = Run(appPath); });
        thread.SetApartmentState(sta ? ApartmentState.STA : ApartmentState.MTA);
        thread.Start();
        thread.Join();
        return code;
    }

    static int Run(string appPath)
    {
        Log("case=" + caseName + " apartment=" + Thread.CurrentThread.GetApartmentState());
        try
        {
            app = Process.Start(new ProcessStartInfo(appPath) { UseShellExecute = false });
            Log("appPid=" + app.Id + " appExe=" + appPath);
            var root = WaitAppRoot(app.Id, 15000);
            if (root == null) { Fail("app window not found within 15s"); return 3; }
            appWindow = new IntPtr(root.Current.NativeWindowHandle);
            Ok("app root=" + root.Current.Name + " hwnd=" + appWindow.ToString("X"));

            if (caseName.StartsWith("N"))
            {
                AutomationElement missing = null;
                Step("negative-findfirst", delegate ()
                {
                    missing = FindWithWait(root, new AndCondition(
                        new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.ComboBox),
                        new PropertyCondition(AutomationElement.NameProperty, MissingSelectName)),
                        "missingSelect", 4000);
                }, 20000);
                if (missing == null)
                {
                    Ok("negative control: nonexistent Select is not found (expected)");
                    negativeControlOk = true;
                    Log("NEGATIVE CONTROL OK");
                    // A negative control must not report success: the runner
                    // asserts this non-zero exit as evidence that a missing
                    // requirement fails the gate.
                    return 7;
                }
                Fail("negative control found an element that must not exist");
                return 6;
            }

            if (caseName.StartsWith("C"))
            {
                AutomationElement found = null;
                bool stockSeen = false;
                Step("treewalker", delegate ()
                {
                    var queue = new Queue<Tuple<AutomationElement, int>>();
                    queue.Enqueue(Tuple.Create(root, 0));
                    int visited = 0;
                    while (queue.Count > 0 && visited < 400)
                    {
                        var item = queue.Dequeue();
                        visited++;
                        string type = TypeName(item.Item1);
                        string name = Name(item.Item1);
                        if (type == "ControlType.ComboBox" && name == ExpectedSelectName) found = item.Item1;
                        if (type == "ControlType.Button" && name == StockButtonName) stockSeen = true;
                        if (item.Item2 >= 8) continue;
                        var child = TreeWalker.ControlViewWalker.GetFirstChild(item.Item1);
                        int siblings = 0;
                        while (child != null && siblings < 60)
                        {
                            queue.Enqueue(Tuple.Create(child, item.Item2 + 1));
                            siblings++;
                            child = TreeWalker.ControlViewWalker.GetNextSibling(child);
                        }
                    }
                    steps.Add("treewalkerVisited=" + visited);
                }, 60000);
                if (found == null) Fail("TreeWalker did not find the Select");
                else Ok("TreeWalker found the Select: " + Name(found));
                if (stockSeen) Ok("TreeWalker also saw the stock positive control");
                else Fail("TreeWalker did not see the stock positive control");
                if (found != null) CheckTriggerSemantics(found);
            }
            else
            {
                if (caseName.StartsWith("B"))
                {
                    StructureChangedEventHandler structure = delegate (object o, StructureChangedEventArgs e) { };
                    AutomationPropertyChangedEventHandler property = delegate (object o, AutomationPropertyChangedEventArgs e) { };
                    bool structureOk = false, propertyOk = false;
                    Step("register-structure-subtree", delegate ()
                    {
                        Automation.AddStructureChangedEventHandler(root, TreeScope.Subtree, structure);
                        structureOk = true;
                    }, 20000);
                    Step("register-property-subtree", delegate ()
                    {
                        Automation.AddAutomationPropertyChangedEventHandler(root, TreeScope.Subtree, property,
                            ExpandCollapsePattern.ExpandCollapseStateProperty);
                        propertyOk = true;
                    }, 20000);
                    if (!structureOk) Fail("subtree structure handler registration failed");
                    if (!propertyOk) Fail("subtree property handler registration failed");
                    AutomationElement found = null;
                    Step("findfirst-after-handlers", delegate ()
                    {
                        found = FindWithWait(root,
                            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.ComboBox),
                            "selectAfterHandlers", 15000);
                    }, 20000);
                    if (found == null) Fail("FindFirst after handlers did not find the Select");
                    else CheckTriggerSemantics(found);
                    // Handlers stay registered until the queries above are done,
                    // then are removed on this same apartment thread.
                    try { Automation.RemoveStructureChangedEventHandler(root, structure); }
                    catch (Exception error) { Fail("remove structure handler: " + error.GetType().Name); }
                    try
                    {
                        Automation.RemoveAutomationPropertyChangedEventHandler(root, property);
                    }
                    catch (Exception error) { Fail("remove property handler: " + error.GetType().Name); }
                }
                else
                {
                    AutomationElement found = null;
                    Step("findfirst", delegate ()
                    {
                        found = FindWithWait(root,
                            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.ComboBox),
                            "select", 15000);
                    }, 20000);
                    if (found == null) Fail("FindFirst did not find the Select");
                    else
                    {
                        CheckTriggerSemantics(found);
                        CheckPopupReachable(found);
                        CheckDialogSelectReachable(root);
                    }
                }
            }

            if (!Responsive(appWindow)) Fail("app is not responding after the case");
            else Ok("app responsive");
            return failures.Count == 0 ? 0 : 4;
        }
        catch (Exception error)
        {
            Fail("exception=" + error.GetType().Name + ": " + error.Message);
            return 4;
        }
        finally
        {
            Flush();
            try
            {
                if (app != null && !app.HasExited)
                {
                    app.CloseMainWindow();
                    if (!app.WaitForExit(4000))
                    {
                        Log("graceful close timed out, terminating owned pid " + app.Id);
                        app.Kill();
                        app.WaitForExit(4000);
                    }
                }
                Log("appExited=" + (app == null || app.HasExited));
            }
            catch (Exception error) { Log("cleanup error=" + error.GetType().Name); }
        }
    }
}
