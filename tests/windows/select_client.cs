using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Automation;

static class SelectClient
{
    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)]
    struct GUITHREADINFO
    {
        public int cbSize;
        public uint flags;
        public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
        public RECT rcCaret;
    }

    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern void mouse_event(uint flags, int dx, int dy, uint data, IntPtr extra);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int index);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc proc, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr data);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint thread, ref GUITHREADINFO info);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr h);
    delegate bool EnumProc(IntPtr hwnd, IntPtr data);

    const int GwOwner = 4;
    const int GwlExStyle = -20;
    const int ExTopmost = 0x00000008;
    const uint MouseLeftDown = 0x0002, MouseLeftUp = 0x0004;
    const uint WmClose = 0x0010;
    const uint KeyUp = 0x0002;
    const byte VkDown = 0x28, VkReturn = 0x0D, VkEscape = 0x1B, VkEnd = 0x23;

    static readonly List<string> report = new List<string>();
    static readonly List<string> failures = new List<string>();
    static string output;
    static int passed;

    static void Check(bool ok, string name)
    {
        if (ok) { passed++; report.Add("[OK] " + name); }
        else { failures.Add(name); report.Add("[FAILED] " + name); }
        Console.WriteLine(report[report.Count - 1]);
        Console.Out.Flush();
    }
    static void Note(string text)
    {
        report.Add(text);
        Console.WriteLine(text);
        Console.Out.Flush();
    }
    static void Settle(int ms = 400) { Thread.Sleep(ms); }
    // Natural discovery step: plain FindFirst on the application root, logged
    // before it runs and repeated for a bounded time.
    static AutomationElement FindWithWait(AutomationElement root, Condition condition,
        string label, int deadlineMs)
    {
        var watch = Stopwatch.StartNew();
        int attempts = 0;
        Note("[STEP] " + label);
        while (watch.ElapsedMilliseconds < deadlineMs)
        {
            attempts++;
            AutomationElement found = null;
            try { found = root.FindFirst(TreeScope.Descendants, condition); }
            catch (Exception error) { Note("search error " + label + " " + error.GetType().Name); return null; }
            if (found != null)
            {
                Note("[STEP] " + label + " found attempts=" + attempts + " elapsed=" + watch.ElapsedMilliseconds + "ms");
                return found;
            }
            Thread.Sleep(250);
        }
        Note("[STEP] " + label + " notfound attempts=" + attempts);
        return null;
    }

    static bool WaitFor(Func<bool> condition, int milliseconds = 3000)
    {
        var watch = Stopwatch.StartNew();
        while (watch.ElapsedMilliseconds < milliseconds)
        {
            if (condition()) return true;
            Thread.Sleep(100);
        }
        return condition();
    }

    // A controlled rejection must surface the UIA error the contract specifies.
    // Timeouts, disconnects and unrelated exceptions are failures, not success.
    static bool RejectedAs(Exception error, string label, int expectedHResult, Type expectedType)
    {
        if (error == null) { Note("[REJECT] " + label + " missing exception"); return false; }
        int hr = error.HResult;
        Note("[REJECT] " + label + " type=" + error.GetType().FullName + " hr=0x" + hr.ToString("X8"));
        if (error is ElementNotAvailableException) { Note("[REJECT] " + label + " element died"); return false; }
        if (hr == unchecked((int)0x80131505)) { Note("[REJECT] " + label + " timeout"); return false; }
        if (hr == unchecked((int)0x80010108) || hr == unchecked((int)0x800706BA)) { Note("[REJECT] " + label + " rpc disconnected"); return false; }
        return (expectedType != null && expectedType.IsAssignableFrom(error.GetType())) || hr == expectedHResult;
    }

    static bool ElementGone(AutomationElement element)
    {
        // Any property access on a retired provider must surface
        // ElementNotAvailable; a live element keeps answering.
        try { string ignored = element.Current.Name; return false; }
        catch (ElementNotAvailableException) { return true; }
        catch (Exception) { return false; }
    }

    static string WindowText(IntPtr h)
    {
        var sb = new StringBuilder(512);
        GetWindowText(h, sb, sb.Capacity);
        return sb.ToString();
    }
    static string ClassOf(IntPtr h)
    {
        var sb = new StringBuilder(256);
        GetClassName(h, sb, sb.Capacity);
        return sb.ToString();
    }
    static Point Centre(IntPtr h)
    {
        RECT r; GetWindowRect(h, out r);
        return new Point((r.Left + r.Right) / 2, (r.Top + r.Bottom) / 2);
    }
    static IntPtr FocusOf(IntPtr window)
    {
        uint pid; uint thread = GetWindowThreadProcessId(window, out pid);
        var info = new GUITHREADINFO();
        info.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
        if (!GetGUIThreadInfo(thread, ref info)) return IntPtr.Zero;
        return info.hwndFocus;
    }
    static void Click(IntPtr h)
    {
        Point p = Centre(h);
        SetCursorPos(p.X, p.Y);
        mouse_event(MouseLeftDown, 0, 0, 0, IntPtr.Zero);
        mouse_event(MouseLeftUp, 0, 0, 0, IntPtr.Zero);
    }
    static void Tap(byte vk)
    {
        keybd_event(vk, 0, 0, IntPtr.Zero);
        keybd_event(vk, 0, KeyUp, IntPtr.Zero);
    }
    static List<IntPtr> Children(IntPtr parent)
    {
        var found = new List<IntPtr>();
        EnumChildWindows(parent, delegate (IntPtr h, IntPtr d) { found.Add(h); return true; }, IntPtr.Zero);
        return found;
    }
    static IntPtr FindChildText(IntPtr parent, string text)
    {
        foreach (var h in Children(parent))
            if (WindowText(h) == text && IsWindowVisible(h)) return h;
        return IntPtr.Zero;
    }
    static List<IntPtr> OwnedPopups(IntPtr owner)
    {
        var found = new List<IntPtr>();
        EnumWindows(delegate (IntPtr h, IntPtr d)
        {
            if (GetWindow(h, (uint)GwOwner) == owner && ClassOf(h).StartsWith("LeafSelectPopup") &&
                IsWindowVisible(h)) found.Add(h);
            return true;
        }, IntPtr.Zero);
        return found;
    }
    static IntPtr FindPopup(IntPtr owner, string expectedName = null)
    {
        foreach (IntPtr candidate in OwnedPopups(owner))
        {
            if (expectedName == null) return candidate;
            try
            {
                if (NameOf(AutomationElement.FromHandle(candidate)) == expectedName) return candidate;
            }
            catch (Exception) { }
        }
        return IntPtr.Zero;
    }
    static IntPtr FindOwnedCaption(IntPtr owner, string caption)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate (IntPtr h, IntPtr d)
        {
            if (GetWindow(h, (uint)GwOwner) == owner && IsWindowVisible(h) && WindowText(h) == caption)
                found = h;
            return true;
        }, IntPtr.Zero);
        return found;
    }
    static void Shot(string name, IntPtr hwnd)
    {
        RECT r; GetWindowRect(hwnd, out r);
        int width = r.Right - r.Left, height = r.Bottom - r.Top;
        if (width <= 0 || height <= 0) { Check(false, "capture rect " + name); return; }
        using (var bitmap = new Bitmap(width, height))
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.CopyFromScreen(r.Left, r.Top, 0, 0, new Size(width, height));
            bitmap.Save(Path.Combine(output, name + ".png"), ImageFormat.Png);
        }
        Note("[SHOT] " + name + ".png " + width + "x" + height);
    }

    static string TypeName(AutomationElement e)
    {
        try { return e.Current.ControlType.ProgrammaticName; } catch { return "?"; }
    }
    static string NameOf(AutomationElement e)
    {
        try { return e.Current.Name; } catch { return "?"; }
    }
    static bool TryPattern(AutomationElement e, AutomationPattern pattern, out object value)
    {
        value = null;
        try { return e.TryGetCurrentPattern(pattern, out value); }
        catch (ElementNotAvailableException) { throw; }
        catch { return false; }
    }
    static AutomationElement ItemAt(AutomationElement list, int index)
    {
        var items = list.FindAll(TreeScope.Children,
            new PropertyCondition(AutomationElement.IsControlElementProperty, true));
        if (index < 0 || index >= items.Count) return null;
        return items[index];
    }
    static AutomationElement ItemNamed(AutomationElement list, string name)
    {
        var items = list.FindAll(TreeScope.Children,
            new PropertyCondition(AutomationElement.IsControlElementProperty, true));
        foreach (AutomationElement item in items) if (NameOf(item) == name) return item;
        return null;
    }
    static string[] ItemNames(AutomationElement list)
    {
        var items = list.FindAll(TreeScope.Children,
            new PropertyCondition(AutomationElement.IsControlElementProperty, true));
        var names = new string[items.Count];
        for (int i = 0; i < items.Count; i++) names[i] = NameOf(items[i]);
        return names;
    }
    static bool SelectedOnly(AutomationElement list, string name)
    {
        var items = list.FindAll(TreeScope.Children,
            new PropertyCondition(AutomationElement.IsControlElementProperty, true));
        bool sawTarget = false;
        foreach (AutomationElement item in items)
        {
            object pattern;
            bool selected = false;
            if (item.TryGetCurrentPattern(SelectionItemPattern.Pattern, out pattern))
                selected = ((SelectionItemPattern)pattern).Current.IsSelected;
            if (selected && NameOf(item) != name) return false;
            if (selected && NameOf(item) == name) sawTarget = true;
        }
        return sawTarget;
    }
    static bool IsSelected(AutomationElement item)
    {
        object pattern;
        return item.TryGetCurrentPattern(SelectionItemPattern.Pattern, out pattern) &&
            ((SelectionItemPattern)pattern).Current.IsSelected;
    }

    static int Main(string[] args)
    {
        output = args.Length > 0 ? args[0] : ".";
        string appPath = args.Length > 1 ? args[1] : "";
        string pidFile = args.Length > 2 ? args[2] : null;
        Directory.CreateDirectory(output);
        var process = Process.Start(new ProcessStartInfo(appPath) { UseShellExecute = false });
        if (pidFile != null) File.WriteAllText(pidFile, process.Id.ToString());
        AutomationElement[] held = new AutomationElement[4];
        int structureEvents = 0, expandEvents = 0, selectionEvents = 0;
        StructureChangedEventHandler structureHandler = delegate (object s, StructureChangedEventArgs e) { Interlocked.Increment(ref structureEvents); };
        AutomationPropertyChangedEventHandler propertyHandler = delegate (object s, AutomationPropertyChangedEventArgs e) { Interlocked.Increment(ref expandEvents); };
        AutomationEventHandler selectionHandler = delegate (object s, AutomationEventArgs e) { Interlocked.Increment(ref selectionEvents); };
        AutomationElement app = null;
        IntPtr appWindow = IntPtr.Zero;
        AutomationElement trigger = null;
        AutomationElement list = null;
        try
        {
            var watch = Stopwatch.StartNew();
            while (watch.ElapsedMilliseconds < 15000 && app == null)
            {
                foreach (AutomationElement element in AutomationElement.RootElement.FindAll(
                    TreeScope.Children, new PropertyCondition(
                        AutomationElement.ControlTypeProperty, ControlType.Window)))
                {
                    try { if (element.Current.ProcessId == process.Id) { app = element; break; } }
                    catch { }
                }
                if (app == null) Thread.Sleep(150);
            }
            if (app == null) { Note("error=app window not found"); return 2; }
            appWindow = new IntPtr(app.Current.NativeWindowHandle);
            SetForegroundWindow(appWindow);
            Settle(600);
            Note("app=" + app.Current.Name + " hwnd=" + appWindow.ToString("X"));

            // ---- trigger semantics -------------------------------------------------
            // Mandatory natural entry: the Select is discovered from the
            // application root by its UIA identity. The HWND is used afterwards
            // only as an identity cross-check.
            trigger = FindWithWait(app, new AndCondition(
                new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.ComboBox),
                new PropertyCondition(AutomationElement.NameProperty, "颜色: 选择一个颜色")),
                "natural-page-select", 15000);
            Check(trigger != null, "page Select discovered naturally from the app root");
            IntPtr triggerWindow = trigger != null
                ? new IntPtr(trigger.Current.NativeWindowHandle) : IntPtr.Zero;
            Check(triggerWindow != IntPtr.Zero && WindowText(triggerWindow) == "选择一个颜色",
                "HWND cross-check matches the naturally discovered element");
            if (trigger == null) { Note("error=no trigger"); return 2; }
            Check(NameOf(trigger) == "颜色: 选择一个颜色",
                "trigger element exposes the composed accessible name");
            held[0] = trigger;
            // Listen on the element itself: no subtree walk while registering.
            Note("[STEP] register event handlers");
            // Subtree: the structure event is about the trigger's children
            // (the popup list), which Element scope would filter out.
            Automation.AddStructureChangedEventHandler(trigger, TreeScope.Subtree, structureHandler);
            Automation.AddAutomationPropertyChangedEventHandler(trigger, TreeScope.Element,
                propertyHandler, ExpandCollapsePattern.ExpandCollapseStateProperty);
            Note("[STEP] handlers registered");
            Note("trigger=" + TypeName(trigger) + ";name=" + NameOf(trigger));
            Check(TypeName(trigger) == "ControlType.ComboBox", "trigger exposes ControlType.ComboBox");
            Check(trigger.Current.IsKeyboardFocusable, "trigger is keyboard focusable");
            Check(trigger.Current.IsEnabled, "enabled trigger reports IsEnabled");
            object expandPattern = null, valuePattern = null, selectionPattern = null;
            Check(TryPattern(trigger, ExpandCollapsePattern.Pattern, out expandPattern),
                "trigger exposes ExpandCollapsePattern");
            Check(TryPattern(trigger, ValuePattern.Pattern, out valuePattern),
                "trigger exposes ValuePattern");
            Check(!TryPattern(trigger, SelectionPattern.Pattern, out selectionPattern),
                "trigger does not fake a Selection pattern");
            if (valuePattern != null)
            {
                var value = (ValuePattern)valuePattern;
                Check(value.Current.IsReadOnly, "value pattern is read-only");
                Check(value.Current.Value == "", "value is empty while no option is accepted");
                bool setFailed = false;
                Exception setError = null;
                try { value.SetValue("hacked"); } catch (Exception error) { setFailed = true; setError = error; }
                // The client-side Value pattern refuses because IsReadOnly is
                // true (documented UIA behavior); the provider itself also
                // refuses SetValue with UIA_E_NOTSUPPORTED (covered separately).
                Check(setFailed && RejectedAs(setError, "SetValue", unchecked((int)0x80131509), typeof(InvalidOperationException)),
                    "SetValue on the read-only value is refused with the UIA invalid-operation error");
                Check(value.Current.Value == "", "refused SetValue kept the accepted value");
            }
            if (expandPattern == null || valuePattern == null)
            {
                // Stop before dereferencing the missing patterns: the recorded
                // failures above are the whole RED contract for this run.
                Note("[MISSING] expand/value patterns are required by the select contract");
                report.Add("passed=" + passed + " failed=" + failures.Count);
                report.Add("OBSERVATIONS FAILED");
                File.WriteAllLines(Path.Combine(output, "select-client.log"), report.ToArray(), new UTF8Encoding(false));
                foreach (var line in report) Console.WriteLine(line);
                return 3;
            }
            var expand = (ExpandCollapsePattern)expandPattern;
            Check(expand.Current.ExpandCollapseState == ExpandCollapseState.Collapsed,
                "collapsed state reported before opening");

            // ---- expand/collapse through UIA --------------------------------------
            expandEvents = 0;
            structureEvents = 0;
            expand.Expand();
            Settle(500);
            Note("[STEP] natural-popup-list");
            AutomationElement listElement = null;
            try
            {
                listElement = trigger.FindFirst(TreeScope.Subtree,
                    new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.List));
            }
            catch (Exception error) { Note("popup subtree search error " + error.GetType().Name); }
            Check(listElement != null, "popup List discovered naturally through the trigger subtree");
            IntPtr popup = listElement != null
                ? new IntPtr(listElement.Current.NativeWindowHandle) : FindPopup(appWindow);
            Check(popup != IntPtr.Zero && popup == FindPopup(appWindow),
                "Expand() published exactly the naturally discovered popup window");
            Check(expand.Current.ExpandCollapseState == ExpandCollapseState.Expanded,
                "expanded state reported after Expand()");
            Check(WaitFor(delegate () { return Volatile.Read(ref expandEvents) >= 1; }),
                "expand state change raised a UIA property event");
            Check(WaitFor(delegate () { return Volatile.Read(ref structureEvents) >= 1; }),
                "popup publication raised a structure event");
            if (popup != IntPtr.Zero) Shot("select-popup-light", popup);
            list = listElement;
            Check(list != null, "popup element is reachable as a real UIA element");
            if (list == null) { Note("error=no list element"); return 2; }
            Note("list=" + TypeName(list) + ";name=" + NameOf(list));
            // Real selection events must be registered for the accepted-value
            // changes; a rejection must not produce one.
            try
            {
                Automation.AddAutomationEventHandler(SelectionItemPattern.ElementSelectedEvent, list,
                    TreeScope.Subtree, selectionHandler);
                Automation.AddAutomationEventHandler(SelectionPattern.InvalidatedEvent, list,
                    TreeScope.Subtree, selectionHandler);
                Note("[STEP] selection events registered");
            }
            catch (Exception error) { Check(false, "selection event registration failed: " + error.GetType().Name); }
            Check(TypeName(list) == "ControlType.List", "popup exposes ControlType.List");
            Check(NameOf(list) == "颜色", "popup list carries the select name");
            var names = ItemNames(list);
            Check(names.Length == 6, "popup lists all six candidates");
            Check(names.Length == 6 && names[0] == "红色" && names[2] == "蓝色",
                "candidate names follow display order");
            var disabled = ItemNamed(list, "绿色（禁用）");
            Check(disabled != null && !disabled.Current.IsEnabled,
                "disabled candidate reports IsEnabled=false");
            var green = ItemNamed(list, "蓝色");
            Check(green != null && green.Current.IsEnabled, "enabled candidate reports IsEnabled=true");
            Check(green != null && !IsSelected(green), "candidates are not reported as selected");
            object listSelection;
            Check(TryPattern(list, SelectionPattern.Pattern, out listSelection),
                "popup list exposes SelectionPattern");
            if (listSelection != null)
                Check(!((SelectionPattern)listSelection).Current.CanSelectMultiple,
                    "selection pattern is single-select");
            Check(green != null && green.Current.BoundingRectangle.Width > 0 &&
                !green.Current.IsOffscreen, "candidate exposes bounds and offscreen state");
            Check(green != null && green.Current.NativeWindowHandle == 0,
                "candidate is a fragment, not a fake window");

            // ---- selection interaction --------------------------------------------
            object disabledItem;
            bool disabledRefused = false;
            int selectionEventsBeforeReject = Volatile.Read(ref selectionEvents);
            if (disabled != null && disabled.TryGetCurrentPattern(SelectionItemPattern.Pattern, out disabledItem))
            {
                Exception disabledError = null;
                try { ((SelectionItemPattern)disabledItem).Select(); }
                catch (Exception error) { disabledRefused = true; disabledError = error; }
                Check(disabledRefused && RejectedAs(disabledError, "disabled-select",
                        unchecked((int)0x80040200), typeof(ElementNotEnabledException)),
                    "selecting a disabled candidate is refused with the UIA not-enabled error");
                Check(Volatile.Read(ref selectionEvents) == selectionEventsBeforeReject,
                    "a refused selection raised no selection event");
                Settle(300);
                Check(FindPopup(appWindow) != IntPtr.Zero, "refused disabled selection left the popup open");
            }
            else Check(false, "disabled candidate exposes SelectionItemPattern");
            // Positive control: a legal candidate must work.
            selectionEvents = 0;
            object legalItem;
            bool legalWorked = false;
            if (green != null && green.TryGetCurrentPattern(SelectionItemPattern.Pattern, out legalItem))
            {
                try { ((SelectionItemPattern)legalItem).Select(); legalWorked = true; }
                catch (Exception) { legalWorked = false; }
            }
            Check(legalWorked, "selecting a legal candidate is accepted");
            Check(WaitFor(delegate () { return Volatile.Read(ref selectionEvents) >= 1; }),
                "the accepted selection raised a real UIA selection event");
            Settle(600);
            Check(FindPopup(appWindow) == IntPtr.Zero, "accepted selection closed the popup");
            Check(((ValuePattern)valuePattern).Current.Value == "蓝色",
                "accepted selection updated the read-only value");
            Check(WindowText(FindChildText(appWindow, "蓝色")) == "蓝色",
                "trigger text follows the accepted value");
            Check(expand.Current.ExpandCollapseState == ExpandCollapseState.Collapsed,
                "accepted selection reports the collapsed state");
            Shot("select-page-light", appWindow);

            // ---- value/open requests reach the app, accepted state wins -----------
            expand.Expand();
            Settle(500);
            IntPtr secondPopup = FindPopup(appWindow, "颜色");
            var second = secondPopup != IntPtr.Zero
                ? AutomationElement.FromHandle(secondPopup) : null;
            Check(second != null && ItemNamed(second, "蓝色") != null && IsSelected(ItemNamed(second, "蓝色")),
                "reopened popup reports the accepted value as selected");
            Check(SelectedOnly(second, "蓝色"), "exactly one candidate is selected");
            // Candidate navigation must not become a selection.
            Tap(VkDown);
            Settle(300);
            Check(SelectedOnly(second, "蓝色"), "keyboard candidate move does not change the selection");
            object itemPattern;
            var blue = ItemNamed(second, "蓝色");
            if (blue != null && blue.TryGetCurrentPattern(SelectionItemPattern.Pattern, out itemPattern))
                Check(((SelectionItemPattern)itemPattern).Current.IsSelected, "selected item reports IsSelected");
            Tap(VkEscape);
            Settle(500);
            Check(FindPopup(appWindow) == IntPtr.Zero, "Escape closed the popup");
            Check(((ValuePattern)valuePattern).Current.Value == "蓝色",
                "cancel kept the accepted value");

            // ---- dark theme visual capture ---------------------------------------
            var themeElement = FindWithWait(app, new AndCondition(
                new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button),
                new PropertyCondition(AutomationElement.NameProperty, "切换浅色/深色")),
                "natural-theme-button", 8000);
            IntPtr themeButton = themeElement != null
                ? new IntPtr(themeElement.Current.NativeWindowHandle) : IntPtr.Zero;
            Check(themeButton != IntPtr.Zero, "theme toggle control exists");
            if (themeButton != IntPtr.Zero)
            {
                Click(themeButton);
                Settle(600);
                expand.Expand();
                Settle(600);
                IntPtr dark = FindPopup(appWindow, "颜色");
                Check(dark != IntPtr.Zero, "popup opens in the dark theme");
                if (dark != IntPtr.Zero) Shot("select-popup-dark", dark);
                Tap(VkEscape);
                Settle(500);
                Click(themeButton);
                Settle(600);
            }

            // ---- lifecycle: retired fragments must be ElementNotAvailable ---------
            held[1] = second;
            held[2] = blue;
            Check(ElementGone(second), "retired popup element reports ElementNotAvailable");
            Check(blue == null || ElementGone(blue), "retired candidate element reports ElementNotAvailable");

            // ---- accepted-state and option reorder -------------------------------
            var reverseElement = FindWithWait(app, new AndCondition(
                new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button),
                new PropertyCondition(AutomationElement.NameProperty, "重排选项")),
                "natural-reorder-button", 8000);
            IntPtr reverse = reverseElement != null
                ? new IntPtr(reverseElement.Current.NativeWindowHandle) : IntPtr.Zero;
            Check(reverse != IntPtr.Zero, "reorder control exists");
            if (reverse != IntPtr.Zero)
            {
                Click(reverse);
                Settle(500);
                expand.Expand();
                Settle(500);
                IntPtr reorderedPopup = FindPopup(appWindow, "颜色");
                var reordered = reorderedPopup != IntPtr.Zero
                    ? AutomationElement.FromHandle(reorderedPopup) : null;
                Check(reordered != null, "popup opens after reordering options");
                if (reordered != null)
                {
                    var reorderedNames = ItemNames(reordered);
                    Check(reorderedNames.Length == 6 && reorderedNames[0] == "石板灰",
                        "reordered display order is reported by UIA");
                    Check(SelectedOnly(reordered, "蓝色"),
                        "accepted value stays selected by key after reordering");
                    Tap(VkEscape);
                    Settle(400);
                    Check(FindPopup(appWindow) == IntPtr.Zero,
                        "reordered popup closed before the long-list case");
                }
            }

            // ---- long list: whole rows, offscreen state, keyboard reachability ---
            Note("[STEP] natural-long-select");
            AutomationElement longElement = null;
            var selects = app.FindAll(TreeScope.Descendants,
                new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.ComboBox));
            foreach (AutomationElement candidate in selects)
                if (NameOf(candidate).StartsWith("长列表")) { longElement = candidate; break; }
            Check(longElement != null, "long-list Select discovered naturally by its UIA name");
            IntPtr longTrigger = longElement != null
                ? new IntPtr(longElement.Current.NativeWindowHandle) : IntPtr.Zero;
            Check(longTrigger != IntPtr.Zero, "long-list trigger exists");
            if (longTrigger != IntPtr.Zero)
            {
                object longExpand;
                Check(longElement.TryGetCurrentPattern(ExpandCollapsePattern.Pattern, out longExpand),
                    "long-list trigger exposes ExpandCollapsePattern");
                if (longExpand != null)
                {
                    ((ExpandCollapsePattern)longExpand).Expand();
                    Settle(600);
                    AutomationElement longListElement = null;
                    try
                    {
                        longListElement = longElement.FindFirst(TreeScope.Subtree,
                            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.List));
                    }
                    catch (Exception error) { Note("long popup search error " + error.GetType().Name); }
                    IntPtr longPopup = longListElement != null
                        ? new IntPtr(longListElement.Current.NativeWindowHandle) : IntPtr.Zero;
                    Note("longPopups=" + OwnedPopups(appWindow).Count + " natural=" + longPopup.ToString("X"));
                    var longList = longListElement;
                    Check(longList != null, "long-list List discovered naturally through its trigger");
                    Check(longList != null, "long-list popup element exists");
                    if (longList != null)
                    {
                        Note("longList children=" + ItemNames(longList).Length +
                            " first=" + string.Join(",", ItemNames(longList)));
                        var last = ItemNamed(longList, "选项20");
                        var first = ItemNamed(longList, "选项1");
                        Check(first != null && !first.Current.IsOffscreen,
                            "first long-list candidate is on screen");
                        Check(last != null && last.Current.IsOffscreen,
                            "unscrolled candidate reports IsOffscreen");
                        Tap(VkEnd);
                        Settle(400);
                        var lastAgain = ItemNamed(longList, "选项20");
                        var firstAgain = ItemNamed(longList, "选项1");
                        Check(lastAgain != null && !lastAgain.Current.IsOffscreen,
                            "End scrolls the last candidate on screen");
                        Check(firstAgain == null || firstAgain.Current.IsOffscreen,
                            "scrolled-away candidate reports IsOffscreen");
                        Shot("select-long-list-light", longPopup);
                        Tap(VkEscape);
                        Settle(400);
                    }
                }
            }

            // ---- modal domain: the dialog gate still applies ---------------------
            var openDialogElement = FindWithWait(app, new AndCondition(
                new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button),
                new PropertyCondition(AutomationElement.NameProperty, "打开含下拉的对话框")),
                "natural-dialog-button", 8000);
            IntPtr openDialog = openDialogElement != null
                ? new IntPtr(openDialogElement.Current.NativeWindowHandle) : IntPtr.Zero;
            Check(openDialog != IntPtr.Zero, "dialog entry control exists");
            if (openDialog != IntPtr.Zero)
            {
                Click(openDialog);
                Settle(700);
                // The dialog surface is a separate owned top-level window of this
                // application (not a Select target); the inner Select is then
                // discovered inside it.
                IntPtr surface = IntPtr.Zero;
                AutomationElement surfaceElement = null;
                var seenWindows = new List<string>();
                var surfaceWatch = Stopwatch.StartNew();
                while (surfaceWatch.ElapsedMilliseconds < 4000 && surfaceElement == null)
                {
                    seenWindows.Clear();
                    foreach (AutomationElement candidate in AutomationElement.RootElement.FindAll(
                        TreeScope.Children, new PropertyCondition(
                            AutomationElement.ControlTypeProperty, ControlType.Window)))
                    {
                        try
                        {
                            if (candidate.Current.ProcessId != process.Id) continue;
                            seenWindows.Add(candidate.Current.Name);
                            if (candidate.Current.Name != "表单中的下拉") continue;
                            surfaceElement = candidate;
                            break;
                        }
                        catch { }
                    }
                    if (surfaceElement == null) Thread.Sleep(200);
                }
                Note("[STEP] dialog-surface natural=" + (surfaceElement != null) +
                    " appWindows=[" + string.Join(",", seenWindows.ToArray()) + "]");
                if (surfaceElement == null)
                {
                    // The dialog surface is a plain application window (not a
                    // Select target): if the desktop tree does not list it, the
                    // owned-window caption identifies the container, and the
                    // inner Select is still discovered through UIA inside it.
                    surface = FindOwnedCaption(appWindow, "表单中的下拉");
                }
                else surface = new IntPtr(surfaceElement.Current.NativeWindowHandle);
                Check(surface != IntPtr.Zero, "dialog surface published (container located, Selects discovered by UIA)");
                if (surface != IntPtr.Zero)
                {
                    Note("pageTriggerEnabled=" + trigger.Current.IsEnabled +
                        " pageTriggerValue=" + ((ValuePattern)valuePattern).Current.Value);
                    Check(!trigger.Current.IsEnabled,
                        "page trigger is disabled while the modal dialog owns the gate");
                    bool pageRefused = false;
                    Exception pageError = null;
                    try { expand.Expand(); } catch (Exception error) { pageRefused = true; pageError = error; }
                    Settle(400);
                    Check(pageRefused &&
                        RejectedAs(pageError, "modal-expand", unchecked((int)0x80040200), typeof(ElementNotEnabledException)),
                        "UIA Expand outside the modal scope is refused with the UIA not-enabled error");
                    Check(FindPopup(appWindow) == IntPtr.Zero,
                        "the refused page Expand published no popup");
                    if (surfaceElement == null)
                    {
                        // Container element only: the inner Select below is still
                        // discovered through UIA inside this subtree.
                        surfaceElement = AutomationElement.FromHandle(surface);
                    }
                    Note("[STEP] natural-dialog-select");
                    AutomationElement innerElement = null;
                    var innerWatch = Stopwatch.StartNew();
                    while (innerWatch.ElapsedMilliseconds < 15000 && innerElement == null)
                    {
                        var innerSelects = surfaceElement.FindAll(TreeScope.Descendants,
                            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.ComboBox));
                        foreach (AutomationElement candidate in innerSelects)
                            if (NameOf(candidate).StartsWith("内层颜色")) { innerElement = candidate; break; }
                        if (innerElement == null) Thread.Sleep(250);
                    }
                    Check(innerElement != null, "dialog Select discovered naturally inside the dialog subtree");
                    var inner = innerElement;
                    if (inner != null)
                    {
                        object innerExpand;
                        Check(inner.TryGetCurrentPattern(ExpandCollapsePattern.Pattern, out innerExpand),
                            "inner trigger exposes ExpandCollapsePattern");
                        if (innerExpand != null)
                        {
                            ((ExpandCollapsePattern)innerExpand).Expand();
                            Settle(600);
                            Note("[STEP] natural-inner-list");
                            AutomationElement innerListElement = null;
                            try
                            {
                                innerListElement = innerElement.FindFirst(TreeScope.Subtree,
                                    new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.List));
                            }
                            catch (Exception error) { Note("inner popup search error " + error.GetType().Name); }
                            IntPtr innerPopup = innerListElement != null
                                ? new IntPtr(innerListElement.Current.NativeWindowHandle) : IntPtr.Zero;
                            Note("innerPopup=" + innerPopup.ToString("X") +
                                " appOwned=" + FindPopup(appWindow).ToString("X") +
                                " surface=" + surface.ToString("X"));
                            Check(innerPopup != IntPtr.Zero, "inner popup is owned by the dialog surface");
                            if (innerPopup != IntPtr.Zero)
                            {
                                var innerList = innerListElement;
                                var amber = ItemNamed(innerList, "琥珀色");
                                object amberItem;
                                bool innerSelected = false;
                                if (amber != null && amber.TryGetCurrentPattern(SelectionItemPattern.Pattern, out amberItem))
                                {
                                    try { ((SelectionItemPattern)amberItem).Select(); innerSelected = true; }
                                    catch (Exception) { innerSelected = false; }
                                }
                                Check(innerSelected, "inner legal candidate selection is accepted");
                                Settle(600);
                                Check(FindPopup(surface) == IntPtr.Zero, "inner selection closed only the inner popup");
                                IntPtr innerAgain = FindChildText(surface, "琥珀色");
                                Check(innerAgain != IntPtr.Zero, "inner trigger text follows the accepted value");
                                object innerValue;
                                if (inner.TryGetCurrentPattern(ValuePattern.Pattern, out innerValue))
                                    Check(((ValuePattern)innerValue).Current.Value == "琥珀色",
                                        "inner read-only value follows the accepted value");
                                Check(IsWindowVisible(surface), "dialog stayed open after the inner selection");
                                Shot("select-dialog-context", surface);
                            }
                        }
                    }
                }
            }
        }
        catch (Exception error)
        {
            failures.Add("exception: " + error.GetType().Name + ": " + error.Message);
            report.Add("[FAILED] exception: " + error.GetType().Name + ": " + error.Message);
        }
        finally
        {
            try { Automation.RemoveStructureChangedEventHandler(app, structureHandler); } catch { }
            // Normal close path first: the application must exit through its own
            // window close, and only then must the retired elements answer
            // ElementNotAvailable. Killing is cleanup for a failed case only.
            bool closedNormally = false;
            try
            {
                if (!process.HasExited)
                {
                    // The same message the system title-bar X sends: the
                    // application's own close handshake, not a kill.
                    PostMessage(appWindow, WmClose, IntPtr.Zero, IntPtr.Zero);
                    closedNormally = process.WaitForExit(8000);
                }
                else closedNormally = true;
            }
            catch (Exception error) { Note("normal close error " + error.GetType().Name); }
            if (!closedNormally)
            {
                Note("[FAILED] normal window close did not exit the application");
                failures.Add("normal close");
                try { if (!process.HasExited) process.Kill(); } catch { }
                try { process.WaitForExit(4000); } catch { }
            }
            else Check(true, "application exited through its normal window close path");
            Thread.Sleep(400);
            if (held[0] != null) Check(ElementGone(held[0]), "closed application retires its UIA elements");
            if (list != null)
            {
                try { Automation.RemoveAutomationEventHandler(SelectionItemPattern.ElementSelectedEvent, list, selectionHandler); } catch { }
                try { Automation.RemoveAutomationEventHandler(SelectionPattern.InvalidatedEvent, list, selectionHandler); } catch { }
            }
            if (trigger != null)
            {
                try { Automation.RemoveAutomationPropertyChangedEventHandler(trigger, propertyHandler); } catch { }
            }
            try { Automation.RemoveAllEventHandlers(); } catch { }
        }
        report.Add("passed=" + passed + " failed=" + failures.Count);
        report.Add(failures.Count == 0 ? "ALL OBSERVATIONS PASSED" : "OBSERVATIONS FAILED");
        File.WriteAllLines(Path.Combine(output, "select-client.log"), report.ToArray(), new UTF8Encoding(false));
        foreach (var line in report) Console.WriteLine(line);
        return failures.Count == 0 ? 0 : 1;
    }
}
