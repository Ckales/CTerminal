//! 本地 AI 对话历史持久化。只保存 UI 提供的 JSON 数据，不保留运行时终端绑定。

use std::fs;
use std::io;
use std::path::Path;

use serde_json::{json, Value};

const FILE_NAME: &str = "ai-history.json";
const MAX_FILE_BYTES: usize = 64 * 1024 * 1024;
const MAX_DART_DATETIME_MILLIS: i64 = 8_640_000_000_000_000;

/// 读取完整的本地对话历史。尚无历史文件时返回空 JSON 数组。
pub fn load() -> Result<String, String> {
    load_from(&crate::paths::config_dir().join(FILE_NAME))
}

/// 校验并原子替换完整的本地对话历史。
pub fn save(json: &str) -> Result<(), String> {
    save_to(&crate::paths::config_dir().join(FILE_NAME), json)
}

/// 把历史消息中的工具调用和结果展开为普通 assistant 文本，供独立对话安全续聊。
/// 结果中不包含 `tool_calls` 或 `tool` 消息，因此续聊不会重放待确认的命令。
pub fn resume(messages_json: &str) -> Result<String, String> {
    if messages_json.len() > MAX_FILE_BYTES {
        return Err(format!("AI 历史消息超过大小上限（{MAX_FILE_BYTES} 字节）"));
    }
    let messages: Value = serde_json::from_str(messages_json)
        .map_err(|err| format!("AI 历史消息 JSON 格式错误：{err}"))?;
    let messages = messages
        .as_array()
        .ok_or_else(|| "AI 历史消息必须是 JSON 数组".to_string())?;
    validate_messages(messages)?;
    let completed_call_ids: std::collections::HashSet<&str> = messages
        .iter()
        .filter(|message| message.get("role").and_then(Value::as_str) == Some("tool"))
        .filter_map(|message| message.get("tool_call_id").and_then(Value::as_str))
        .collect();

    let mut resumed = Vec::with_capacity(messages.len());
    for (index, message) in messages.iter().enumerate() {
        let object = message.as_object().expect("message schema was validated");
        let role = object
            .get("role")
            .and_then(Value::as_str)
            .ok_or_else(|| format!("AI 历史第 {} 条消息缺少有效 role", index + 1))?;
        match role {
            "user" => resumed.push(json!({
                "role": "user",
                "content": object.get("content").cloned().unwrap_or(Value::Null)
            })),
            "assistant" => {
                let mut text = object
                    .get("content")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                if let Some(calls) = object.get("tool_calls").and_then(Value::as_array) {
                    for call in calls {
                        let function = call.get("function").unwrap_or(&Value::Null);
                        let arguments = function.get("arguments").unwrap_or(&Value::Null);
                        let parsed_arguments = match arguments.as_str() {
                            Some(raw) => serde_json::from_str::<Value>(raw).ok(),
                            None => Some(arguments.clone()),
                        };
                        let description = parsed_arguments
                            .as_ref()
                            .and_then(|value| value.get("description"))
                            .and_then(Value::as_str)
                            .unwrap_or_default();
                        let command = parsed_arguments
                            .as_ref()
                            .and_then(|value| value.get("command"))
                            .and_then(Value::as_str)
                            .unwrap_or_default();
                        if !description.is_empty() || !command.is_empty() {
                            if !text.is_empty() {
                                text.push_str("\n\n");
                            }
                            let call_id = call.get("id").and_then(Value::as_str);
                            if call_id.is_some_and(|id| completed_call_ids.contains(id)) {
                                text.push_str("Command request (a recorded tool result follows; the request alone does not establish success):\n");
                            } else {
                                text.push_str("Pending command request (execution status is unknown; do not replay automatically):\n");
                            }
                            if !description.is_empty() {
                                text.push_str("Command description: ");
                                text.push_str(description);
                                text.push('\n');
                            }
                            if !command.is_empty() {
                                text.push_str("Command: ");
                                text.push_str(command);
                            }
                        }
                    }
                }
                resumed.push(json!({"role": "assistant", "content": text}));
            }
            "tool" => {
                let raw = object
                    .get("content")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let result = serde_json::from_str::<Value>(raw).ok();
                let output = result
                    .as_ref()
                    .and_then(|value| value.get("output"))
                    .and_then(Value::as_str)
                    .unwrap_or(raw);
                let status = result
                    .as_ref()
                    .and_then(|value| value.get("status"))
                    .and_then(Value::as_str);
                let exit_code = result
                    .as_ref()
                    .and_then(|value| value.get("exitCode"))
                    .and_then(Value::as_i64);
                let mut text = String::from("Recorded command result");
                if let Some(status) = status {
                    text.push_str(" (status: ");
                    text.push_str(status);
                    text.push(')');
                }
                if let Some(exit_code) = exit_code {
                    text.push_str(&format!(" (exit code: {exit_code})"));
                }
                text.push_str(":\n");
                text.push_str(output);
                resumed.push(json!({"role": "assistant", "content": text}));
            }
            _ => unreachable!("message role was validated"),
        }
    }
    serde_json::to_string(&resumed).map_err(|err| err.to_string())
}

