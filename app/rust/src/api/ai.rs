//! AI 请求的 FRB 薄桥接；配置和聊天逻辑由 cterm-core 负责。

use flutter_rust_bridge::frb;
use crate::frb_generated::StreamSink;

pub struct AiChatEvent {
    pub kind: String,
    pub text: String,
}

#[frb(sync)]
pub fn ai_presets_defaults() -> String {
    serde_json::to_string(&cterm_core::config::default_ai_prompt_presets())
        .expect("default AI presets always serialize")
}

#[frb(sync)]
pub fn ai_chat_prepare() -> u32 {
    cterm_core::ai::prepare_chat()
}

#[frb(sync)]
pub fn ai_chat_cancel(request_id: u32) {
    cterm_core::ai::cancel_chat(request_id);
}

pub async fn ai_chat_stream(
    request_id: u32,
    preset_id: String,
    messages_json: String,
    context: String,
    sink: StreamSink<AiChatEvent>,
) -> Result<(), String> {
    let config = match cterm_core::config::load() {
        Ok(config) => config,
        Err(error) => {
            cterm_core::ai::discard_chat(request_id);
            let _ = sink.add(AiChatEvent { kind: "error".into(), text: error.clone() });
            return Err(error);
        }
    };
    let result = cterm_core::ai::stream_chat(
        request_id,
        &config.ai,
        &preset_id,
        &messages_json,
        &context,
        |text| sink.add(AiChatEvent { kind: "delta".into(), text: text.to_owned() }).is_ok(),
    )
    .await;
    match result {
        Ok(cterm_core::ai::ChatStreamOutcome::Completed) => {
            let _ = sink.add(AiChatEvent { kind: "done".into(), text: String::new() });
            Ok(())
        }
        Ok(cterm_core::ai::ChatStreamOutcome::Cancelled) => {
            let _ = sink.add(AiChatEvent { kind: "cancelled".into(), text: String::new() });
            Ok(())
        }
        Err(error) => {
            let _ = sink.add(AiChatEvent { kind: "error".into(), text: error.clone() });
            Err(error)
        }
    }
}

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
