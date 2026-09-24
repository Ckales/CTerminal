//! 新版本检查：取 GitHub 最新发布，与当前版本做语义化版本比较。
//! 当前版本以本 crate 的 Cargo 版本为准（界面上的版本号也从这里取）。

use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::i18n::tr;
use crate::paths;

pub const CURRENT_VERSION: &str = env!("CARGO_PKG_VERSION");
const LATEST_URL: &str = "https://api.github.com/repos/Ckales/CTerminal/releases/latest";
/// 启动时的自动检查每天最多一次
const CHECK_INTERVAL: u64 = 24 * 60 * 60;

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct UpdateStatus {
    /// 最新发布的 tag，如 v0.2.0；还没有任何发布时为空
    pub latest: String,
    /// 发布页地址
    pub url: String,
    pub newer: bool,
}

/// 上次自动检查的记录，存在配置目录的 update-check.json（state.json 归界面层整体覆盖写，不混用）
#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
struct CheckRecord {
    checked_at: u64,
    latest: String,
    url: String,
}

/// 立即检查（“关于”页的按钮）
pub fn check_now() -> Result<UpdateStatus, String> {
    let (latest, url) = fetch_latest()?;
    save_record(&CheckRecord { checked_at: now(), latest: latest.clone(), url: url.clone() });
    let newer = is_newer(&latest, CURRENT_VERSION);
    Ok(UpdateStatus { latest, url, newer })
}

/// 启动时的后台检查：24 小时内检查过就用上次的结果；有新版才返回。失败静默（下次启动再试）。
pub fn check_daily() -> Option<UpdateStatus> {
    let record = load_record();
    if now().saturating_sub(record.checked_at) < CHECK_INTERVAL {
        // 用缓存的 tag 重新和当前版本比：升级后提示自然消失
        let newer = is_newer(&record.latest, CURRENT_VERSION);
        return newer.then_some(UpdateStatus { latest: record.latest, url: record.url, newer });
    }
    let status = check_now().ok()?;
    status.newer.then_some(status)
}

/// 返回 (tag_name, html_url)；仓库还没有发布时 GitHub 返回 404，视为没有新版本
fn fetch_latest() -> Result<(String, String), String> {
    let config = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(15)))
        .http_status_as_error(false)
        .build();
    let agent: ureq::Agent = config.into();
    let mut response = agent
        .get(LATEST_URL)
        .header("User-Agent", &format!("CTerminal/{CURRENT_VERSION}"))
        .header("Accept", "application/vnd.github+json")
        .call()
        .map_err(|err| crate::trf!("检查更新失败：{err}", err = err))?;
    let status = response.status().as_u16();
    if status == 404 {
        return Ok((String::new(), String::new()));
    }
    if status != 200 {
        return Err(crate::trf!("检查更新失败：{err}", err = format!("HTTP {status}")));
    }
    let body = response.body_mut().read_to_string().map_err(|err| crate::trf!("检查更新失败：{err}", err = err))?;
    parse_release(&body)
}

fn parse_release(body: &str) -> Result<(String, String), String> {
    #[derive(Deserialize)]
    struct Release {
        tag_name: String,
        html_url: String,
    }
    let release: Release = serde_json::from_str(body).map_err(|_| tr("检查更新失败：返回内容无法识别"))?;
    Ok((release.tag_name, release.html_url))
}

/// latest 是否比 current 新。预发布版本（带 -）不提示；无法解析的 tag 视为不新。
pub fn is_newer(latest: &str, current: &str) -> bool {
    let Some((latest_numbers, latest_pre)) = parse_version(latest) else { return false };
    let Some((current_numbers, current_pre)) = parse_version(current) else { return false };
    if latest_pre {
        return false;
    }
    if latest_numbers != current_numbers {
        return latest_numbers > current_numbers;
    }
    // 同号时正式版比预发布版新：0.2.0 > 0.2.0-beta
    current_pre
}

/// "v1.2.3-beta+build" → ([1, 2, 3], 是否预发布)。缺的段按 0 算
fn parse_version(text: &str) -> Option<([u64; 3], bool)> {
    let text = text.trim();
    let text = text.strip_prefix(['v', 'V']).unwrap_or(text);
    let text = text.split('+').next().unwrap_or_default();
    let (core, pre) = match text.split_once('-') {
        Some((core, _)) => (core, true),
        None => (text, false),
    };
    let mut numbers = [0u64; 3];
    let parts: Vec<&str> = core.split('.').collect();
    if parts.is_empty() || parts.len() > 3 {
        return None;
    }
    for (index, part) in parts.iter().enumerate() {
        numbers[index] = part.parse().ok()?;
    }
    Some((numbers, pre))
}

fn record_path() -> PathBuf {
    paths::config_dir().join("update-check.json")
}

fn load_record() -> CheckRecord {
    let Ok(text) = std::fs::read_to_string(record_path()) else { return CheckRecord::default() };
    serde_json::from_str(&text).unwrap_or_default()
}

/// 记录写不进去只影响“每天一次”的节流，不打断检查
fn save_record(record: &CheckRecord) {
    let path = record_path();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let json = serde_json::to_string(record).expect("record always serializes");
    let _ = std::fs::write(path, json);
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_comparison() {
        // v 前缀
        assert!(is_newer("v0.2.0", "0.1.0"));
        assert!(is_newer("V1.0", "0.9.9"));
        // 相等
        assert!(!is_newer("v0.1.0", "0.1.0"));
        assert!(!is_newer("0.1", "0.1.0"));
        // 更旧
        assert!(!is_newer("v0.0.9", "0.1.0"));
        assert!(!is_newer("v0.1.0", "0.10.0"));
        // 数字按数值比，不按字符串
        assert!(is_newer("v0.10.0", "0.9.0"));
        // 预发布版本不提示
        assert!(!is_newer("v0.2.0-beta.1", "0.1.0"));
        // 当前是预发布，同号正式版算新
        assert!(is_newer("v0.2.0", "0.2.0-rc.1"));
        assert!(!is_newer("v0.1.9", "0.2.0-rc.1"));
        // 构建元数据忽略
        assert!(!is_newer("v0.1.0+build.5", "0.1.0"));
        // 无法解析 / 还没有发布
        assert!(!is_newer("nightly", "0.1.0"));
        assert!(!is_newer("", "0.1.0"));
        assert!(!is_newer("v1.2.3.4", "0.1.0"));
    }

    #[test]
    fn release_json() {
        let body = r#"{"tag_name":"v0.2.0","html_url":"https://example.com/releases/v0.2.0","draft":false}"#;
        assert_eq!(parse_release(body).unwrap(), ("v0.2.0".to_string(), "https://example.com/releases/v0.2.0".to_string()));
        assert!(parse_release("{}").is_err());
    }
}
