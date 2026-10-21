//! AI 请求的 FRB 薄桥接；配置和聊天逻辑由 cterm-core 负责。

use flutter_rust_bridge::frb;

#[frb(sync)]
pub fn ai_status() -> bool {
    cterm_core::ai::has_api_key()
}

pub fn ai_set_api_key(value: String) -> Result<(), String> {
    cterm_core::ai::set_api_key(&value)
}

pub fn ai_chat(messages_json: String, context: String) -> Result<String, String> {
    let config = cterm_core::config::load()?;
    cterm_core::ai::chat(&config.ai, &messages_json, &context)
}
