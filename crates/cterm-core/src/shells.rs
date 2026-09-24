//! 本地 shell 探测：生成「本地」分组下的内置 Profile

use serde::{Deserialize, Serialize};

use crate::paths::PathStyle;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DetectedShell {
    /// 稳定 id，用作内置 profile 的 id 后缀
    pub id: String,
    pub name: String,
    pub command: String,
    pub args: Vec<String>,
    pub icon: String,
}

impl DetectedShell {
    pub fn path_style(&self) -> PathStyle {
        path_style_of(&self.id)
    }
}

pub fn path_style_of(shell_id: &str) -> PathStyle {
    if shell_id.starts_with("wsl") {
        return PathStyle::Wsl;
    }
    match shell_id {
        "git-bash" | "msys2" => PathStyle::Msys,
        "cygwin" => PathStyle::Cygwin,
        _ => PathStyle::Native,
    }
}

/// 用户默认 shell（$SHELL / %COMSPEC%）
pub fn default_shell() -> DetectedShell {
    let shells = detect();
    if cfg!(windows) {
        // 与 Windows Terminal 一致：优先 PowerShell 7，其次 Windows PowerShell，最后 CMD
        for preferred in ["pwsh", "powershell", "cmd"] {
            if let Some(shell) = shells.iter().find(|shell| shell.id == preferred) {
                return shell.clone();
            }
        }
    }
    let user_shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
    shells
        .iter()
        .find(|shell| shell.command == user_shell)
        .cloned()
        .unwrap_or_else(|| unix_shell(&user_shell))
}

fn unix_shell(path: &str) -> DetectedShell {
    let name = path.rsplit('/').next().unwrap_or(path).to_string();
    DetectedShell {
        id: name.clone(),
        name,
        command: path.to_string(),
        // macOS 终端的惯例：登录 shell，才会读 ~/.zprofile 里的 PATH
        args: vec!["-l".into()],
        icon: "terminal".into(),
    }
}

#[cfg(not(windows))]
pub fn detect() -> Vec<DetectedShell> {
    let content = std::fs::read_to_string("/etc/shells").unwrap_or_default();
    let mut shells = parse_etc_shells(&content);
    shells.retain(|shell| std::path::Path::new(&shell.command).exists());
    shells
}

#[cfg_attr(windows, allow(dead_code))]
fn parse_etc_shells(content: &str) -> Vec<DetectedShell> {
    let mut shells: Vec<DetectedShell> = Vec::new();
    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let shell = unix_shell(line);
        // /bin/zsh 与 /usr/local/bin/zsh 同名时保留第一个
        if shells.iter().any(|existing| existing.id == shell.id) {
            continue;
        }
        shells.push(shell);
    }
    shells.sort_by(|a, b| a.name.cmp(&b.name));
    shells
}

#[cfg(windows)]
pub fn detect() -> Vec<DetectedShell> {
    use std::path::Path;

    let mut shells = Vec::new();
    let system_root = std::env::var("SystemRoot").unwrap_or_else(|_| r"C:\Windows".into());
    shells.push(DetectedShell {
        id: "cmd".into(),
        name: "CMD".into(),
        command: format!(r"{system_root}\System32\cmd.exe"),
        args: vec![],
        icon: "cmd".into(),
    });
    shells.push(DetectedShell {
        id: "powershell".into(),
        name: "PowerShell".into(),
        command: format!(r"{system_root}\System32\WindowsPowerShell\v1.0\powershell.exe"),
        args: vec!["-nologo".into()],
        icon: "powershell".into(),
    });
    let program_files = std::env::var("ProgramFiles").unwrap_or_else(|_| r"C:\Program Files".into());
    let pwsh = format!(r"{program_files}\PowerShell\7\pwsh.exe");
    if Path::new(&pwsh).exists() {
        shells.push(DetectedShell {
            id: "pwsh".into(),
            name: "PowerShell Core".into(),
            command: pwsh,
            args: vec!["-nologo".into()],
            icon: "powershell".into(),
        });
    }
    let git_bash = format!(r"{program_files}\Git\bin\bash.exe");
    if Path::new(&git_bash).exists() {
        shells.push(DetectedShell {
            id: "git-bash".into(),
            name: "Git-Bash".into(),
            command: git_bash,
            args: vec!["--login".into(), "-i".into()],
            icon: "git".into(),
        });
    }
    for (id, path) in [("msys2", r"C:\msys64\usr\bin\bash.exe"), ("cygwin", r"C:\cygwin64\bin\bash.exe")] {
        if Path::new(path).exists() {
            shells.push(DetectedShell {
                id: id.into(),
                name: if id == "msys2" { "MSYS2".into() } else { "Cygwin".into() },
                command: path.into(),
                args: vec!["--login".into(), "-i".into()],
                icon: "terminal".into(),
            });
        }
    }
    shells.extend(detect_wsl(&system_root));
    shells
}

#[cfg(windows)]
fn detect_wsl(system_root: &str) -> Vec<DetectedShell> {
    use std::os::windows::process::CommandExt;

    let wsl = format!(r"{system_root}\System32\wsl.exe");
    if !std::path::Path::new(&wsl).exists() {
        return Vec::new();
    }
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let output = std::process::Command::new(&wsl)
        .args(["--list", "--quiet"])
        .creation_flags(CREATE_NO_WINDOW)
        .output();
    let Ok(output) = output else { return Vec::new() };
    // wsl.exe 输出 UTF-16LE
    let units: Vec<u16> = output.stdout.chunks_exact(2).map(|pair| u16::from_le_bytes([pair[0], pair[1]])).collect();
    let text = String::from_utf16_lossy(&units);
    let mut shells = Vec::new();
    for distro in text.lines() {
        let distro = distro.trim().trim_matches('\0');
        if distro.is_empty() {
            continue;
        }
        shells.push(DetectedShell {
            id: format!("wsl-{}", distro.to_lowercase()),
            name: format!("WSL / {distro}"),
            command: wsl.clone(),
            args: vec!["-d".into(), distro.into()],
            icon: "linux".into(),
        });
    }
    shells
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn etc_shells_dedup_and_login() {
        let shells = parse_etc_shells("# comment\n/bin/zsh\n/bin/bash\n/usr/local/bin/zsh\n\n/bin/sh\n");
        let names: Vec<&str> = shells.iter().map(|shell| shell.name.as_str()).collect();
        assert_eq!(names, ["bash", "sh", "zsh"]);
        assert_eq!(shells[2].command, "/bin/zsh");
        assert_eq!(shells[0].args, ["-l"]);
    }

    #[test]
    fn path_styles() {
        assert_eq!(path_style_of("wsl-ubuntu"), PathStyle::Wsl);
        assert_eq!(path_style_of("git-bash"), PathStyle::Msys);
        assert_eq!(path_style_of("zsh"), PathStyle::Native);
    }
}
