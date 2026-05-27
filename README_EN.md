# Claude Code Notification Hook for Windows

**English** | [中文](README.md)

Push Toast notifications through Windows Notification Center with taskbar flashing for Claude Code hook events. **Zero external dependencies** — uses only built-in Windows APIs and PowerShell.

## Features

- **Toast notification** — push notifications via Windows Notification Center (silent, avoids double sound)
- **Click to activate** — clicking the toast brings the Claude Code terminal window to the foreground
- **System sound** — plays `System.Media.SystemSounds.Asterisk` alert
- **Taskbar flashing** — flashes 3 times, then keeps taskbar highlighted until you switch to the window
- **Duplicate suppression** — auto-debounce: skips repeated events within 10 seconds (except `Stop`)
- **Zero dependencies** — pure PowerShell + WinRT API + .NET, no module installs needed

## Events

| Event | Trigger |
|-------|---------|
| `Stop` | Response finished |
| `Notification` | Custom message from Claude Code |
| `PermissionRequest` | Claude Code needs permission |

## Quick Install

Run in PowerShell from the project directory:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

This will:
1. Register the AppUserModelID shortcut in Start Menu (required for Toast to work)
2. Copy `claude-hook-toast.ps1` to `%USERPROFILE%\.claude\`
3. Update `%USERPROFILE%\.claude\settings.json` with hook configuration (preserves existing settings)

Restart Claude Code to activate. Verify with `/hooks` in Claude Code.

## Manual Installation

### 1. Register AppUserModelID

Windows Toast API requires a Start Menu shortcut with the AppUserModelID set. Create `%APPDATA%\Microsoft\Windows\Start Menu\Programs\ClaudeCodeNotify.lnk` with AppUserModelID `ClaudeCode.Notification` via `IShellLinkW` + `IPropertyStore` COM interfaces. See `install.ps1` for the implementation.

### 2. Copy the script

```powershell
Copy-Item -Path "claude-hook-toast.ps1" -Destination "$env:USERPROFILE\.claude\claude-hook-toast.ps1" -Force
```

### 3. Edit `~/.claude/settings.json`

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "powershell -ExecutionPolicy Bypass -File \"${env:USERPROFILE}\\.claude\\claude-hook-toast.ps1\" -Event Stop",
            "async": true,
            "shell": "powershell",
            "timeout": 10
          }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "powershell -ExecutionPolicy Bypass -File \"${env:USERPROFILE}\\.claude\\claude-hook-toast.ps1\" -Event Notification",
            "async": true,
            "shell": "powershell",
            "timeout": 10
          }
        ]
      }
    ],
    "PermissionRequest": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "powershell -ExecutionPolicy Bypass -File \"${env:USERPROFILE}\\.claude\\claude-hook-toast.ps1\" -Event PermissionRequest",
            "async": true,
            "shell": "powershell",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

> **Note**: Using `${env:USERPROFILE}` avoids hardcoding the username path, making it portable across machines.

## Files

| File | Purpose |
|------|---------|
| `claude-hook-toast.ps1` | Main notification script (Toast + click-to-activate + taskbar flash + sound + debounce + logging) |
| `install.ps1` | One-click installer (registers AppUserModelID + copies script + configures hooks) |

## Debugging

Script logs are written to `%TEMP%\claude_hook_log.txt`. Run `/hooks` in Claude Code to verify hooks are loaded correctly.

## Requirements

- Windows 10 or later
- PowerShell 5.1+
- Claude Code

## How It Works

The Windows Toast API (`ToastNotificationManager.CreateToastNotifier`) requires the app's AppUserModelID to be registered in a Start Menu shortcut. `install.ps1` uses `IShellLinkW` + `IPropertyStore` COM interfaces to create a `.lnk` file with the `PKEY_AppUserModel_ID` property, making `ClaudeCode.Notification` a valid notification source.

The notification script reads hook event JSON from stdin, then:
- Enumerates process windows to find one with "Claude" in the title
- Flashes the taskbar via `FlashWindowEx` (user32.dll)
- Plays `SystemSounds.Asterisk` system sound
- Pushes a Toast notification via WinRT `ToastNotificationManager` API
- Registers the `ToastNotification.Activated` event and runs a `DoEvents` message pump (up to 8 seconds)
- On click, forces the target window to the foreground using `AttachThreadInput` + `SetForegroundWindow`

## License

MIT
