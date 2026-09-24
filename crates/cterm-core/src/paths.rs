//! 路径：用户目录、配置目录，以及 Windows 下宿主路径 → 各 shell 路径写法的翻译

use std::path::{Path, PathBuf};

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

/// 下载默认存到“下载”文件夹（SFTP 下载、ZMODEM 接收）
pub fn downloads_dir() -> PathBuf {
    home_dir().join("Downloads")
}

/// 目录里已有同名文件时加序号：a.txt → a (1).txt，绝不覆盖
pub fn unique_path(dir: &Path, name: &str) -> PathBuf {
    let candidate = dir.join(name);
    if !candidate.exists() {
        return candidate;
    }
    let (stem, ext) = match name.rfind('.') {
        Some(dot) if dot > 0 => (&name[..dot], &name[dot..]),
        _ => (name, ""),
    };
    let mut index = 1;
    loop {
        let candidate = dir.join(format!("{stem} ({index}){ext}"));
        if !candidate.exists() {
            return candidate;
        }
        index += 1;
    }
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
    // UNC 路径 \\server\share：Git-Bash / MSYS2 / Cygwin 认 //server/share；WSL 没有对应写法，原样交给引号处理
    if host.starts_with(r"\\") && matches!(style, PathStyle::Msys | PathStyle::Cygwin) {
        return host.replace('\\', "/");
    }
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
    // cmd / PowerShell 里反斜杠是路径分隔符；POSIX shell 里是转义符，文件名带它必须加引号
    let windows_native = cfg!(windows) && style == PathStyle::Native;
    let needs_quote = path.chars().any(|c| c.is_whitespace() || "'\"()&;|<>$`!*?[]{}#~".contains(c) || (c == '\\' && !windows_native));
    if !needs_quote {
        return path.to_string();
    }
    if windows_native {
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

    #[test]
    fn drive_edge_cases() {
        // 根目录、小写盘符、已经是正斜杠、裸盘符
        assert_eq!(to_shell(r"C:\", PathStyle::Msys), "/c/");
        assert_eq!(to_shell(r"C:\", PathStyle::Wsl), "/mnt/c/");
        assert_eq!(to_shell(r"d:\Work", PathStyle::Cygwin), "/cygdrive/d/Work");
        assert_eq!(to_shell("E:/a/b", PathStyle::Wsl), "/mnt/e/a/b");
        assert_eq!(to_shell("Z:", PathStyle::Msys), "/z");
        // 不是盘符的冒号不翻译
        assert_eq!(to_shell("1:/x", PathStyle::Msys), "1:/x");
        assert_eq!(to_shell("", PathStyle::Wsl), "");
    }

    #[test]
    fn unc_paths() {
        let unc = r"\\server\share\dir";
        assert_eq!(to_shell(unc, PathStyle::Msys), "//server/share/dir");
        assert_eq!(to_shell(unc, PathStyle::Cygwin), "//server/share/dir");
        assert_eq!(to_shell(unc, PathStyle::Wsl), unc);
        assert_eq!(to_shell(unc, PathStyle::Native), unc);
        // WSL 下原样的反斜杠必须被引号保护，否则 bash 会把它当转义吃掉
        assert_eq!(quote_for_shell(unc, PathStyle::Wsl), format!("'{unc}'"));
    }

    #[test]
    fn backslash_in_posix_file_name_is_quoted() {
        assert_eq!(quote_for_shell(r"/tmp/a\b", PathStyle::Msys), r"'/tmp/a\b'");
        assert_eq!(quote_for_shell("/tmp/$HOME", PathStyle::Wsl), "'/tmp/$HOME'");
        assert_eq!(quote_for_shell("/tmp/plain-name_1.txt", PathStyle::Wsl), "/tmp/plain-name_1.txt");
    }
}