fn load_from(path: &Path) -> Result<String, String> {
    match fs::metadata(path) {
        Ok(metadata) if metadata.len() > MAX_FILE_BYTES as u64 => {
            return Err(format!("AI 历史超过大小上限（{MAX_FILE_BYTES} 字节）"));
        }
        Ok(_) => {}
        Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok("[]".into()),
        Err(err) => return Err(format!("读取 AI 历史失败：{err}")),
    }
    let json = match fs::read_to_string(path) {
        Ok(json) => json,
        Err(err) => return Err(format!("读取 AI 历史失败：{err}")),
    };
    validate(&json)?;
    Ok(json)
}

fn save_to(path: &Path, json: &str) -> Result<(), String> {
    validate(json)?;

    // A failed load must not turn into a silent reset on the next save.
    if path.exists() {
        load_from(path)?;
    }

    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|err| format!("创建 AI 历史目录失败：{err}"))?;
    }
    let temp = path.with_extension("json.tmp");
    fs::write(&temp, json).map_err(|err| format!("写入 AI 历史失败：{err}"))?;
    fs::rename(&temp, path).map_err(|err| format!("保存 AI 历史失败：{err}"))
}

fn validate(json: &str) -> Result<(), String> {
    if json.len() > MAX_FILE_BYTES {
        return Err(format!("AI 历史超过大小上限（{MAX_FILE_BYTES} 字节）"));
    }
    let value: Value =
        serde_json::from_str(json).map_err(|err| format!("AI 历史 JSON 格式错误：{err}"))?;
    let records = value
        .as_array()
        .ok_or_else(|| "AI 历史必须是 JSON 数组".to_string())?;
    let mut ids = std::collections::HashSet::with_capacity(records.len());
    for (index, record) in records.iter().enumerate() {
        let error = |message: &str| format!("AI 历史第 {} 条对话{message}", index + 1);
        let object = record.as_object().ok_or_else(|| error("必须是对象"))?;
        if !object.get("id").is_some_and(Value::is_string) {
            return Err(error("的 id 必须是字符串"));
        }
        if object
            .get("id")
            .and_then(Value::as_str)
            .is_some_and(|id| id.is_empty() || id.len() > 256)
        {
            return Err(error("的 id 不能为空且最多 256 字节"));
        }
        let id = object.get("id").and_then(Value::as_str).unwrap();
        if !ids.insert(id) {
            return Err(error("的 id 重复"));
        }
        let messages = object
            .get("messages")
            .and_then(Value::as_array)
            .ok_or_else(|| error("的 messages 必须是数组"))?;
        validate_messages(messages).map_err(|message| error(&format!("的消息无效：{message}")))?;
        if !object
            .get("updatedAt")
            .and_then(Value::as_number)
            .and_then(serde_json::Number::as_i64)
            .is_some_and(|timestamp| {
                (-MAX_DART_DATETIME_MILLIS..=MAX_DART_DATETIME_MILLIS).contains(&timestamp)
            })
        {
            return Err(error("的 updatedAt 必须是 Dart DateTime 支持范围内的整数"));
        }
        for field in ["draft", "context", "presetId", "partial"] {
            if object
                .get(field)
                .is_some_and(|value| !value.is_string() && !value.is_null())
            {
                return Err(error(&format!("的 {field} 必须是字符串或 null")));
            }
        }
    }
    Ok(())
}

