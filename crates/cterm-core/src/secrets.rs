//! 凭据：只存系统钥匙串（macOS Keychain / Windows 凭据管理器）。
//! 读取接口不暴露给界面层：界面只能写入、查询是否存在、删除。

const SERVICE: &str = "CTerminal";

/// 凭据键：`<kind>:<profile id>`，kind 如 password / passphrase:<私钥路径>
pub fn key(kind: &str, profile_id: &str) -> String {
    format!("{kind}:{profile_id}")
}

fn entry(key: &str) -> Result<keyring::Entry, String> {
    keyring::Entry::new(SERVICE, key).map_err(|err| trf!("无法访问系统钥匙串：{err}", err = err))
}

pub fn set(key: &str, value: &str) -> Result<(), String> {
    entry(key)?.set_password(value).map_err(|err| trf!("保存到钥匙串失败：{err}", err = err))
}

/// 仅供 Rust 内部连接时使用
pub(crate) fn get(key: &str) -> Option<String> {
    entry(key).ok()?.get_password().ok()
}

pub fn exists(key: &str) -> bool {
    get(key).is_some()
}

pub fn delete(key: &str) -> Result<(), String> {
    match entry(key)?.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(err) => Err(trf!("从钥匙串删除失败：{err}", err = err)),
    }
}
