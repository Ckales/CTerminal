# CTerminal

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE.md)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows-lightgrey.svg)](#系统要求)

CTerminal 是一款跨平台桌面终端，不基于 Electron：界面用 Flutter 自绘，终端内核、连接和配置全部由 Rust 实现，两者通过 flutter_rust_bridge 连接。

> 早期版本。macOS 已可日常使用；Windows 版尚未经过真机测试。暂未提供签名和公证的安装包。

## 功能

**终端**
- 基于 alacritty_terminal 的 VT 解析：256 色 / 真彩色、粗斜体下划线删除线、备用屏幕、同步更新、OSC 52 复制、标题
- 中文等宽字符对齐、表情符号、制表符与方块字符自绘（TUI 边框无缝）
- 选区（单击拖动 / 双击单词 / 三击整行 / Alt 块选）、选中即复制、中键粘贴、括号粘贴、多行粘贴确认
- 拖文件到终端粘贴路径（Windows 上按 WSL / Git-Bash 等翻译写法）
- 搜索（大小写 / 正则 / 全词），滚动回看与滚动条，⌘ / Ctrl 点击打开链接
- 输入法：拼音等组合输入在光标处显示，候选框跟随光标
- 鼠标上报（vim / htop / tmux 可用鼠标），Option 作 Meta 可选

**标签页与分屏**
- 标签栏融入标题栏，拖动排序、重命名、彩标、复制、关闭其他 / 左侧 / 右侧
- 任意嵌套的横竖分屏、拖动调整比例、方向键切换窗格、窗格最大化
- 拆分标签页为独立标签 / 合并所有标签页、同时输入到所有窗格
- 重新打开关闭的标签页、重启后恢复标签页与分屏布局（本地 shell 会回到原来的目录）

**配置和连接**
- 本地 shell 自动探测（macOS 读 /etc/shells；Windows 探测 CMD、PowerShell、pwsh、Git-Bash、MSYS2、Cygwin、WSL）
- SSH：密码 / 私钥（含加密私钥）/ ssh-agent / 键盘交互、known_hosts 校验与密钥变更警告、跳板机、本地 / 远程 / 动态（SOCKS5）端口转发、agent 转发、保活、登录脚本
- SFTP 文件面板：浏览、拖入上传（含文件夹）、双击下载、重命名、新建文件夹、删除
- 自动导入 `~/.ssh/config` 中的主机
- Telnet、串口（波特率 / 数据位 / 校验 / 流控 / 换行 / 本地回显）
- 配置选择器：分组、筛选、最近使用，输入 `user@host:port` 直接快速连接
- 会话结束时的行为：正常退出关闭、出错保留、自动重连

**界面语言**：简体中文 / English，默认跟随系统

**设置**（以标签页打开）
- 应用、外观（主题、标签栏位置、透明度、缩放、字体）、配色方案（10 套内置 + 自定义编辑器）、终端、配置和连接、快捷键（全部可改）、SSH、凭据、配置文件

## 系统要求

- macOS 12+ 或 Windows 10 1809+（ConPTY 最低要求）
- 从源码构建需要：
  - [Flutter](https://docs.flutter.dev/get-started/install) 3.x（Dart 3.13+）
  - [Rust](https://www.rust-lang.org/tools/install) 1.95+
  - macOS：Xcode 15+、CocoaPods（`brew install cocoapods`）
  - Windows：Visual Studio 2022（“使用 C++ 的桌面开发”）

## 从源码运行

```bash
git clone https://github.com/Ckales/CTerminal.git
cd CTerminal/app
flutter pub get
flutter run -d macos      # Windows 上用 -d windows
```

首次运行要编译 Rust 依赖，会比较慢。

## 构建

```bash
cd app
flutter build macos --release   # 产物：build/macos/Build/Products/Release/CTerminal.app
flutter build windows --release # 产物：build/windows/x64/runner/Release/
```

## 命令行

支持以下子命令：

```bash
CTerminal open ~/project                 # 在目录中打开默认配置
CTerminal run htop                       # 在新标签页运行命令
CTerminal profile "生产数据库"            # 按名称打开配置
CTerminal quickConnect deploy@192.0.2.10 # 快速 SSH 连接
CTerminal settings appearance            # 打开设置
```

macOS 上通过 `open -a CTerminal --args run htop` 调用。

## 常用快捷键（macOS）

| 快捷键 | 操作 |
| --- | --- |
| `⌘T` / `⌘W` / `⌘⇧T` | 新建 / 关闭 / 重新打开标签页 |
| `⌘1`…`⌘9`、`⌃Tab` | 切换标签页 |
| `⌘⇧D` / `⌘D` | 向右 / 向下拆分 |
| `⌘⌥←→↑↓` | 切换窗格 |
| `⌘⌥↩` | 最大化窗格 |
| `⌘E` | 选择配置（可快速连接） |
| `⌘⇧P` | 命令面板 |
| `⌘F` | 搜索 |
| `⌘C` / `⌘V` / `⌘K` | 复制 / 粘贴 / 清屏 |
| `⌘,` | 设置 |

Windows 上 `⌘` 对应 `Ctrl+Shift`。全部快捷键可在“设置 → 快捷键”修改。

## 配置与隐私

- 配置文件：macOS `~/Library/Application Support/CTerminal/config.json`，Windows `%APPDATA%\CTerminal\config.json`
- SSH 密码、私钥口令只保存在系统钥匙串（macOS 钥匙串 / Windows 凭据管理器），不写进配置文件，界面层也读不回来
- 首次连接 SSH 主机会显示指纹请你确认，确认后写入 `~/.ssh/known_hosts`；主机密钥变化时会警告并默认拒绝

## 开发

```bash
sh app/tool/test.sh   # Rust 核心测试 + Dart 测试 + 真实内核驱动的界面测试
cd app && flutter analyze
```

```text
crates/cterm-core/   终端引擎、连接（本地 / SSH / Telnet / 串口）、配置、凭据，零 UI 依赖
app/rust/            flutter_rust_bridge 薄包装
app/lib/             Flutter 界面
app/test/            Dart 测试
```

## 参与贡献

欢迎提交 Issue 和 Pull Request。提交前请确保 `sh app/tool/test.sh` 与 `flutter analyze` 通过；测试数据请使用 `example.com`、`192.0.2.x` 这类文档保留地址。

## 致谢

终端内核 [alacritty_terminal](https://github.com/alacritty/alacritty)，SSH [russh](https://github.com/Eugeny/russh)，PTY [portable-pty](https://github.com/wezterm/wezterm)。

## 许可证

[MIT](LICENSE.md)
