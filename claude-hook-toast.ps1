# Claude Code Notification Hook Script (Windows PowerShell)
param([string]$Event = "", [string]$Message = "")

$logFile = "${env:TEMP}\claude_hook_log.txt"
function Write-Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    "$ts [$pid] $msg" | Out-File $logFile -Append -Encoding utf8
}

Write-Log "===== START Event=[$Event] Message=[$Message] ====="

# Always read stdin for hook event data (message, etc.)
$json = ($input | Out-String) | ConvertFrom-Json -ErrorAction SilentlyContinue
if (-not $Event) { $Event = $json.hook_event_name }
if (-not $Message) { $Message = $json.message }
Write-Log "After stdin: Event=[$Event] Message=[$Message]"

# Debounce: skip same event within 10 seconds, never debounce Stop
if ($Event -ne "Stop") {
    try {
        $f = "${env:TEMP}\claude_hook_$Event"
        $now = (Get-Date).ToUniversalTime().Ticks
        if (Test-Path $f) {
            $prev = [Int64](Get-Content $f -Raw)
            if ($prev -and ($now - $prev) -lt 100000000) {  # 10 seconds in ticks (100ns units)
                Write-Log "DEBOUNCED: interval $((($now - $prev)/10000000).ToString('0.0'))s"
                exit 0
            }
        }
        $now | Set-Content $f
        Write-Log "Debounce updated"
    } catch { Write-Log "Debounce ERROR: $($_.Exception.Message)" }
}

$text = switch ($Event) {
    "Stop"             { "Response finished" }
    "Notification"     { if ($Message) { $Message } else { "New notification" } }
    "PermissionRequest"{ "Permission required" }
    default            { if ($Event) { "$Event : $Message" } else { "Claude Code" } }
}
Write-Log "Toast text: [$text]"

