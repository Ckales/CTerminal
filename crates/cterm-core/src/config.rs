//! 配置：结构、默认值、版本迁移、读写。配置里不存任何秘密（密码进系统钥匙串，见 secrets.rs）。

use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::frame::Palette;
use crate::local::LocalOptions;
use crate::shells;

pub const CONFIG_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Config {
    pub version: u32,
    pub profiles: Vec<Profile>,
    pub groups: Vec<ProfileGroup>,
    pub hotkeys: BTreeMap<String, Vec<String>>,
    pub terminal: TerminalSettings,
    pub appearance: AppearanceSettings,
    pub application: ApplicationSettings,
    pub ssh: SshSettings,
    pub custom_color_schemes: Vec<ColorScheme>,
    /// 最近使用的 profile id，选择器里排在前面
    pub recent_profiles: Vec<String>,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            version: CONFIG_VERSION,
            profiles: Vec::new(),
            groups: Vec::new(),
            hotkeys: default_hotkeys(),
            terminal: TerminalSettings::default(),
            appearance: AppearanceSettings::default(),
            application: ApplicationSettings::default(),
            ssh: SshSettings::default(),
            custom_color_schemes: Vec::new(),
            recent_profiles: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Profile {
    pub id: String,
    pub name: String,
    /// 分组 id，空 = 未分组
    pub group: String,
    pub icon: String,
    /// 标签彩标，如 "#ff615a"，空 = 无
    pub color: String,
    /// 内置 profile（探测出的本地 shell）不写入配置文件
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub is_builtin: bool,
    /// 忽略程序设置的窗口标题，Tab 始终显示 profile 名
    pub disable_dynamic_title: bool,
    /// auto / keep / reconnect / close
    pub behavior_on_session_end: String,
    #[serde(flatten)]
    pub kind: ProfileKind,
}

impl Default for Profile {
    fn default() -> Self {
        Profile {
            id: String::new(),
            name: String::new(),
            group: String::new(),
            icon: String::new(),
            color: String::new(),
            is_builtin: false,
            disable_dynamic_title: false,
            behavior_on_session_end: "auto".into(),
            kind: ProfileKind::Local(LocalOptions::default()),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", content = "options", rename_all = "camelCase")]
pub enum ProfileKind {
    Local(LocalOptions),
    Ssh(SshOptions),
    Telnet(TelnetOptions),
    Serial(SerialOptions),
}

impl ProfileKind {
    pub fn type_name(&self) -> &'static str {
        match self {
            ProfileKind::Local(_) => "local",
            ProfileKind::Ssh(_) => "ssh",
            ProfileKind::Telnet(_) => "telnet",
            ProfileKind::Serial(_) => "serial",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct SshOptions {
    pub host: String,
    pub port: u16,
    pub user: String,
    /// auto / password / publicKey / agent / keyboardInteractive
    pub auth: String,
    /// 私钥文件路径；口令存钥匙串
    pub private_keys: Vec<String>,
    /// 跳板机：另一个 SSH profile 的 id
    pub jump_host: String,
    /// 经由此命令的 stdin/stdout 连接（%h %p %r %%）；同时配置了跳板机时以跳板机为准
    pub proxy_command: String,
    pub forwarded_ports: Vec<ForwardedPort>,
    pub keepalive_interval: u32,
    pub keepalive_count_max: u32,
    pub agent_forward: bool,
    /// 连接后自动执行的命令
    pub login_scripts: Vec<LoginScript>,
    pub ready_timeout: u32,
}

impl Default for SshOptions {
    fn default() -> Self {
        SshOptions {
            host: String::new(),
            port: 22,
            user: String::new(),
            auth: "auto".into(),
            private_keys: Vec::new(),
            jump_host: String::new(),
            proxy_command: String::new(),
            forwarded_ports: Vec::new(),
            keepalive_interval: 30,
            keepalive_count_max: 3,
            agent_forward: false,
            login_scripts: Vec::new(),
            ready_timeout: 20,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct ForwardedPort {
    /// local / remote / dynamic
    #[serde(rename = "type")]
    pub kind: String,
    pub host: String,
    pub port: u16,
    pub target_address: String,
    pub target_port: u16,
    pub description: String,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct LoginScript {
    /// 等待出现的文本，空 = 立即发送
    pub expect: String,
    pub send: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct TelnetOptions {
    pub host: String,
    pub port: u16,
}

impl Default for TelnetOptions {
    fn default() -> Self {
        TelnetOptions { host: String::new(), port: 23 }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct SerialOptions {
    pub port: String,
    pub baudrate: u32,
    pub databits: u8,
    pub stopbits: u8,
    /// none / odd / even
    pub parity: String,
    /// none / software / hardware
    pub flowcontrol: String,
    /// 回车发送：cr / lf / crlf
    pub output_newlines: String,
    /// 本地回显
    pub local_echo: bool,
}

impl Default for SerialOptions {
    fn default() -> Self {
        SerialOptions {
            port: String::new(),
            baudrate: 115200,
            databits: 8,
            stopbits: 1,
            parity: "none".into(),
            flowcontrol: "none".into(),
            output_newlines: "cr".into(),
            local_echo: false,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct ProfileGroup {
    pub id: String,
    pub name: String,
    pub collapsed: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct TerminalSettings {
    pub font: String,
    pub font_size: f64,
    pub line_height: f64,
    /// block / underline / beam
    pub cursor: String,
    pub cursor_blink: bool,
    pub scrollback_lines: u32,
    pub color_scheme: String,
    pub bold_is_bright: bool,
    pub copy_on_select: bool,
    /// menu / paste / clipboard（有选区时复制，否则粘贴）
    pub right_click: String,
    pub paste_on_middle_click: bool,
    /// off / visual / audible
    pub bell: String,
    /// macOS 上把 Option 当 Meta
    pub alt_is_meta: bool,
    pub warn_on_multiline_paste: bool,
    pub scroll_on_input: bool,
    pub word_separators: String,
    pub padding: f64,
    /// 字体连字（liga / calt），默认关
    pub ligatures: bool,
}

impl Default for TerminalSettings {
    fn default() -> Self {
        TerminalSettings {
            font: default_font().into(),
            font_size: 14.0,
            line_height: 1.2,
            cursor: "block".into(),
            cursor_blink: true,
            scrollback_lines: 25000,
            color_scheme: "CTerminal Default".into(),
            bold_is_bright: true,
            copy_on_select: false,
            right_click: "menu".into(),
            paste_on_middle_click: true,
            bell: "off".into(),
            alt_is_meta: false,
            warn_on_multiline_paste: true,
            scroll_on_input: true,
            word_separators: ",│`|:\"' ()[]{}<>\t".into(),
            padding: 8.0,
            ligatures: false,
        }
    }
}

fn default_font() -> &'static str {
    if cfg!(windows) {
        "Consolas"
    } else {
        "Menlo"
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct AppearanceSettings {
    /// dark / light / system
    pub theme: String,
    /// top / bottom / left / right
    pub tabs_location: String,
    /// 标签等宽铺满（false = 按内容宽度）
    pub flexible_tabs: bool,
    pub opacity: f64,
    pub show_tab_profile_icon: bool,
    pub show_tab_close_button: bool,
    /// 界面缩放
    pub zoom: f64,
}

impl Default for AppearanceSettings {
    fn default() -> Self {
        AppearanceSettings {
            theme: "dark".into(),
            tabs_location: "top".into(),
            flexible_tabs: false,
            opacity: 1.0,
            show_tab_profile_icon: true,
            show_tab_close_button: true,
            zoom: 1.0,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct ApplicationSettings {
    /// system / zh-CN / en
    pub language: String,
    /// 重启后恢复上次的标签页
    pub restore_tabs: bool,
    /// 新建标签页默认 profile id，空 = 系统默认 shell
    pub default_profile: String,
    pub enable_welcome_tab: bool,
    /// 关闭窗口 / 有运行中会话时确认
    pub confirm_on_close: bool,
    /// 启动时检查新版本（每天最多一次）
    pub check_for_updates: bool,
}

impl Default for ApplicationSettings {
    fn default() -> Self {
        ApplicationSettings {
            language: "system".into(),
            restore_tabs: true,
            default_profile: String::new(),
            enable_welcome_tab: true,
            confirm_on_close: true,
            check_for_updates: true,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct SshSettings {
    /// 连接前是否检查 known_hosts
    pub verify_host_keys: bool,
    pub known_hosts_file: String,
    /// 使用系统 ssh-agent（SSH_AUTH_SOCK / Windows OpenSSH agent）
    pub use_agent: bool,
}

impl Default for SshSettings {
    fn default() -> Self {
        SshSettings { verify_host_keys: true, known_hosts_file: String::new(), use_agent: true }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ColorScheme {
    pub name: String,
    pub foreground: String,
    pub background: String,
    pub cursor: String,
    pub colors: Vec<String>,
}

impl ColorScheme {
    pub fn to_palette(&self) -> Option<Palette> {
        let mut ansi = [0u32; 16];
        if self.colors.len() != 16 {
            return None;
        }
        for (index, color) in self.colors.iter().enumerate() {
            ansi[index] = parse_hex(color)?;
        }
        Some(Palette {
            foreground: parse_hex(&self.foreground)?,
            background: parse_hex(&self.background)?,
            cursor: parse_hex(&self.cursor)?,
            ansi,
        })
    }
}

pub fn parse_hex(color: &str) -> Option<u32> {
    let hex = color.strip_prefix('#')?;
    // from_str_radix 接受前导 '+'，"#+12345" 不能算合法颜色
    if hex.len() != 6 || !hex.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return None;
    }
    u32::from_str_radix(hex, 16).ok()
}

/// 快捷键默认值：macOS 用 ⌘，Windows 用 Ctrl
pub fn default_hotkeys() -> BTreeMap<String, Vec<String>> {
    let mac = cfg!(target_os = "macos");
    let cmd = if mac { "⌘" } else { "Ctrl-Shift" };
    let alt = if mac { "⌥" } else { "Alt" };
    let pairs: Vec<(&str, Vec<String>)> = vec![
        ("copy", vec![format!("{cmd}-C")]),
        ("paste", vec![format!("{cmd}-V")]),
        ("clear", vec![if mac { "⌘-K".into() } else { String::new() }]),
        ("select-all", vec![format!("{cmd}-A")]),
        ("zoom-in", vec![if mac { "⌘-=".into() } else { "Ctrl-=".into() }]),
        ("zoom-out", vec![if mac { "⌘--".into() } else { "Ctrl--".into() }]),
        ("reset-zoom", vec![if mac { "⌘-0".into() } else { "Ctrl-0".into() }]),
        ("home", vec![if mac { "⌘-Left".into() } else { String::new() }]),
        ("end", vec![if mac { "⌘-Right".into() } else { String::new() }]),
        ("previous-word", vec![if mac { "⌥-Left".into() } else { "Ctrl-Left".into() }]),
        ("next-word", vec![if mac { "⌥-Right".into() } else { "Ctrl-Right".into() }]),
        ("delete-previous-word", vec![if mac { "⌥-Backspace".into() } else { "Ctrl-Backspace".into() }]),
        ("delete-line", vec![if mac { "⌘-Backspace".into() } else { String::new() }]),
        ("delete-next-word", vec![if mac { "⌥-Delete".into() } else { "Ctrl-Delete".into() }]),
        ("search", vec![format!("{cmd}-F")]),
        ("pane-focus-all", vec![if mac { "⌘-Shift-I".into() } else { "Ctrl-Shift-I".into() }]),
        ("focus-all-tabs", vec![if mac { "⌘-⌥-Shift-I".into() } else { "Ctrl-Alt-Shift-I".into() }]),
        ("copy-current-path", vec![]),
        // 有选区时复制，否则发 ^C；默认不绑定，免得 Ctrl-C 行为出乎意料
        ("ctrl-c", vec![]),
        ("scroll-to-top", vec!["Shift-PageUp".into()]),
        ("scroll-page-up", vec![format!("{alt}-PageUp")]),
        ("scroll-up", vec!["Ctrl-Shift-Up".into()]),
        ("scroll-down", vec!["Ctrl-Shift-Down".into()]),
        ("scroll-page-down", vec![format!("{alt}-PageDown")]),
        ("scroll-to-bottom", vec!["Shift-PageDown".into()]),
        ("settings", vec![if mac { "⌘-,".into() } else { "Ctrl-,".into() }]),
        ("new-tab", vec![format!("{cmd}-T")]),
        ("new-window", vec![format!("{cmd}-N")]),
        ("toggle-fullscreen", vec![if mac { "Ctrl-⌘-F".into() } else { "F11".into() }]),
        ("close-tab", vec![format!("{cmd}-W")]),
        ("reopen-tab", vec![if mac { "⌘-Shift-T".into() } else { "Ctrl-Shift-Alt-T".into() }]),
        ("rename-tab", vec![format!("{cmd}-R")]),
        ("next-tab", vec!["Ctrl-Tab".into()]),
        ("previous-tab", vec!["Ctrl-Shift-Tab".into()]),
        ("move-tab-left", vec![if mac { "⌘-Shift-Left".into() } else { "Ctrl-Shift-PageUp".into() }]),
        ("move-tab-right", vec![if mac { "⌘-Shift-Right".into() } else { "Ctrl-Shift-PageDown".into() }]),
        ("duplicate-tab", vec![]),
        ("restart-tab", vec![]),
        ("restart-ssh-session", vec![]),
        ("restart-telnet-session", vec![]),
        ("restart-serial-session", vec![]),
        ("toggle-last-tab", vec![]),
        ("pin-tab", vec![]),
        ("reconnect-tab", vec![]),
        ("disconnect-tab", vec![]),
        ("open-sftp", vec![]),
        // 全局显示 / 隐藏窗口。Ctrl-Space 在 macOS 上是切换输入法，默认不绑定
        ("toggle-window", vec![]),
        ("explode-tab", vec![if mac { "⌘-Shift-.".into() } else { "Ctrl-Shift-.".into() }]),
        ("combine-tabs", vec![if mac { "⌘-Shift-,".into() } else { "Ctrl-Shift-,".into() }]),
        ("split-right", vec![if mac { "⌘-Shift-D".into() } else { "Ctrl-Shift-D".into() }]),
        ("split-bottom", vec![if mac { "⌘-D".into() } else { "Ctrl-Shift-E".into() }]),
        ("split-left", vec![]),
        ("split-top", vec![]),
        ("pane-nav-right", vec![format!("{cmd}-{alt}-Right")]),
        ("pane-nav-down", vec![format!("{cmd}-{alt}-Down")]),
        ("pane-nav-up", vec![format!("{cmd}-{alt}-Up")]),
        ("pane-nav-left", vec![format!("{cmd}-{alt}-Left")]),
        ("pane-nav-previous", vec![format!("{cmd}-{alt}-[")]),
        ("pane-nav-next", vec![format!("{cmd}-{alt}-]")]),
        ("pane-maximize", vec![format!("{cmd}-{alt}-Enter")]),
        ("close-pane", vec![if mac { "⌘-Shift-W".into() } else { "Ctrl-Shift-Alt-W".into() }]),
        ("pane-increase-vertical", vec![]),
        ("pane-decrease-vertical", vec![]),
        ("pane-increase-horizontal", vec![]),
        ("pane-decrease-horizontal", vec![]),
        ("profile-selector", vec![format!("{cmd}-E")]),
        ("switch-profile", vec![if mac { "⌘-Shift-E".into() } else { "Ctrl-Shift-Alt-E".into() }]),
        ("command-selector", vec![if mac { "⌘-Shift-P".into() } else { "Ctrl-Shift-P".into() }]),
        ("serial", vec![format!("{alt}-K")]),
    ];
    let mut hotkeys = BTreeMap::new();
    for (action, keys) in pairs {
        let keys: Vec<String> = keys.into_iter().filter(|key| !key.is_empty()).collect();
        hotkeys.insert(action.to_string(), keys);
    }
    for index in 1..=9 {
        let key = if mac { format!("⌘-{index}") } else { format!("Alt-{index}") };
        hotkeys.insert(format!("tab-{index}"), vec![key]);
        hotkeys.insert(format!("pane-nav-{index}"), vec![]);
    }
    for index in 10..=20 {
        hotkeys.insert(format!("tab-{index}"), vec![]);
    }
    hotkeys
}

/// 按版本逐级迁移原始 JSON。新增版本时在这里加一个分支，旧分支永远保留。
pub fn migrate(mut value: Value) -> Value {
    // 根节点不是对象（文件损坏成数组 / 字符串）时不迁移，交给反序列化报错；否则下面的索引赋值会 panic
    if !value.is_object() {
        return value;
    }
    let version = value.get("version").and_then(Value::as_u64).unwrap_or(0);
    if version < 1 {
        // v0：尚未发布过的草稿格式，没有字段需要改名，只补版本号
        value["version"] = Value::from(1);
    }
    value
}

/// 解析配置：迁移 → 反序列化 → 补新增的默认快捷键
pub fn parse(json: &str) -> Result<Config, String> {
    let raw: Value = serde_json::from_str(json).map_err(|err| trf!("配置文件格式错误：{err}", err = err))?;
    // serde 的结构体也接受数组形式，"[]" 会被悄悄当成默认配置，必须显式拒绝
    if !raw.is_object() {
        return Err(trf!("配置文件内容错误：{err}", err = "expected a JSON object"));
    }
    let migrated = migrate(raw);
    // 更新版本写的配置：旧版本读进来再保存会丢掉不认识的字段，直接拒绝
    let version = migrated.get("version").and_then(Value::as_u64).unwrap_or(0);
    if version > CONFIG_VERSION as u64 {
        return Err(trf!("配置文件由更新版本的 CTerminal 创建（配置版本 {version}），请升级后再打开", version = version));
    }
    let mut config: Config = serde_json::from_value(migrated).map_err(|err| trf!("配置文件内容错误：{err}", err = err))?;
    for (action, keys) in default_hotkeys() {
        config.hotkeys.entry(action).or_insert(keys);
    }
    config.version = CONFIG_VERSION;
    Ok(config)
}

pub fn config_path() -> PathBuf {
    crate::paths::config_dir().join("config.json")
}

pub fn load_from(path: &Path) -> Result<Config, String> {
    match fs::read_to_string(path) {
        Ok(json) => parse(&json),
        Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(Config::default()),
        Err(err) => Err(trf!("读取配置失败：{err}", err = err)),
    }
}

/// 先写临时文件再改名，写到一半崩溃也不会留下半个配置
pub fn save_to(path: &Path, config: &Config) -> Result<(), String> {
    let mut stored = config.clone();
    stored.profiles.retain(|profile| !profile.is_builtin);
    let json = serde_json::to_string_pretty(&stored).map_err(|err| err.to_string())?;
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|err| trf!("创建配置目录失败：{err}", err = err))?;
    }
    // 原文件读不出来时（损坏、更新版本写的）界面用默认值运行，这里第一次保存前先把原文件留一份
    if path.exists() && load_from(path).is_err() {
        let seconds = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|elapsed| elapsed.as_secs()).unwrap_or(0);
        let backup = path.with_file_name(format!("config.broken-{seconds}.json"));
        fs::rename(path, &backup).map_err(|err| trf!("备份原配置文件失败：{err}", err = err))?;
        crate::log::warn(&format!("原配置文件无法读取，已备份为 {}", backup.display()));
    }
    let temp = path.with_extension("json.tmp");
    fs::write(&temp, json).map_err(|err| trf!("写入配置失败：{err}", err = err))?;
    fs::rename(&temp, path).map_err(|err| trf!("写入配置失败：{err}", err = err))
}

pub fn load() -> Result<Config, String> {
    load_from(&config_path())
}

pub fn save(config: &Config) -> Result<(), String> {
    save_to(&config_path(), config)
}

/// 探测出的本地 shell，作为内置 profile
pub fn builtin_profiles() -> Vec<Profile> {
    let mut profiles = Vec::new();
    for shell in shells::detect() {
        profiles.push(Profile {
            id: format!("local:{}", shell.id),
            name: shell.name.clone(),
            icon: shell.icon.clone(),
            is_builtin: true,
            kind: ProfileKind::Local(LocalOptions {
                command: shell.command,
                args: shell.args,
                cwd: String::new(),
                env: Vec::new(),
            }),
            ..Default::default()
        });
    }
    profiles
}

/// 内置（本地 shell + ~/.ssh/config）+ 用户 profile
pub fn all_profiles(config: &Config) -> Vec<Profile> {
    let mut profiles = builtin_profiles();
    profiles.extend(crate::ssh_config::import());
    profiles.extend(config.profiles.iter().cloned());
    profiles
}

/// 默认 profile：配置指定的 → 系统默认 shell
pub fn default_profile(config: &Config) -> Profile {
    let profiles = all_profiles(config);
    if let Some(found) = profiles.iter().find(|profile| profile.id == config.application.default_profile) {
        return found.clone();
    }
    let shell = shells::default_shell();
    let id = format!("local:{}", shell.id);
    if let Some(found) = profiles.into_iter().find(|profile| profile.id == id) {
        return found;
    }
    Profile {
        id,
        name: shell.name,
        is_builtin: true,
        kind: ProfileKind::Local(LocalOptions { command: shell.command, args: shell.args, ..Default::default() }),
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn profile_hotkeys_and_ligatures_survive_round_trip() {
        let config = parse(r#"{"version":1,"hotkeys":{"profile:p1":["⌘-Shift-1"]},"terminal":{"ligatures":true}}"#).unwrap();
        assert_eq!(config.hotkeys["profile:p1"], ["⌘-Shift-1"]);
        assert!(config.terminal.ligatures);
        assert!(!TerminalSettings::default().ligatures);
        let defaults = default_hotkeys();
        for action in ["ctrl-c", "copy-current-path", "focus-all-tabs", "pane-nav-9", "tab-20", "toggle-last-tab", "pin-tab", "restart-serial-session"] {
            assert!(defaults.contains_key(action), "缺少默认快捷键条目 {action}");
        }
        assert!(defaults["ctrl-c"].is_empty());
    }

    #[test]
    fn profile_round_trip_uses_type_and_options() {
        let profile = Profile {
            id: "p1".into(),
            name: "db".into(),
            kind: ProfileKind::Ssh(SshOptions { host: "192.0.2.10".into(), user: "deploy".into(), ..Default::default() }),
            ..Default::default()
        };
        let json = serde_json::to_value(&profile).unwrap();
        assert_eq!(json["type"], "ssh");
        assert_eq!(json["options"]["host"], "192.0.2.10");
        assert_eq!(json["options"]["port"], 22);
        let back: Profile = serde_json::from_value(json).unwrap();
        assert_eq!(back, profile);
    }

    #[test]
    fn missing_fields_take_defaults_and_new_hotkeys_are_added() {
        let config = parse(r#"{"version":1,"hotkeys":{"copy":["⌘-X"]},"terminal":{"fontSize":20}}"#).unwrap();
        assert_eq!(config.terminal.font_size, 20.0);
        assert_eq!(config.terminal.scrollback_lines, 25000);
        assert_eq!(config.hotkeys["copy"], ["⌘-X"]);
        assert!(config.hotkeys.contains_key("split-right"));
    }

    #[test]
    fn migrate_from_unversioned() {
        let config = parse("{}").unwrap();
        assert_eq!(config.version, CONFIG_VERSION);
    }

    #[test]
    fn save_skips_builtin_and_is_atomic() {
        let dir = std::env::temp_dir().join(format!("cterm-config-{}", std::process::id()));
        let path = dir.join("config.json");
        let mut config = Config::default();
        config.profiles.push(Profile { id: "local:zsh".into(), is_builtin: true, ..Default::default() });
        config.profiles.push(Profile { id: "mine".into(), name: "mine".into(), ..Default::default() });
        save_to(&path, &config).unwrap();
        let loaded = load_from(&path).unwrap();
        assert_eq!(loaded.profiles.len(), 1);
        assert_eq!(loaded.profiles[0].id, "mine");
        assert!(!path.with_extension("json.tmp").exists());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn newer_config_is_rejected_and_backed_up_before_overwrite() {
        let json = r#"{"version":99,"futureField":{"keep":true}}"#;
        assert!(parse(json).unwrap_err().contains("99"));
        let dir = std::env::temp_dir().join(format!("cterm-config-newer-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("config.json");
        fs::write(&path, json).unwrap();
        save_to(&path, &Config::default()).unwrap();
        let backups: Vec<_> = fs::read_dir(&dir)
            .unwrap()
            .flatten()
            .filter(|entry| entry.file_name().to_string_lossy().starts_with("config.broken-"))
            .collect();
        assert_eq!(backups.len(), 1);
        assert_eq!(fs::read_to_string(backups[0].path()).unwrap(), json);
        assert!(load_from(&path).is_ok());
        // 原文件正常时不备份
        save_to(&path, &Config::default()).unwrap();
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 2);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn config_never_contains_secret_fields() {
        // 秘密只进钥匙串：配置结构里不允许出现这些字段名，防止以后被“简化”回明文
        let mut config = Config::default();
        config.profiles.push(Profile { kind: ProfileKind::Ssh(SshOptions::default()), ..Default::default() });
        let json = serde_json::to_string(&config).unwrap().to_lowercase();
        for forbidden in ["password", "passphrase", "secret", "token"] {
            assert!(!json.contains(forbidden), "config contains {forbidden}");
        }
    }

    #[test]
    fn color_scheme_parses() {
        let scheme = ColorScheme {
            name: "x".into(),
            foreground: "#cacaca".into(),
            background: "#171717".into(),
            cursor: "#bbbbbb".into(),
            colors: Palette::default().ansi.iter().map(|color| format!("#{color:06x}")).collect(),
        };
        assert_eq!(scheme.to_palette().unwrap(), Palette::default());
    }

    #[test]
    fn broken_json_is_an_error_not_a_panic() {
        assert!(parse("{").is_err());
        assert!(parse("").is_err());
        // 根节点不是对象：以前 migrate 里的 value["version"] 会直接 panic，"[]" 还会被当成默认配置
        for root in ["[]", "\"x\"", "3", "true"] {
            assert!(parse(root).is_err(), "{root}");
        }
        assert!(parse(r#"{"terminal":{"fontSize":"big"}}"#).is_err());
    }

    #[test]
    fn unknown_fields_are_ignored() {
        let config = parse(r#"{"version":1,"futureThing":1,"terminal":{"unknownKey":true,"cursor":"beam"}}"#).unwrap();
        assert_eq!(config.terminal.cursor, "beam");
    }

    #[test]
    fn old_or_odd_version_values_are_migrated() {
        for json in [r#"{"version":0}"#, r#"{"version":"1"}"#, r#"{"version":null}"#] {
            assert_eq!(parse(json).unwrap().version, CONFIG_VERSION, "{json}");
        }
    }

    #[test]
    fn user_unbound_hotkey_is_not_restored() {
        // 用户清空的快捷键保持为空，只补配置里完全没有的动作
        let config = parse(r#"{"hotkeys":{"copy":[]}}"#).unwrap();
        assert!(config.hotkeys["copy"].is_empty());
        assert!(!config.hotkeys["paste"].is_empty());
    }

    #[test]
    fn hex_colors_are_strict() {
        assert_eq!(parse_hex("#ABCdef"), Some(0xabcdef));
        assert_eq!(parse_hex("cacaca"), None);
        assert_eq!(parse_hex("#fff"), None);
        assert_eq!(parse_hex("#+12345"), None);
        assert_eq!(parse_hex("#-12345"), None);
        assert_eq!(parse_hex("#cacacaff"), None);
        let mut scheme = crate::schemes::builtin()[0].clone();
        scheme.colors.pop();
        assert!(scheme.to_palette().is_none());
    }

    #[test]
    fn missing_file_loads_defaults() {
        let path = std::env::temp_dir().join(format!("cterm-missing-{}/config.json", std::process::id()));
        assert_eq!(load_from(&path).unwrap(), Config::default());
    }
}
