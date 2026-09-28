//! 命令历史：回车时从屏幕读出刚输入的命令记下来，输入时按前缀给出补全建议。
//! 不依赖 shell 集成，本地 / SSH / Telnet / 串口通用；没有回显的输入（密码）屏幕上读不到，不会被记下。

use std::path::PathBuf;
use std::sync::{Arc, LazyLock, Mutex};

const LIMIT: usize = 1000;

#[derive(Default)]
pub struct History {
    /// None = 只在内存里（测试用）
    path: Option<PathBuf>,
    /// 旧的在前
    entries: Vec<String>,
}

impl History {
    pub fn load(path: PathBuf) -> History {
        let entries = match std::fs::read_to_string(&path) {
            Ok(text) => text.lines().map(str::to_string).collect(),
            Err(_) => Vec::new(),
        };
        History { path: Some(path), entries }
    }

    /// 记一条命令：重复的挪到最新，超出上限丢最旧的
    pub fn add(&mut self, command: &str) {
        let command = command.trim();
        // 单个字符多半是回答 y/n；全是 * 是带回显的密码
        if command.chars().count() < 2 || command.chars().all(|c| c == '*' || c == '•') {
            return;
        }
        self.entries.retain(|entry| entry != command);
        self.entries.push(command.to_string());
        if self.entries.len() > LIMIT {
            self.entries.drain(..self.entries.len() - LIMIT);
        }
        if let Some(path) = &self.path {
            let mut text = self.entries.join("\n");
            text.push('\n');
            if let Some(dir) = path.parent() {
                let _ = std::fs::create_dir_all(dir);
            }
            if let Err(err) = std::fs::write(path, text) {
                crate::log::warn(&format!("命令历史保存失败：{err}"));
            }
        }
    }

    /// 以 prefix 开头的命令，新的在前，最多 limit 条（不含与 prefix 相同的）
    pub fn suggest(&self, prefix: &str, limit: usize) -> Vec<String> {
        let mut found = Vec::new();
        if prefix.trim().is_empty() {
            return found;
        }
        for entry in self.entries.iter().rev() {
            if found.len() == limit {
                break;
            }
            if entry.len() > prefix.len() && entry.starts_with(prefix) {
                found.push(entry.clone());
            }
        }
        found
    }
}

static SHARED: LazyLock<Arc<Mutex<History>>> =
    LazyLock::new(|| Arc::new(Mutex::new(History::load(crate::paths::config_dir().join("history.txt")))));

/// 所有会话共用的一份历史
pub fn shared() -> Arc<Mutex<History>> {
    SHARED.clone()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn add_dedupes_filters_and_caps() {
        let mut history = History::default();
        history.add("  git status ");
        history.add("y");
        history.add("******");
        history.add("git log");
        history.add("git status");
        assert_eq!(history.entries, ["git log", "git status"]);
        for index in 0..LIMIT + 5 {
            history.add(&format!("echo {index}"));
        }
        assert_eq!(history.entries.len(), LIMIT);
        assert_eq!(history.entries[0], "echo 5");
    }

    #[test]
    fn suggest_prefers_latest_and_skips_exact() {
        let mut history = History::default();
        history.add("cd Work/dev/aiproxy");
        history.add("cd Work/dev/api");
        assert_eq!(history.suggest("cd Work/dev/a", 8), ["cd Work/dev/api", "cd Work/dev/aiproxy"]);
        assert_eq!(history.suggest("cd Work/dev/a", 1), ["cd Work/dev/api"]);
        assert_eq!(history.suggest("cd Work/dev/ai", 8), ["cd Work/dev/aiproxy"]);
        assert!(history.suggest("cd Work/dev/api", 8).is_empty());
        assert!(history.suggest("  ", 8).is_empty());
    }

    #[test]
    fn persists_one_command_per_line() {
        let dir = std::env::temp_dir().join(format!("cterm-history-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("history.txt");
        let _ = std::fs::remove_file(&path);
        History::load(path.clone()).add("ls -la");
        assert_eq!(History::load(path.clone()).suggest("ls", 8), ["ls -la"]);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
