//! Confirmed command execution in an existing terminal session.
//!
//! A private OSC marker brackets output from the active interactive shell. The
//! token is unique per invocation and output is collected from the existing
//! PTY/channel; this module never starts another shell.

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const OUTPUT_LIMIT: usize = 1024 * 1024;
pub(crate) const EXECUTION_TIMEOUT: Duration = Duration::from_secs(30);
static TOKEN_COUNTER: AtomicU64 = AtomicU64::new(1);

pub(crate) fn token() -> String {
    let time = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let count = TOKEN_COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{time:x}-{count:x}")
}

pub(crate) fn shell_command(command: &str, token: &str) -> Result<Vec<u8>, String> {
    if command.trim().is_empty() {
        return Err(crate::i18n::tr("命令不能为空"));
    }
    if command.len() > 4 * 1024 {
        return Err(crate::i18n::tr("命令超过 4 KiB 限制"));
    }
    if command
        .bytes()
        .any(|byte| (byte < 0x20 && byte != b'\n' && byte != b'\t') || byte == 0x7f)
    {
        return Err(crate::i18n::tr("命令包含不允许的控制字符"));
    }

    let quoted = command.replace('\'', "'\\''");
    let line = format!(
        "printf '\\033]777;cterm;begin;{token}\\007'; eval '{quoted}'; __cterm_ai_status=$?; printf '\\033]777;cterm;end;{token};%s\\007' \"$__cterm_ai_status\"\r"
    );
    Ok(line.into_bytes())
}

#[derive(Debug, Default)]
pub(crate) struct MarkerCapture {
    begin: Vec<u8>,
    end_prefix: Vec<u8>,
    pending: Vec<u8>,
    started: bool,
    finished: bool,
    output: Vec<u8>,
    truncated: bool,
    exit_code: Option<i32>,
}

impl MarkerCapture {
    pub(crate) fn new(token: &str) -> Self {
        Self {
            begin: format!("\x1b]777;cterm;begin;{token}\x07").into_bytes(),
            end_prefix: format!("\x1b]777;cterm;end;{token};").into_bytes(),
            ..Default::default()
        }
    }

    pub(crate) fn feed(&mut self, bytes: &[u8]) -> bool {
        if self.finished {
            return true;
        }
        self.pending.extend_from_slice(bytes);
        loop {
            if !self.started {
                if let Some(index) = find_subslice(&self.pending, &self.begin) {
                    let after = index + self.begin.len();
                    self.pending.drain(..after);
                    self.started = true;
                    continue;
                }
                retain_marker_suffix(&mut self.pending, &self.begin);
                return false;
            }

            if let Some(index) = find_subslice(&self.pending, &self.end_prefix) {
                let output = self.pending[..index].to_vec();
                self.append_output(&output);
                self.pending.drain(..index);
                let status_start = self.end_prefix.len();
                let Some(bell_offset) = self.pending[status_start..]
                    .iter()
                    .position(|byte| *byte == 0x07)
                else {
                    return false;
                };
                let status = &self.pending[status_start..status_start + bell_offset];
                self.exit_code = std::str::from_utf8(status)
                    .ok()
                    .and_then(|status| status.parse().ok());
                self.pending.drain(..status_start + bell_offset + 1);
                self.finished = true;
                return true;
            }

            let retained = self.end_prefix.len().saturating_sub(1);
            if self.pending.len() > retained {
                let flush = self.pending.len() - retained;
                let output = self.pending[..flush].to_vec();
                self.append_output(&output);
                self.pending.drain(..flush);
            }
            return false;
        }
    }

    fn append_output(&mut self, bytes: &[u8]) {
        let room = OUTPUT_LIMIT.saturating_sub(self.output.len());
        let count = room.min(bytes.len());
        self.output.extend_from_slice(&bytes[..count]);
        self.truncated |= count != bytes.len();
    }

    pub(crate) fn finished(&self) -> bool {
        self.finished
    }

    pub(crate) fn exit_code(&self) -> Option<i32> {
        self.exit_code
    }

    pub(crate) fn output_text(&self) -> String {
        strip_terminal_controls(&self.output)
    }

