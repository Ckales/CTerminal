//! 路径：用户目录、配置目录，以及 Windows 下宿主路径 → 各 shell 路径写法的翻译

use std::path::PathBuf;

pub fn home_dir() -> PathBuf {
    let var = if cfg!(windows) { "USERPROFILE" } else { "HOME" };
    std::env::var_os(var).map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"))
}

/// macOS: ~/Library/Application Support/CTerminal；Windows: %APPDATA%\CTerminal。
/// 设置了 CTERMINAL_CONFIG_DIR 时用它（测试用，避免读写真实配置）
pub fn config_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("CTERMINAL_CONFIG_DIR") {
        return PathBuf::from(dir);
    }
    if cfg!(windows) {
        let appdata = std::env::var_os("APPDATA").map(PathBuf::from).unwrap_or_else(home_dir);
        return appdata.join("CTerminal");
    }
    if cfg!(target_os = "macos") {
        return home_dir().join("Library/Application Support/CTerminal");
    }
    let base = std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from).unwrap_or_else(|| home_dir().join(".config"));
    base.join("cterminal")
}

/// 目标 shell 使用的路径写法
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PathStyle {
    /// 原样（macOS / cmd / PowerShell）
    Native,
    /// Git-Bash / MSYS2：/c/foo
    Msys,
    /// WSL：/mnt/c/foo
    Wsl,
    /// Cygwin：/cygdrive/c/foo
    Cygwin,
}

/// 宿主路径 → shell 路径（拖文件进终端、“在此处打开”用）
pub fn to_shell(host: &str, style: PathStyle) -> String {
    let bytes = host.as_bytes();
    let has_drive = bytes.len() >= 2 && bytes[1] == b':' && bytes[0].is_ascii_alphabetic();
    if style == PathStyle::Native || !has_drive {
        return host.to_string();
    }
    let drive = (bytes[0] as char).to_ascii_lowercase();
    let rest = host[2..].replace('\\', "/");
    let prefix = match style {
        PathStyle::Msys => format!("/{drive}"),
        PathStyle::Wsl => format!("/mnt/{drive}"),
        PathStyle::Cygwin => format!("/cygdrive/{drive}"),
        PathStyle::Native => unreachable!(),
    };
    format!("{prefix}{rest}")
}

/// 拖进终端的路径要转义，含空格等字符时加引号
pub fn quote_for_shell(path: &str, style: PathStyle) -> String {
    let needs_quote = path.chars().any(|c| c.is_whitespace() || "'\"()&;|<>$`!*?[]{}#~".contains(c));
    if !needs_quote {
        return path.to_string();
    }
    if cfg!(windows) && style == PathStyle::Native {
        return format!("\"{path}\"");
    }
    format!("'{}'", path.replace('\'', r"'\''"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn windows_paths_per_shell() {
        let host = r"C:\Users\me\My Files";
        assert_eq!(to_shell(host, PathStyle::Native), host);
        assert_eq!(to_shell(host, PathStyle::Msys), "/c/Users/me/My Files");
        assert_eq!(to_shell(host, PathStyle::Wsl), "/mnt/c/Users/me/My Files");
        assert_eq!(to_shell(host, PathStyle::Cygwin), "/cygdrive/c/Users/me/My Files");
        assert_eq!(to_shell("/Users/me", PathStyle::Wsl), "/Users/me");
    }

    #[test]
    fn quoting() {
        assert_eq!(quote_for_shell("/tmp/a", PathStyle::Msys), "/tmp/a");
        assert_eq!(quote_for_shell("/tmp/it's here", PathStyle::Msys), r"'/tmp/it'\''s here'");
    }
}
