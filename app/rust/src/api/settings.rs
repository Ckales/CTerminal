//! 配置、profile、凭据的桥接。配置以 JSON 往返：结构、默认值、迁移只在 cterm-core 定义一份。

use std::sync::{LazyLock, Mutex};

use cterm_core::config::{self, Config, Profile, ProfileKind};
use cterm_core::{log, paths, schemes, secrets, serial, shells};
use flutter_rust_bridge::frb;

static CONFIG: LazyLock<Mutex<Option<Config>>> = LazyLock::new(|| Mutex::new(None));

pub(crate) fn current_config() -> Config {
    let mut cached = CONFIG.lock().unwrap();
    if let Some(config) = cached.as_ref() {
        return config.clone();
    }
    log::init();
    let config = config::load().unwrap_or_else(|err| {
        log::error(&format!("读取配置失败，本次使用默认设置：{err}"));
        Config::default()
    });
    *cached = Some(config.clone());
    config
}

fn to_json<T: serde::Serialize>(value: &T) -> String {
    serde_json::to_string(value).expect("config types always serialize")
}

/// 读取配置（缺失字段已补默认值）。文件损坏时返回错误，不静默覆盖用户的文件。
pub fn config_load() -> Result<String, String> {
    // 启动时第一个调用，顺带初始化日志
    log::init();
    let config = config::load().inspect_err(|err| log::error(&format!("读取配置失败：{err}")))?;
    *CONFIG.lock().unwrap() = Some(config.clone());
    Ok(to_json(&config))
}

/// 校验并保存，返回规范化后的配置
pub fn config_save(json: String) -> Result<String, String> {
    let config = config::parse(&json).inspect_err(|err| log::error(&format!("保存配置失败：{err}")))?;
    config::save(&config).inspect_err(|err| log::error(&format!("保存配置失败：{err}")))?;
    *CONFIG.lock().unwrap() = Some(config.clone());
    Ok(to_json(&config))
}

#[frb(sync)]
pub fn config_defaults() -> String {
    to_json(&Config::default())
}

#[frb(sync)]
pub fn config_file_path() -> String {
    config::config_path().display().to_string()
}

/// 内置（本地 shell、~/.ssh/config）+ 用户 profile
pub fn profiles_list() -> String {
    to_json(&config::all_profiles(&current_config()))
}

pub fn default_profile() -> String {
    to_json(&config::default_profile(&current_config()))
}

#[frb(sync)]
pub fn color_schemes() -> String {
    to_json(&schemes::all(&current_config()))
}

pub fn serial_ports() -> Vec<String> {
    serial::list_ports()
}

/// kind: password / passphrase:<私钥路径>
pub fn secret_set(kind: String, profile_id: String, value: String) -> Result<(), String> {
    secrets::set(&secrets::key(&kind, &profile_id), &value)
}

pub fn secret_exists(kind: String, profile_id: String) -> bool {
    secrets::exists(&secrets::key(&kind, &profile_id))
}

pub fn secret_delete(kind: String, profile_id: String) -> Result<(), String> {
    secrets::delete(&secrets::key(&kind, &profile_id))
}

/// 拖文件进终端：按目标 shell 翻译路径并转义
#[frb(sync)]
pub fn shell_path(path: String, profile_json: String) -> String {
    let style = match serde_json::from_str::<Profile>(&profile_json) {
        Ok(profile) if matches!(profile.kind, ProfileKind::Local(_)) => {
            shells::path_style_of(profile.id.strip_prefix("local:").unwrap_or_default())
        }
        _ => paths::PathStyle::Native,
    };
    paths::quote_for_shell(&paths::to_shell(&path, style), style)
}

fn state_path() -> std::path::PathBuf {
    paths::config_dir().join("state.json")
}

/// 窗口 / 标签页状态（恢复标签页用），内容由界面层定义
pub fn state_load() -> String {
    std::fs::read_to_string(state_path()).unwrap_or_default()
}

pub fn state_save(json: String) -> Result<(), String> {
    let path = state_path();
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|err| err.to_string())?;
    }
    let temp = path.with_extension("json.tmp");
    std::fs::write(&temp, json).map_err(|err| err.to_string())?;
    std::fs::rename(&temp, &path).map_err(|err| err.to_string())
}

/// 界面语言变化时同步给 Rust（SSH 提示、连接错误等在终端里显示的文字）；code: zh / en
#[frb(sync)]
pub fn set_language(code: String) {
    cterm_core::i18n::set_language(&code);
}