# ── Window activation helpers (find terminal, flash, bring to foreground) ──
Add-Type @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
public static class WinActivate {
    // ── Foreground / flash helpers ──
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int dwProcessId);
    [DllImport("user32.dll")] public static extern bool FlashWindowEx(ref FLASHWINFO fi);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();

    public struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }
    public const uint FLASHW_TRAY = 2;

    // ── Parent-process helpers (NtQueryInformationProcess) ──
    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(IntPtr hProcess, int infoClass, out PROCESS_BASIC_INFORMATION pbi, int size, out int bytesRead);

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_BASIC_INFORMATION {
        public IntPtr ExitStatus;
        public IntPtr PebBaseAddress;
        public IntPtr AffinityMask;
        public IntPtr BasePriority;
        public UIntPtr UniqueProcessId;
        public IntPtr InheritedFromUniqueProcessId;
    }

    private static int GetParentProcessId(int pid) {
        try {
            using (var p = Process.GetProcessById(pid)) {
                int bytesRead;
                PROCESS_BASIC_INFORMATION pbi;
                int status = NtQueryInformationProcess(p.Handle, 0, out pbi, Marshal.SizeOf(typeof(PROCESS_BASIC_INFORMATION)), out bytesRead);
                if (status == 0) return (int)pbi.InheritedFromUniqueProcessId.ToInt64();
            }
        } catch {}
        return -1;
    }

    // ── Process names that should be skipped in tree walk ──
    private static readonly string[] NonTerminalProcesses = new[] {
        "explorer", "sihost", "taskhostw", "taskhostex", "dwm", "rundll32"
    };

    private static bool IsNonTerminal(string name) {
        name = name.ToLowerInvariant();
        foreach (var s in NonTerminalProcesses)
            if (name == s) return true;
        return false;
    }

    /// <summary>Walk the parent process chain to find the terminal window that hosts us.</summary>
    public static IntPtr FindTerminalByProcessTree() {
        string logPath = System.IO.Path.Combine(System.Environment.GetEnvironmentVariable("TEMP"), "claude_hook_log.txt");
        int ourPid = Process.GetCurrentProcess().Id;
        Action<string> Log = msg => System.IO.File.AppendAllText(logPath,
            string.Format("{0:yyyy-MM-dd HH:mm:ss.fff} [{1}] {2}\r\n", DateTime.Now, ourPid, msg),
            Encoding.UTF8);

        Log("FindTerminal: walking parent chain from PID=" + ourPid);

        int currentPid = ourPid;
        for (int level = 0; level < 10; level++) {
            int ppid = GetParentProcessId(currentPid);
            if (ppid <= 0) { Log("FindTerminal: no more parents"); break; }

            try {
                using (var parent = Process.GetProcessById(ppid)) {
                    IntPtr hwnd = parent.MainWindowHandle;
                    string name = parent.ProcessName.ToLowerInvariant();
                    Log(string.Format("FindTerminal: level={0} PID={1} name={2} hwnd={3}",
                        level, ppid, parent.ProcessName, hwnd));

                    if (IsNonTerminal(name) && hwnd != IntPtr.Zero) {
                        Log(string.Format("FindTerminal: SKIPPING non-terminal '{0}' hwnd={1}", name, hwnd));
                        currentPid = ppid;
                        continue;
                    }

                    if (hwnd != IntPtr.Zero) {
                        Log(string.Format("FindTerminal: SELECTED PID={0} name={1} hwnd={2}",
                            ppid, parent.ProcessName, hwnd));
                        return hwnd;
                    }
                    currentPid = ppid;
                }
            } catch { Log("FindTerminal: error opening parent PID=" + ppid); break; }
        }
        Log("FindTerminal: NOT FOUND in process tree");
        return IntPtr.Zero;
    }

    // ── Console-attach strategy: attach to claude.exe's console ──
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AttachConsole(int dwProcessId);
    [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "FreeConsole")]
    private static extern bool FreeConsoleNative();
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")]
    private static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder lpClassName, int nMaxCount);

    /// <summary>Walk parent chain to find the specific claude.exe PID that spawned us.</summary>
    private static int FindParentClaudePid() {
        int currentPid = Process.GetCurrentProcess().Id;
        for (int level = 0; level < 10; level++) {
            int ppid = GetParentProcessId(currentPid);
            if (ppid <= 0) break;
            try {
                using (var p = Process.GetProcessById(ppid)) {
                    if (p.ProcessName.Equals("claude", StringComparison.OrdinalIgnoreCase))
                        return ppid;
                    currentPid = ppid;
                }
            } catch { break; }
        }
        return -1;
    }

    /// <summary>Find the visible terminal window by attaching to the specific claude.exe's console.</summary>
    public static IntPtr FindTerminalViaConsole() {
        string logPath = System.IO.Path.Combine(System.Environment.GetEnvironmentVariable("TEMP"), "claude_hook_log.txt");
        int ourPid = Process.GetCurrentProcess().Id;
        Action<string> Log = msg => System.IO.File.AppendAllText(logPath,
            string.Format("{0:yyyy-MM-dd HH:mm:ss.fff} [{1}] {2}\r\n", DateTime.Now, ourPid, msg),
            Encoding.UTF8);

        // Step 1: find the specific claude.exe that spawned THIS hook
        int claudePid = FindParentClaudePid();
        if (claudePid <= 0) {
            Log("ConsoleAttach: could not find parent claude.exe PID");
            // Fallback: iterate all claude processes (less precise)
            foreach (var p in Process.GetProcessesByName("claude")) {
                claudePid = p.Id; break;
            }
            if (claudePid <= 0) { Log("ConsoleAttach: no claude.exe found"); return IntPtr.Zero; }
        }
        Log("ConsoleAttach: parent claude PID=" + claudePid);

        // Step 2: attach to the specific claude.exe's console
        FreeConsoleNative();
        if (!AttachConsole(claudePid)) {
            int err = Marshal.GetLastWin32Error();
            Log("ConsoleAttach: AttachConsole PID=" + claudePid + " failed error=" + err);
            return IntPtr.Zero;
        }
        IntPtr consoleHwnd = GetConsoleWindow();
        FreeConsoleNative();

        if (consoleHwnd == IntPtr.Zero) {
            Log("ConsoleAttach: GetConsoleWindow returned NULL");
            return IntPtr.Zero;
        }
        Log(string.Format("ConsoleAttach: got consoleHwnd={0}", consoleHwnd));

        // Step 3: if the console window is visible, use it directly (legacy console / standalone conhost)
        if (IsWindowVisible(consoleHwnd)) {
            Log("ConsoleAttach: console window is VISIBLE, using directly");
            return consoleHwnd;
        }
        Log("ConsoleAttach: console window is HIDDEN (Windows Terminal + ConPTY)");

        // Step 4: Windows Terminal case — find the CASCADIA_HOSTING_WINDOW_CLASS window
        // by searching for WindowsTerminal.exe / wt.exe processes with visible windows
        string[] terminalNames = { "WindowsTerminal", "wt" };
        foreach (var name in terminalNames) {
            foreach (var tp in Process.GetProcessesByName(name)) {
                try {
                    if (tp.MainWindowHandle != IntPtr.Zero && IsWindowVisible(tp.MainWindowHandle)) {
                        // Verify this is a terminal window by checking class name
                        var sb = new System.Text.StringBuilder(256);
                        if (GetClassName(tp.MainWindowHandle, sb, sb.Capacity) > 0) {
                            string cls = sb.ToString();
                            if (cls.IndexOf("CASCADIA", StringComparison.OrdinalIgnoreCase) >= 0 ||
                                cls.IndexOf("HOSTING", StringComparison.OrdinalIgnoreCase) >= 0) {
                                Log(string.Format("ConsoleAttach: found WindowsTerminal hwnd={0} class=[{1}]",
                                    tp.MainWindowHandle, cls));
                                return tp.MainWindowHandle;
                            }
                        }
                    }
                } catch { }
            }
        }

        // Step 5: fallback — also try searching any terminal-like top-level window
        // that contains our claude content
        Log("ConsoleAttach: returning hidden console hwnd as last resort");
        return consoleHwnd;
    }

    // ── Title-search fallback (used when process-tree walk and console-attach fail) ──
    public static IntPtr FindWindowByTitle() {
        string logPath = System.IO.Path.Combine(System.Environment.GetEnvironmentVariable("TEMP"), "claude_hook_log.txt");
        int pid = Process.GetCurrentProcess().Id;
        Action<string> Log = msg => System.IO.File.AppendAllText(logPath,
            string.Format("{0:yyyy-MM-dd HH:mm:ss.fff} [{1}] {2}\r\n", DateTime.Now, pid, msg),
            Encoding.UTF8);

        // 1) "Claude" in window title excluding browser windows (by title AND process name)
        string[] browserProcesses = new[] { "chrome", "msedge", "firefox", "opera", "brave", "vivaldi", "browser" };
        foreach (var p in Process.GetProcesses()) {
            try {
                if (p.MainWindowHandle == IntPtr.Zero || string.IsNullOrEmpty(p.MainWindowTitle)) continue;
                if (p.MainWindowTitle.IndexOf("Claude", StringComparison.OrdinalIgnoreCase) < 0) continue;
                // Skip browser windows regardless of how "Claude" appears in title
                string title = p.MainWindowTitle;
                bool isBrowser = title.Contains("Edge") || title.Contains("Chrome") || title.Contains("Firefox");
                if (!isBrowser) {
                    string pname = p.ProcessName.ToLowerInvariant();
                    foreach (var b in browserProcesses)
                        if (pname.Contains(b)) { isBrowser = true; break; }
                }
                if (isBrowser) continue;
                Log("TitleFallback: found [Claude title] hwnd=" + p.MainWindowHandle + " proc=" + p.ProcessName);
                return p.MainWindowHandle;
            } catch {}
        }

        // 2) Known terminal processes
        string[] terminalProcesses = new[] { "WindowsTerminal", "wt", "cmd", "powershell", "pwsh", "pwsh-preview" };
        foreach (var tp in terminalProcesses) {
            foreach (var p in Process.GetProcessesByName(tp)) {
                try {
                    if (p.MainWindowHandle != IntPtr.Zero) {
                        Log(string.Format("TitleFallback: found [{0}] hwnd={1} title=[{2}]",
                            tp, p.MainWindowHandle, p.MainWindowTitle));
                        return p.MainWindowHandle;
                    }
                } catch {}
            }
        }

        // 3) Any non-background window with "Command Prompt" or "PowerShell" or "Terminal" in title
        foreach (var p in Process.GetProcesses()) {
            try {
                if (p.MainWindowHandle == IntPtr.Zero || string.IsNullOrEmpty(p.MainWindowTitle)) continue;
                string title = p.MainWindowTitle;
                if (title.IndexOf("Command Prompt", StringComparison.OrdinalIgnoreCase) >= 0 ||
                    title.IndexOf("PowerShell", StringComparison.OrdinalIgnoreCase) >= 0 ||
                    title.IndexOf("Terminal", StringComparison.OrdinalIgnoreCase) >= 0) {
                    // Skip browser windows
                    string pname = p.ProcessName.ToLowerInvariant();
                    bool isBrowser = title.Contains("Edge") || title.Contains("Chrome") || title.Contains("Firefox");
                    if (!isBrowser) {
                        foreach (var b in browserProcesses)
                            if (pname.Contains(b)) { isBrowser = true; break; }
                    }
                    if (isBrowser) continue;
                    Log("TitleFallback: found [terminal title] hwnd=" + p.MainWindowHandle);
                    return p.MainWindowHandle;
                }
            } catch {}
        }

        Log("TitleFallback: NOT FOUND");
        return IntPtr.Zero;
    }

    // ── Bring a window to foreground (with thread-attach gymnastics) ──
    public static void ForceForeground(IntPtr hWnd) {
        string logPath = System.IO.Path.Combine(System.Environment.GetEnvironmentVariable("TEMP"), "claude_hook_log.txt");
        int pid = Process.GetCurrentProcess().Id;
        Action<string> Log = msg => System.IO.File.AppendAllText(logPath,
            string.Format("{0:yyyy-MM-dd HH:mm:ss.fff} [{1}] {2}\r\n", DateTime.Now, pid, msg),
            Encoding.UTF8);

        Log("ForceForeground: start hwnd=" + hWnd);
        if (hWnd == IntPtr.Zero) { Log("ForceForeground: ABORT hwnd is Zero"); return; }

        uint targetThreadId;
        GetWindowThreadProcessId(hWnd, out targetThreadId);
        uint currentThreadId = GetCurrentThreadId();
        Log(string.Format("ForceForeground: targetThread={0} currentThread={1}", targetThreadId, currentThreadId));

        bool attached = false;
        if (targetThreadId != currentThreadId) {
            attached = AttachThreadInput(currentThreadId, targetThreadId, true);
            Log("ForceForeground: AttachThreadInput=" + attached);
        }
        try {
            if (IsIconic(hWnd)) { Log("ForceForeground: SW_RESTORE=" + ShowWindow(hWnd, 9)); }
            Log("ForceForeground: SW_SHOW=" + ShowWindow(hWnd, 5));
            Log("ForceForeground: BringWindowToTop=" + BringWindowToTop(hWnd));
            Log("ForceForeground: SetForegroundWindow=" + SetForegroundWindow(hWnd));
        } finally {
            if (attached) { AttachThreadInput(currentThreadId, targetThreadId, false); }
        }
    }
}
"@