fn validate_messages(messages: &[Value]) -> Result<(), String> {
    for (index, message) in messages.iter().enumerate() {
        let error = |reason: &str| format!("第 {} 条消息{reason}", index + 1);
        let object = message.as_object().ok_or_else(|| error("必须是对象"))?;
        let role = object
            .get("role")
            .and_then(Value::as_str)
            .ok_or_else(|| error("缺少有效 role"))?;
        if !matches!(role, "user" | "assistant" | "tool") {
            return Err(error("的 role 无效"));
        }

        match (role, object.get("content")) {
            ("tool", Some(content)) if content.is_string() => {}
            ("tool", _) => return Err(error("的 tool content 必须是字符串")),
            (_, Some(content)) if content.is_string() || content.is_null() => {}
            (_, Some(_)) => return Err(error("的 content 必须是字符串或 null")),
            (_, None) => {}
        }

        if let Some(tool_calls) = object.get("tool_calls") {
            if role != "assistant" {
                return Err(error("只有 assistant 消息可以包含 tool_calls"));
            }
            let calls = tool_calls
                .as_array()
                .filter(|calls| calls.len() == 1)
                .ok_or_else(|| error("的 tool_calls 必须恰好包含一个工具调用"))?;
            let call = calls[0]
                .as_object()
                .ok_or_else(|| error("的 tool_calls 项必须是对象"))?;
            let function = call
                .get("function")
                .and_then(Value::as_object)
                .ok_or_else(|| error("的工具调用 function 必须是对象"))?;
            let arguments = function
                .get("arguments")
                .and_then(Value::as_str)
                .ok_or_else(|| error("的工具调用 arguments 必须是字符串"))?;
            let parsed: Value = serde_json::from_str(arguments)
                .map_err(|_| error("的工具调用 arguments 必须是 JSON 对象字符串"))?;
            if !parsed.is_object() {
                return Err(error("的工具调用 arguments 必须是 JSON 对象字符串"));
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "cterm-ai-history-{name}-{}-{}",
            std::process::id(),
            std::thread::current().name().unwrap_or("test")
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn valid_history() -> String {
        json!([{
            "id": "chat-1",
            "messages": [
                {"role": "user", "content": "hello"},
                {"role": "assistant", "content": null, "tool_calls": [
                    {"id": "call-1", "type": "function", "function": {"name": "run", "arguments": "{}"}}
                ]},
                {"role": "tool", "tool_call_id": "call-1", "content": "ok"}
            ],
            "draft": "continue",
            "context": "terminal context",
            "presetId": "general",
            "updatedAt": 1_800_000_000_000_i64,
            "uiLabel": "kept"
        }])
        .to_string()
    }

    #[test]
    fn round_trips_full_history_and_additional_ui_fields() {
        let dir = temp_dir("roundtrip");
        let path = dir.join(FILE_NAME);
        let json = valid_history();
        save_to(&path, &json).unwrap();
        let loaded: Value = serde_json::from_str(&load_from(&path).unwrap()).unwrap();
        assert_eq!(loaded[0]["id"], "chat-1");
        assert_eq!(loaded[0]["messages"][1]["tool_calls"][0]["id"], "call-1");
        assert_eq!(loaded[0]["uiLabel"], "kept");
        assert!(!path.with_extension("json.tmp").exists());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn missing_file_is_an_empty_history() {
        let dir = temp_dir("missing");
        assert_eq!(load_from(&dir.join(FILE_NAME)).unwrap(), "[]");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn invalid_json_and_invalid_records_are_rejected_without_writing() {
        let dir = temp_dir("invalid");
        let path = dir.join(FILE_NAME);
        assert!(save_to(&path, "not json").is_err());
        assert!(save_to(
            &path,
            r#"[{"id":"x","messages":[{"role":"system"}],"updatedAt":1}]"#
        )
        .is_err());
        assert!(!path.exists());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn nullable_preset_and_optional_partial_are_accepted() {
        let history = json!([{
            "id": "chat-1",
            "messages": [],
            "presetId": null,
            "partial": "in progress",
            "draft": null,
            "context": null,
            "updatedAt": 1_800_000_000_000_i64
        }])
        .to_string();
        validate(&history).unwrap();
    }

    #[test]
    fn duplicate_ids_and_invalid_optional_fields_are_rejected() {
        let duplicate_ids = json!([
            {"id":"same","messages":[],"updatedAt":1},
            {"id":"same","messages":[],"updatedAt":2}
        ])
        .to_string();
        assert!(validate(&duplicate_ids).is_err());

        let invalid_optional = json!([{
            "id": "chat-1",
            "messages": [],
            "presetId": 42,
            "updatedAt": 1
        }])
        .to_string();
        assert!(validate(&invalid_optional).is_err());

        let out_of_range_timestamp = json!([{
            "id": "chat-1",
            "messages": [],
            "updatedAt": u64::MAX
        }])
        .to_string();
        assert!(validate(&out_of_range_timestamp).is_err());
    }

    #[test]
    fn message_content_and_tool_schema_are_safe_for_ui_and_resume() {
        let record = |messages: Value| {
            json!([{
                "id": "chat-1",
                "messages": messages,
                "updatedAt": 1_800_000_000_000_i64
            }])
            .to_string()
        };

        assert!(validate(&record(json!([{"role":"user","content":42}]))).is_err());
        assert!(validate(&record(json!([{"role":"tool","content":null}]))).is_err());
        assert!(validate(&record(json!([{
            "role":"assistant",
            "tool_calls":[]
        }])))
        .is_err());
        assert!(validate(&record(json!([{
            "role":"assistant",
            "tool_calls":[
                {"function":{"arguments":"{}"}},
                {"function":{"arguments":"{}"}}
            ]
        }])))
        .is_err());
        assert!(validate(&record(json!([{
            "role":"assistant",
            "tool_calls":[{"function":{"arguments":"[]"}}]
        }])))
        .is_err());
        assert!(resume(r#"[{"role":"user","content":42}]"#).is_err());

        let optional_assistant_content = json!([
            {"role":"assistant"},
            {"role":"assistant","content":null}
        ])
        .to_string();
        validate(&record(
            serde_json::from_str(&optional_assistant_content).unwrap(),
        ))
        .unwrap();
        assert!(resume(&optional_assistant_content).is_ok());
    }

    #[test]
    fn timestamp_must_be_in_dart_datetime_range() {
        for timestamp in [MAX_DART_DATETIME_MILLIS + 1, -MAX_DART_DATETIME_MILLIS - 1] {
            let history = json!([{
                "id": "chat-1",
                "messages": [],
                "updatedAt": timestamp
            }])
            .to_string();
            assert!(validate(&history).is_err());
        }
    }

    #[test]
    fn corrupt_file_is_reported_and_never_overwritten() {
        let dir = temp_dir("corrupt");
        let path = dir.join(FILE_NAME);
        fs::write(&path, "{").unwrap();
        assert!(load_from(&path).is_err());
        assert!(save_to(&path, &valid_history()).is_err());
        assert_eq!(fs::read_to_string(&path).unwrap(), "{");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn resume_flattens_pending_and_completed_tool_calls() {
        let messages = json!([
            {"role": "user", "content": "show files"},
            {"role": "assistant", "content": "I can check.", "tool_calls": [{
                "id": "pending-call",
                "type": "function",
                "function": {"name": "execute_terminal_command", "arguments": "{\"description\":\"List current files\",\"command\":\"ls -la\"}"}
            }]},
            {"role": "assistant", "content": null, "tool_calls": [{
                "id": "done-call",
                "type": "function",
                "function": {"name": "execute_terminal_command", "arguments": "{\"description\":\"Print working directory\",\"command\":\"pwd\"}"}
            }]},
            {"role": "tool", "tool_call_id": "done-call", "content": "{\"status\":\"ok\",\"output\":\"/tmp/work\",\"exitCode\":0}"}
        ])
        .to_string();
        let resumed: Value = serde_json::from_str(&resume(&messages).unwrap()).unwrap();
        assert_eq!(resumed[0]["role"], "user");
        assert_eq!(resumed[1]["role"], "assistant");
        assert!(resumed[1]["content"]
            .as_str()
            .unwrap()
            .contains("Pending command request"));
        assert!(resumed[1]["content"].as_str().unwrap().contains("ls -la"));
        assert_eq!(resumed[2]["role"], "assistant");
        assert!(resumed[2]["content"]
            .as_str()
            .unwrap()
            .contains("recorded tool result follows"));
        assert!(resumed[2]["content"].as_str().unwrap().contains("pwd"));
        assert_eq!(resumed[3]["role"], "assistant");
        assert!(resumed[3]["content"]
            .as_str()
            .unwrap()
            .contains("Recorded command result"));
        assert!(resumed[3]["content"]
            .as_str()
            .unwrap()
            .contains("/tmp/work"));
        assert!(resumed
            .as_array()
            .unwrap()
            .iter()
            .all(|message| message.get("tool_calls").is_none()));
        assert!(resumed
            .as_array()
            .unwrap()
            .iter()
            .all(|message| message["role"] != "tool"));
    }
}
