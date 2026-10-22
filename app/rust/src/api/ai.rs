//! AI 请求的 FRB 薄桥接；配置和聊天逻辑由 cterm-core 负责。

use crate::frb_generated::StreamSink;
use flutter_rust_bridge::frb;

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
            let _ = sink.add(AiChatEvent {
                kind: "error".into(),
                text: error.clone(),
            });
            return Err(error);
        }
    };
    let result = cterm_core::ai::stream_chat(
        request_id,
        &config.ai,
        &preset_id,
        &messages_json,
        &context,
        |text| {
            sink.add(AiChatEvent {
                kind: "delta".into(),
                text: text.to_owned(),
            })
            .is_ok()
        },
    )
    .await;
    match result {
        Ok(cterm_core::ai::ChatStreamOutcome::Completed) => {
            let _ = sink.add(AiChatEvent {
                kind: "done".into(),
                text: String::new(),
            });
            Ok(())
        }
        Ok(cterm_core::ai::ChatStreamOutcome::Cancelled) => {
            let _ = sink.add(AiChatEvent {
                kind: "cancelled".into(),
                text: String::new(),
            });
            Ok(())
        }
        Err(error) => {
            let _ = sink.add(AiChatEvent {
                kind: "error".into(),
                text: error.clone(),
            });
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

/// 工具模式始终绑定发起请求的终端 id，UI 只展示确认和传回结果。
pub async fn ai_agent_stream(
    request_id: u32,
    preset_id: String,
    messages_json: String,
    context: String,
    terminal_id: u32,
    sink: StreamSink<AiChatEvent>,
) -> Result<(), String> {
    let config = match cterm_core::config::load() {
        Ok(config) => config,
        Err(error) => {
            cterm_core::ai::discard_chat(request_id);
            return Err(error);
        }
    };
    let Some(session) = crate::api::terminal::session_by_id(terminal_id) else {
        cterm_core::ai::discard_chat(request_id);
        return Err(cterm_core::i18n::tr("目标终端已关闭，请重新发起请求"));
    };
    let tools_enabled = session.ai_capability().is_some();
    let result = cterm_core::ai::stream_chat_with_tools(
        request_id,
        &config.ai,
        &preset_id,
        &messages_json,
        &context,
        tools_enabled,
        |event| {
            let (kind, text) = match event {
                cterm_core::ai::ChatEvent::Delta(text) => ("delta", text),
                cterm_core::ai::ChatEvent::ToolCalls(text) => ("tool_calls", text),
            };
            sink.add(AiChatEvent {
                kind: kind.into(),
                text,
            })
            .is_ok()
        },
    )
    .await;
    match result {
        Ok(outcome) => {
            let kind = match outcome {
                cterm_core::ai::ChatStreamOutcome::Completed => "done",
                cterm_core::ai::ChatStreamOutcome::Cancelled => "cancelled",
            };
            let _ = sink.add(AiChatEvent {
                kind: kind.into(),
                text: String::new(),
            });
            Ok(())
        }
        Err(error) => {
            let _ = sink.add(AiChatEvent {
                kind: "error".into(),
                text: error.clone(),
            });
            Err(error)
        }
    }
}

pub fn ai_tool_execute(
    terminal_id: u32,
    call_id: String,
    command: String,
) -> Result<String, String> {
    crate::api::terminal::session_by_id(terminal_id)
        .ok_or_else(|| cterm_core::i18n::tr("目标终端已关闭，请重新发起请求"))?
        .ai_execute(&call_id, &command)
}

#[frb(sync)]
pub fn ai_tool_cancel(terminal_id: u32, call_id: String) {
    if let Some(session) = crate::api::terminal::session_by_id(terminal_id) {
        session.ai_cancel(&call_id);
    }
}
