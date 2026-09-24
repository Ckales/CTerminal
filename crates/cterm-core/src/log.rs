//! 核心日志：配置目录/logs/cterminal.log，超过约 5MB 改名为 .1（只留一个旧文件）。
//! 只记连接元数据、状态变化和错误原因。绝不记录终端内容、键盘输入、粘贴内容、
//! 密码 / 口令 / 键盘交互的回答、钥匙串里的值：日志函数只接收调用方拼好的描述文字。
//! 没调用 init() 时什么都不写，测试不会写到真实配置目录。

use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Mutex, Once, PoisonError};
use std::time::{SystemTime, UNIX_EPOCH};

const MAX_BYTES: u64 = 5 * 1024 * 1024;

static LOGGER: Mutex<Option<Logger>> = Mutex::new(None);

struct Logger {
    path: PathBuf,
    max_bytes: u64,
    file: Option<File>,
    size: u64,
}

impl Logger {
    fn new(path: PathBuf, max_bytes: u64) -> Logger {
        Logger { path, max_bytes, file: None, size: 0 }
    }

    fn open(&mut self) {
        self.file = OpenOptions::new().create(true).append(true).open(&self.path).ok();
        self.size = self.file.as_ref().and_then(|file| file.metadata().ok()).map(|meta| meta.len()).unwrap_or(0);
    }

    /// 写失败静默忽略：日志不能影响终端本身
    fn write(&mut self, level: &str, message: &str) {
        let line = format!("{} {level} {}\n", timestamp(SystemTime::now()), message.replace('\n', "\\n"));
        if self.file.is_none() {
            self.open();
        }
        if self.size > 0 && self.size + line.len() as u64 > self.max_bytes {
            // 先关文件再改名（Windows 不能改名打开着的文件）；rename 会覆盖旧的 .1
            self.file = None;
            let _ = fs::rename(&self.path, self.path.with_extension("log.1"));
            self.open();
        }
        let Some(file) = self.file.as_mut() else { return };
        if file.write_all(line.as_bytes()).is_ok() {
            self.size += line.len() as u64;
        }
    }
}

/// 应用启动时调用，重复调用无副作用：打开日志文件、装 panic hook、记一条启动信息
pub fn init() {
    static INIT: Once = Once::new();
    INIT.call_once(|| {
        let dir = crate::paths::config_dir().join("logs");
        if fs::create_dir_all(&dir).is_err() {
            return;
        }
        *LOGGER.lock().unwrap_or_else(PoisonError::into_inner) = Some(Logger::new(dir.join("cterminal.log"), MAX_BYTES));
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            // panic 可能发生在持有日志锁的线程里，拿不到锁就不记，不能死锁
            if let Ok(mut guard) = LOGGER.try_lock() {
                if let Some(logger) = guard.as_mut() {
                    logger.write("ERROR", &format!("panic {info}"));
                }
            }
            previous(info);
        }));
        info(&format!("启动 cterm-core {} {}/{}", env!("CARGO_PKG_VERSION"), std::env::consts::OS, std::env::consts::ARCH));
    });
}

fn write(level: &str, message: &str) {
    let mut guard = LOGGER.lock().unwrap_or_else(PoisonError::into_inner);
    if let Some(logger) = guard.as_mut() {
        logger.write(level, message);
    }
}

pub fn info(message: &str) {
    write("INFO", message);
}

pub fn warn(message: &str) {
    write("WARN", message);
}

pub fn error(message: &str) {
    write("ERROR", message);
}

/// UTC 时间，精确到毫秒：2026-09-24T03:04:05.123Z
fn timestamp(time: SystemTime) -> String {
    let since = time.duration_since(UNIX_EPOCH).unwrap_or_default();
    let seconds = since.as_secs();
    let clock = seconds % 86400;
    // 天数 → 公历日期（Howard Hinnant 的 civil_from_days）
    let days = (seconds / 86400) as i64 + 719468;
    let era = days.div_euclid(146097);
    let day_of_era = days.rem_euclid(146097);
    let year_of_era = (day_of_era - day_of_era / 1460 + day_of_era / 36524 - day_of_era / 146096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 { month_index + 3 } else { month_index - 9 };
    let year = year_of_era + era * 400 + if month <= 2 { 1 } else { 0 };
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{:03}Z",
        clock / 3600,
        clock % 3600 / 60,
        clock % 60,
        since.subsec_millis()
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn timestamp_format() {
        let at = |seconds: u64, millis: u64| timestamp(UNIX_EPOCH + Duration::from_secs(seconds) + Duration::from_millis(millis));
        assert_eq!(at(0, 0), "1970-01-01T00:00:00.000Z");
        assert_eq!(at(951782400, 5), "2000-02-29T00:00:00.005Z");
        assert_eq!(at(1_000_000_000, 0), "2001-09-09T01:46:40.000Z");
    }

    #[test]
    fn lines_have_level_and_rotate_keeping_one_old_file() {
        let dir = std::env::temp_dir().join(format!("cterm-log-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("cterminal.log");
        let mut logger = Logger::new(path.clone(), 200);
        logger.write("INFO", "第一行\n续行");
        let first = fs::read_to_string(&path).unwrap();
        assert!(first.ends_with(" INFO 第一行\\n续行\n"), "{first}");
        assert_eq!(first.lines().count(), 1, "多行消息要压成一行");
        for index in 0..20 {
            logger.write("WARN", &format!("message {index}"));
        }
        let current = fs::read_to_string(&path).unwrap();
        let old = fs::read_to_string(path.with_extension("log.1")).unwrap();
        assert!(current.len() <= 200 && old.len() <= 200, "单个文件不超过上限");
        assert!(current.contains("message 19"));
        assert!(!old.contains("第一行"), "只保留一个旧文件，更早的内容被丢弃");
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 2);
        let _ = fs::remove_dir_all(&dir);
    }

    /// 边界守卫：日志调用不许出现终端数据、输入、密码类变量。
    /// 只能看单行写法，是最低防线；新增日志时照样要自己确认不带秘密
    #[test]
    fn log_calls_never_touch_terminal_data_or_secrets() {
        let forbidden = ["Output::Data", "bytes", "data", "password", "passphrase", "answer", "saved", "secrets::get", "line", "text"];
        let src = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src");
        let mut offending = Vec::new();
        for entry in fs::read_dir(&src).unwrap().flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name == "log.rs" {
                continue;
            }
            let content = fs::read_to_string(entry.path()).unwrap();
            for (number, line) in content.lines().enumerate() {
                if !line.contains("log::info(") && !line.contains("log::warn(") && !line.contains("log::error(") {
                    continue;
                }
                if forbidden.iter().any(|word| line.contains(word)) {
                    offending.push(format!("{name}:{}: {}", number + 1, line.trim()));
                }
            }
        }
        assert!(offending.is_empty(), "日志调用疑似带了终端内容或秘密：\n{}", offending.join("\n"));
    }
}
