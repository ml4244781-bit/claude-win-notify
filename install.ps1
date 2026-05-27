# Claude Code Toast Notification Hook - Optimized Installer
# Run: powershell -ExecutionPolicy Bypass -File install.ps1
$ErrorActionPreference = "Stop"

$scriptName = "claude-hook-toast.ps1"
$sourcePath = Join-Path $PSScriptRoot $scriptName
$destDir = Join-Path $env:USERPROFILE ".claude"
$destPath = Join-Path $destDir $scriptName
$settingsPath = Join-Path $destDir "settings.json"
$appId = "ClaudeCode.Notification"
$shortcutPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\ClaudeCodeNotify.lnk"

# Create .claude directory if missing
if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

# Copy hook script (skip if already in the destination directory)
if ((Resolve-Path $sourcePath).Path -ne (Resolve-Path $destPath).Path) {
    Copy-Item -Path $sourcePath -Destination $destPath -Force
    Write-Host "[OK] Copied $scriptName to $destPath"
} else {
    Write-Host "[SKIP] $scriptName already in $destDir"
}

# Register AppUserModelID shortcut (required for Windows Toast notifications)
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
[ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IShellLinkW {
    void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszFile, int cchMaxPath, out IntPtr pfd, uint fFlags);
    void GetIDList(out IntPtr ppidl);
    void SetIDList(IntPtr pidl);
    void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszFile, int cchMaxName);
    void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
    void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszDir, int cchMaxPath);
    void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
    void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszArgs, int cchMaxPath);
    void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
    void GetHotkey(out ushort pwHotkey);
    void SetHotkey(ushort wHotkey);
    void GetShowCmd(out int piShowCmd);
    void SetShowCmd(int iShowCmd);
    void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszIconPath, int cchMaxPath, out int piIcon);
    void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
    void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, uint dwReserved);
    void Resolve(IntPtr hwnd, uint fFlags);
    void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
}
[ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPropertyStore {
    void GetCount(out uint cProps);
    void GetAt(uint iProp, out PROPERTYKEY pkey);
    void GetValue(ref PROPERTYKEY key, out PROPVARIANT pv);
    void SetValue(ref PROPERTYKEY key, ref PROPVARIANT pv);
    void Commit();
}
[StructLayout(LayoutKind.Sequential)]
public struct PROPERTYKEY {
    public Guid fmtid;
    public uint pid;
}
[StructLayout(LayoutKind.Sequential)]
public struct PROPVARIANT {
    public ushort vt;
    public ushort wReserved1;
    public ushort wReserved2;
    public ushort wReserved3;
    public IntPtr p;
}
[ComImport, Guid("0000010B-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPersistFile {
    void GetCurFile([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszFile);
    void IsDirty();
    void Load([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, uint dwMode);
    void Save([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, int fRemember);
    void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
}
public class ShortcutHelper {
    private static readonly PROPERTYKEY PKEY_AppUserModel_ID = new PROPERTYKEY {
        fmtid = new Guid("{9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}"), pid = 5
    };
    public static void CreateShortcut(string path, string target, string appUserModelId) {
        var shellLink = (IShellLinkW)new ShellLink();
        shellLink.SetPath(target);
        shellLink.SetArguments("-NoProfile -WindowStyle Hidden");
        shellLink.SetShowCmd(1);
        var key = PKEY_AppUserModel_ID;
        var propStore = (IPropertyStore)shellLink;
        PROPVARIANT pv = new PROPVARIANT { vt = 31 };
        IntPtr hGlobal = Marshal.StringToCoTaskMemUni(appUserModelId);
        pv.p = hGlobal;
        propStore.SetValue(ref key, ref pv);
        propStore.Commit();
        Marshal.FreeCoTaskMem(hGlobal);
        var persistFile = (IPersistFile)shellLink;
        persistFile.Save(path, 1);
    }
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    private class ShellLink {}
}
"@

[ShortcutHelper]::CreateShortcut($shortcutPath, "powershell.exe", $appId)
Write-Host "[OK] Registered AppUserModelID '$appId' shortcut"

# Build CORRECT 3-level hook configuration (event → matcher group → hooks array)
$hookEvents = @("Stop", "Notification")
$hookConfig = @{}

foreach ($event in $hookEvents) {
    $hookConfig[$event] = @(
        @{
            matcher = ""  # Empty matcher = match all scenarios
            hooks = @(
                @{
                    type = "command"
                    command = "powershell -STA -ExecutionPolicy Bypass -File `"`${env:USERPROFILE}\\.claude\\$scriptName`" -Event $event"
                    async = $true
                    shell = "powershell"  # Explicitly specify PowerShell shell
                    timeout = 35  # Allow up to 30s for toast click + buffer
                }
            )
        }
    )
}

# Read existing settings or create new
if (Test-Path $settingsPath) {
    $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
} else {
    $settings = New-Object PSObject
}

# Merge hooks into settings (overwrites existing hooks, preserves other settings)
$settings | Add-Member -Type NoteProperty -Name "hooks" -Value $hookConfig -Force

# Write back with pretty formatting and UTF-8 encoding
$settings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath -Encoding UTF8
Write-Host "[OK] Updated $settingsPath with standard-compliant hook configuration"

Write-Host ""
Write-Host "✅ Installation complete! Restart Claude Code to apply changes."
Write-Host "🔍 Verify: Run '/hooks' in Claude Code to check loaded hooks"