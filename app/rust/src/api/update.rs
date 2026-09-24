//! 新版本检查的桥接：规则（版本比较、每天一次）都在 cterm_core::update。

use cterm_core::update;
use flutter_rust_bridge::frb;

pub struct UpdateInfo {
    /// 最新发布的 tag；还没有任何发布时为空
    pub latest: String,
    pub url: String,
    pub newer: bool,
}

fn to_info(status: update::UpdateStatus) -> UpdateInfo {
    UpdateInfo { latest: status.latest, url: status.url, newer: status.newer }
}

/// 当前版本（Cargo 包版本，界面显示也用它）
#[frb(sync)]
pub fn app_version() -> String {
    update::CURRENT_VERSION.to_string()
}

/// 启动时后台检查：24 小时内最多请求一次；只有新版本时返回，失败静默
pub fn update_check_daily() -> Option<UpdateInfo> {
    update::check_daily().map(to_info)
}

/// “关于”页的立即检查
pub fn update_check_now() -> Result<UpdateInfo, String> {
    update::check_now().map(to_info)
}
