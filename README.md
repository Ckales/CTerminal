# CTerminal

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE.md)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows-lightgrey.svg)](#系统要求)

CTerminal 是一款面向 macOS 和 Windows 的桌面终端，支持本地命令行、SSH、标签页、分屏和 SFTP 文件传输。

**[下载 CTerminal](https://github.com/Ckales/CTerminal/releases/latest)** · [查看所有版本](https://github.com/Ckales/CTerminal/releases)

## 下载与安装

### macOS

1. 从 Releases 下载 `.dmg` 并打开。
2. 将 `CTerminal.app` 拖到 `Applications` 文件夹。
3. 从“应用程序”中启动 CTerminal。

首次打开时，如果 macOS 提示无法验证开发者，请确认应用来自本项目 Releases，然后在“系统设置 → 隐私与安全性”中允许打开。

### Windows

1. 从 Releases 下载 Windows `.zip` 并解压整个压缩包。
2. 打开解压后的 `CTerminal` 文件夹，运行 `CTerminal.exe`。


## 功能

- **终端**：支持 256 色和真彩色、中文与表情符号、输入法组合输入、搜索、鼠标交互、链接打开和文件路径粘贴。
- **标签页与分屏**：标签重命名、排序、颜色标记；横向或纵向分屏、调整比例、最大化窗格；重启后恢复会话布局。
- **连接**：本地 shell、SSH、Telnet、串口；SSH 支持密钥、ssh-agent、跳板机和端口转发。
- **文件传输**：SSH 会话可使用 SFTP 面板浏览和管理文件；支持拖入上传、下载、重命名和文件夹操作。终端也支持 ZMODEM 收发。
- **个性化**：简体中文和英文界面、主题与配色方案、字体、可调整的快捷键，以及可保存和分组的连接配置。
- **AI 助手**：可隐藏的右侧或底部面板，支持独立会话对话、附加终端选区和复制生成的命令。

## 快速开始

- 启动后可直接使用本地 shell。
- 按 `⌘E`（macOS）打开配置选择器；也可以输入 `user@host:port` 快速建立 SSH 连接。
- SSH 连接成功后，可通过文件面板访问远程文件。
- 更多外观、终端、连接和快捷键选项位于“设置”中。

### 常用快捷键（macOS）

| 快捷键 | 操作 |
| --- | --- |
| `⌘T` / `⌘W` / `⌘⇧T` | 新建 / 关闭 / 重新打开标签页 |
| `⌘1`…`⌘9`、`⌃Tab` | 切换标签页 |
| `⌘⇧D` / `⌘D` | 向右 / 向下拆分 |
| `⌘⌥←→↑↓` | 切换窗格 |
| `⌘⌥↩` | 最大化窗格 |
| `⌘E` | 选择连接配置 |
| `⌘⇧P` | 打开命令面板 |
| `⌘F` | 搜索终端内容 |
| `⌘C` / `⌘V` / `⌘K` | 复制 / 粘贴 / 清屏 |
| `⌘,` | 打开设置 |

所有快捷键都可以在“设置 → 快捷键”中查看和修改。

### AI 助手

点击设置按钮左侧的对话图标打开助手。在“设置 → AI助手”填写 Chat Completions 兼容服务的 Base URL（例如 `https://api.example.com/v1`）、模型名称和 API Key，保存后即可对话。服务地址和模型名称请使用服务商提供的值；API Key 存入系统凭据存储。

面板可以在设置或面板顶部菜单中切换到右侧／底部，拖动分隔线可调整尺寸。每个终端窗格保留自己的对话和草稿，收起面板后仍会保留，退出应用后清除。默认只发送你输入的文字；点击附件按钮可加入当前终端选区，发送前可以查看和移除。生成的命令可以复制后自行执行。

## 系统要求

- macOS 12 或更高版本
- Windows 10 版本 1809 或更高版本

## 配置与安全

- 配置文件位于 macOS `~/Library/Application Support/CTerminal/config.json`，Windows `%APPDATA%\CTerminal\config.json`。
- SSH 密码和私钥口令保存在系统凭据存储中（macOS 钥匙串或 Windows 凭据管理器），不写入应用配置文件。
- 首次连接 SSH 主机时，请核对并确认主机指纹。之后如果主机密钥发生变化，CTerminal 会发出警告并默认拒绝连接。

## 常见问题

**macOS 提示无法验证开发者，怎么办？**

这是当前未公证安装包触发的 Gatekeeper 提示。确认安装包来自本项目 Releases 后，按“下载与安装 → macOS”的步骤在“隐私与安全性”中手动允许打开。

**Windows ZIP 是源码吗？**

不是。它包含运行程序所需的发布文件。解压完整 ZIP 后运行其中的 `CTerminal.exe`；源码可以通过本仓库获取。

**从哪里报告问题？**

请在 [GitHub Issues](https://github.com/Ckales/CTerminal/issues) 提交问题，并附上操作系统版本、复现步骤和相关报错信息。请勿提交密码、私钥或其他凭据。

## 参与贡献

欢迎通过 [GitHub Issues](https://github.com/Ckales/CTerminal/issues) 反馈问题或提交 Pull Request。

## 致谢

感谢 [alacritty_terminal](https://github.com/alacritty/alacritty)、[russh](https://github.com/Eugeny/russh) 和 [portable-pty](https://github.com/wez/wezterm) 项目。

## 许可证

[MIT](LICENSE.md)