# ── Find the target window ──
# Strategy 1: walk parent process tree (skips Explorer, finds terminal)
$targetHwnd = [WinActivate]::FindTerminalByProcessTree()
if ($targetHwnd -eq [IntPtr]::Zero) {
    # Strategy 2: search window titles / process names for terminal windows
    # Handles Windows Terminal (Cascadia) where console-attach gives wrong hwnd
    Write-Log "ProcessTree: failed, trying title/process-name search"
    $targetHwnd = [WinActivate]::FindWindowByTitle()
}
if ($targetHwnd -eq [IntPtr]::Zero) {
    # Strategy 3: attach to claude.exe's console to get its console window
    # Last resort - may return hidden conhost window instead of visible terminal
    Write-Log "TitleSearch: failed, trying console-attach"
    $targetHwnd = [WinActivate]::FindTerminalViaConsole()
}
$twProc = 0; $twThread = [WinActivate]::GetWindowThreadProcessId($targetHwnd, [ref]$twProc)
Write-Log "TargetWindow: $targetHwnd (threadId=$twThread procId=$twProc)"

# ── Flash terminal taskbar ──
try {
    $fi = New-Object WinActivate+FLASHWINFO
    $fi.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($fi)
    $fi.dwFlags = [WinActivate]::FLASHW_TRAY
    $fi.uCount = 3
    # Use the same target window we found above
    if ($targetHwnd -ne [IntPtr]::Zero) {
        $fi.hwnd = $targetHwnd
    } else {
        $fi.hwnd = [WinActivate]::GetConsoleWindow()
    }
    if ($fi.hwnd -ne [IntPtr]::Zero) {
        $result = [WinActivate]::FlashWindowEx([ref]$fi)
        Write-Log "Flash: hwnd=$($fi.hwnd) result=$result"
    } else {
        Write-Log "Flash: no window handle found"
    }
} catch { Write-Log "Flash ERROR: $($_.Exception.Message)" }