    pub(crate) fn truncated(&self) -> bool {
        self.truncated
    }
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

fn retain_marker_suffix(pending: &mut Vec<u8>, marker: &[u8]) {
    let max = pending.len().min(marker.len().saturating_sub(1));
    for size in (1..=max).rev() {
        if pending[pending.len() - size..] == marker[..size] {
            pending.drain(..pending.len() - size);
            return;
        }
    }
    pending.clear();
}

pub(crate) fn result_json(capture: &MarkerCapture, status: &str) -> String {
    serde_json::json!({
        "output": capture.output_text(),
        "exitCode": capture.exit_code(),
        "status": status,
        "truncated": capture.truncated(),
    })
    .to_string()
}

/// Strip terminal control sequences while preserving text, tabs, and line breaks.
fn strip_terminal_controls(bytes: &[u8]) -> String {
    #[derive(Clone, Copy)]
    enum State {
        Text,
        Escape,
        Csi,
        Osc,
        OscEscape,
    }
    let mut state = State::Text;
    let mut out = Vec::with_capacity(bytes.len());
    for &byte in bytes {
        state = match state {
            State::Text => match byte {
                0x1b => State::Escape,
                b'\n' | b'\r' | b'\t' => {
                    out.push(byte);
                    State::Text
                }
                0x00..=0x1f | 0x7f => State::Text,
                _ => {
                    out.push(byte);
                    State::Text
                }
            },
            State::Escape => match byte {
                b'[' => State::Csi,
                b']' => State::Osc,
                0x30..=0x7e => State::Text,
                _ => State::Escape,
            },
            State::Csi => {
                if (0x40..=0x7e).contains(&byte) {
                    State::Text
                } else {
                    State::Csi
                }
            }
            State::Osc => match byte {
                0x07 => State::Text,
                0x1b => State::OscEscape,
                _ => State::Osc,
            },
            State::OscEscape => match byte {
                b'\\' => State::Text,
                0x1b => State::OscEscape,
                _ => State::Osc,
            },
        };
    }
    String::from_utf8_lossy(&out)
        .replace("\r\n", "\n")
        .replace('\r', "\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shell_command_quotes_eval_and_brackets_with_status() {
        let command =
            String::from_utf8(shell_command("printf '%s' 'a b'", "abc").unwrap()).unwrap();
        assert!(command.contains("eval 'printf "));
        assert!(command.contains("%s"));
        assert!(command.contains("a b"));
        assert!(command.starts_with("printf '\\033]777;cterm;begin;abc\\007'; eval "));
        assert!(
            command.ends_with("printf '\\033]777;cterm;end;abc;%s\\007' \"$__cterm_ai_status\"\r")
        );
    }

    #[test]
    fn marker_capture_handles_fragmented_boundaries_and_strips_controls() {
        let mut capture = MarkerCapture::new("n1");
        for part in [
            b"ignored\x1b]777;cterm;be".as_slice(),
            b"gin;n1\x07hello\x1b[31m red\x1b[0m\x1b]777;cterm;end;n1;".as_slice(),
            b"7\x07after".as_slice(),
        ] {
            capture.feed(part);
        }
        assert!(capture.finished());
        assert_eq!(capture.exit_code(), Some(7));
        assert_eq!(capture.output_text(), "hello red");
    }

    #[test]
    fn marker_capture_preserves_end_marker_when_status_is_fragmented() {
        let mut capture = MarkerCapture::new("split");
        let stream = b"\x1b]777;cterm;begin;split\x07output\x1b]777;cterm;end;split;23\x07";
        for byte in stream {
            capture.feed(std::slice::from_ref(byte));
        }
        assert!(capture.finished());
        assert_eq!(capture.exit_code(), Some(23));
        assert_eq!(capture.output_text(), "output");
    }

    #[test]
    fn rejects_command_control_characters_and_large_lines() {
        assert!(shell_command("echo hi\r", "x").is_err());
        assert!(shell_command("echo hi\u{1b}[2J", "x").is_err());
        assert!(shell_command(&"x".repeat(4 * 1024 + 1), "x").is_err());
        assert!(shell_command("echo hi\nthere", "x").is_ok());
    }

    #[test]
    fn capture_is_bounded() {
        let mut capture = MarkerCapture::new("cap");
        capture.feed(b"\x1b]777;cterm;begin;cap\x07");
        capture.feed(&vec![b'x'; OUTPUT_LIMIT + 12]);
        capture.feed(b"\x1b]777;cterm;end;cap;0\x07");
        assert!(capture.truncated());
        assert_eq!(capture.output_text().len(), OUTPUT_LIMIT);
    }
}
