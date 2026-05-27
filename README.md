# Claude Code 通知挂钩 for Windows

[English](README_EN.md) | **中文**

通过 Windows 通知中心弹出 Toast 通知，并在任务栏闪烁图标，让你在不看终端时也能感知 Claude Code 的状态。**零外部依赖**——仅使用 Windows 内置 API 和 PowerShell。

## 功能

- **Toast 通知** — 通过 Windows 通知中心推送消息（静默，不重复播放提示音）
- **点击激活** — 点击 Toast 通知自动将 Claude Code 窗口切换至前台并激活
- **系统提示音** — 通过 `System.Media.SystemSounds.Asterisk` 播放系统音效
- **任务栏闪烁** — 任务栏按钮闪烁 3 次，切换窗口后自动取消
- **重复抑制** — 10 秒内自动忽略同一事件的重复触发（`Stop` 事件除外）
- **零依赖** — 纯 PowerShell + WinRT API + .NET，无需安装任何模块

## 事件

| 事件 | 触发时机 |
|------|---------|
| `Stop` | 响应完成 |
| `Notification` | Claude Code 发来自定义消息 |
| `PermissionRequest` | Claude Code 需要授权 |

## 快速安装

在项目目录下打开 PowerShell，运行：

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

安装脚本会自动完成：
1. 注册 AppUserModelID 快捷方式到开始菜单（Toast 通知的必要前提）
2. 将 `claude-hook-toast.ps1` 复制到 `%USERPROFILE%\.claude\`
3. 自动更新 `%USERPROFILE%\.claude\settings.json` 中的 hooks 配置（保留其他已有设置）

重启 Claude Code 后生效。可在 Claude Code 中运行 `/hooks` 验证配置是否加载成功。

## 手动安装

### 1. 注册 AppUserModelID

Windows Toast 通知要求应用程序在开始菜单中有注册的快捷方式。创建 `%APPDATA%\Microsoft\Windows\Start Menu\Programs\ClaudeCodeNotify.lnk` 并设置其 AppUserModelID 为 `ClaudeCode.Notification`。`install.ps1` 通过 `IShellLinkW` + `IPropertyStore` COM 接口自动完成此步骤。

### 2. 复制脚本

```powershell
Copy-Item -Path "claude-hook-toast.ps1" -Destination "$env:USERPROFILE\.claude\claude-hook-toast.ps1" -Force
```

### 3. 编辑 `~/.claude/settings.json`

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

> **注意**：使用 `${env:USERPROFILE}` 环境变量可以避免硬编码用户名路径，更具可移植性。

## 项目文件

| 文件 | 用途 |
|------|------|
| `claude-hook-toast.ps1` | 主通知脚本（Toast + 点击激活窗口 + 任务栏闪烁 + 系统提示音 + 重复抑制 + 日志记录） |
| `install.ps1` | 一键安装（注册 AppUserModelID + 复制脚本 + 配置 hooks） |

## 调试

脚本运行日志输出到 `%TEMP%\claude_hook_log.txt`，可在 Claude Code 中通过 `/hooks` 命令验证 hooks 是否正常加载。

## 系统要求

- Windows 10 或更高版本
- PowerShell 5.1+
- Claude Code

## 原理

Windows Toast 通知 API (`ToastNotificationManager.CreateToastNotifier`) 要求应用的 AppUserModelID 必须注册在开始菜单的快捷方式中。`install.ps1` 通过 `IShellLinkW` + `IPropertyStore` COM 接口创建 `.lnk` 文件并写入 `PKEY_AppUserModel_ID` 属性，使 `ClaudeCode.Notification` 成为有效的通知源。

通知脚本通过 stdin 读取 Claude Code 传递的 hook 事件 JSON 数据，解析事件类型和消息内容后：
- 枚举进程窗口，找到标题含 "Claude" 的窗口句柄
- 调用 `FlashWindowEx` (user32.dll) 闪烁任务栏
- 播放 `SystemSounds.Asterisk` 系统提示音
- 使用 WinRT `ToastNotificationManager` API 弹出 Toast 通知
- 注册 `ToastNotification.Activated` 事件，使用 `DoEvents` 消息泵等待点击（最长 8 秒）
- 点击时通过 `AttachThreadInput` + `SetForegroundWindow` 强制激活目标窗口

## 许可证

MIT