# Play notification sound
try {
    [System.Media.SystemSounds]::Asterisk.Play()
    Write-Log "Sound: played"
} catch { Write-Log "Sound ERROR: $($_.Exception.Message)" }

# Toast notification (requires AppUserModelID shortcut - set up by install.ps1)
try {
    $tpl = [Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime]::GetTemplateContent(
        [Windows.UI.Notifications.ToastTemplateType,Windows.UI.Notifications,ContentType=WindowsRuntime]::ToastText02)
    $tpl.SelectSingleNode('//text[@id="1"]').InnerText = "Claude Code"
    $tpl.SelectSingleNode('//text[@id="2"]').InnerText = $text
    # Silent audio to avoid double sound with SystemSounds
    $el = $tpl.CreateElement("audio")
    $el.SetAttribute("silent", "true")
    $tpl.DocumentElement.AppendChild($el) | Out-Null
    $toast = New-Object Windows.UI.Notifications.ToastNotification $tpl
    $toast.Tag = "CC_$Event"
    $toast.Group = "ClaudeCode"
    $toast.SuppressPopup = $false

    # Click-to-activate: bring Claude Code window to foreground when toast is clicked
    Write-Log "ClickActivate: targetHwnd=$targetHwnd, registering handler"
    $clickSignal = New-Object System.Threading.ManualResetEvent($false)
    $clickLogFile = $logFile  # capture for closure

    # Register Activated event with explicit TypedEventHandler delegate.
    # PowerShell's Add_Activated() cannot correctly create WinRT generic delegates,
    # so we must construct the typed handler manually.
    $activatedHandler = [Windows.Foundation.TypedEventHandler[Windows.UI.Notifications.ToastNotification, Object]]{
        param($sender, $eventArgs)
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') [$pid] ClickActivate: *** ACTIVATED event fired! targetHwnd=$targetHwnd ***" |
            Out-File $clickLogFile -Append -Encoding utf8
        try {
            [WinActivate]::ForceForeground($targetHwnd)
            "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') [$pid] ClickActivate: ForceForeground completed" |
                Out-File $clickLogFile -Append -Encoding utf8
        } catch {
            "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') [$pid] ClickActivate: ForceForeground ERROR: $($_.Exception.Message)" |
                Out-File $clickLogFile -Append -Encoding utf8
        }
        try { $clickSignal.Set() } catch {
            "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') [$pid] ClickActivate: clickSignal.Set() ERROR: $($_.Exception.Message)" |
                Out-File $clickLogFile -Append -Encoding utf8
        }
    }
    $toast.add_Activated($activatedHandler)
    Write-Log "ClickActivate: handler registered, showing toast"

    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("ClaudeCode.Notification").Show($toast)
    Write-Log "Toast: sent successfully Tag=[CC_$Event]"

    # Wait for potential click (message pump keeps COM/WinRT events alive)
    if ($targetHwnd -ne [IntPtr]::Zero) {
        Write-Log "ClickActivate: starting DoEvents wait loop (max 30s)"
        Add-Type -AssemblyName System.Windows.Forms
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $lastLog = 0
        while ($sw.Elapsed.TotalSeconds -lt 30 -and -not $clickSignal.WaitOne(0)) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 200
            if ($sw.Elapsed.TotalSeconds - $lastLog -ge 5) {
                Write-Log "ClickActivate: waiting... elapsed=$($sw.Elapsed.TotalSeconds.ToString('0.0'))s"
                $lastLog = $sw.Elapsed.TotalSeconds
            }
        }
        Write-Log "ClickActivate: wait done elapsed=$($sw.Elapsed.TotalSeconds.ToString('0.0'))s signaled=$($clickSignal.WaitOne(0))"
        # Prevent GC of toast object before event can fire
        [GC]::KeepAlive($toast)
    } else {
        Write-Log "ClickActivate: skipped wait (no target window found)"
    }
} catch { Write-Log "Toast ERROR: $($_.Exception.Message)" }

Write-Log "===== END ====="
