//! 导入 ~/.ssh/config 的主机为只读 profile（不写入配置文件）

use std::path::{Path, PathBuf};

use crate::config::{Profile, ProfileKind, SshOptions};

pub const GROUP_ID: &str = "ssh-config";

/// Include 嵌套上限，同 OpenSSH，防循环引用
const MAX_INCLUDE_DEPTH: usize = 16;

pub fn import() -> Vec<Profile> {
    let ssh_dir = crate::paths::home_dir().join(".ssh");
    match std::fs::read_to_string(ssh_dir.join("config")) {
        Ok(content) => parse(&content, &ssh_dir),
        Err(_) => Vec::new(),
    }
}

/// ssh_dir：~/.ssh 目录。Include 的相对路径相对它，~ 取它的上级目录（测试时指向临时目录）
pub fn parse(content: &str, ssh_dir: &Path) -> Vec<Profile> {
    let mut parser = Parser { ssh_dir, profiles: Vec::new() };
    parser.parse_lines(content, &mut Vec::new(), 0, false);
    parser.profiles
}

struct Parser<'a> {
    ssh_dir: &'a Path,
    profiles: Vec<Profile>,
}

/// ~ 取 ~/.ssh 的上级目录
fn home(ssh_dir: &Path) -> &Path {
    ssh_dir.parent().unwrap_or(ssh_dir)
}

fn expand_home(path: &str, ssh_dir: &Path) -> String {
    if let Some(rest) = path.strip_prefix("~/") {
        return home(ssh_dir).join(rest).display().to_string();
    }
    path.to_string()
}

impl Parser<'_> {
    /// current：当前 Host 块对应的 profile 下标。
    /// in_host_include：本文件是在具体主机的 Host 块里被 Include 的。OpenSSH 只在外层块匹配时才读它，
    /// 其中的 Host 块要内外两层同时匹配才生效，所以这里不从中新建主机，只把开头的配置项归给外层块
    fn parse_lines(&mut self, content: &str, current: &mut Vec<usize>, depth: usize, in_host_include: bool) {
        // 当前块只列了具体主机名（没有通配符）
        let mut concrete_block = false;
        let ssh_dir = self.ssh_dir;
        for raw in content.lines() {
            let line = raw.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let (key, raw_value) = match line.split_once(|c: char| c.is_whitespace() || c == '=') {
                Some((key, value)) => (key.to_lowercase(), value.trim().trim_start_matches('=').trim()),
                None => continue,
            };
            // ProxyCommand / Include 取原文（命令里的引号要保留）；其余配置项去掉两端引号
            let value = raw_value.trim_matches('"').to_string();
            if key == "host" {
                current.clear();
                concrete_block = false;
                if in_host_include {
                    continue;
                }
                let mut wildcard = false;
                for alias in value.split_whitespace() {
                    // 通配符块是给其他主机的默认值，不是可连接的主机
                    if alias.contains('*') || alias.contains('?') || alias.starts_with('!') {
                        wildcard |= !alias.starts_with('!');
                        continue;
                    }
                    current.push(self.profile_index(alias));
                }
                concrete_block = !current.is_empty() && !wildcard;
                continue;
            }
            if key == "match" {
                current.clear();
                concrete_block = false;
                continue;
            }
            if key == "include" {
                self.include(raw_value, current, depth, in_host_include || concrete_block);
                continue;
            }
            for &index in current.iter() {
                let ProfileKind::Ssh(options) = &mut self.profiles[index].kind else { continue };
                match key.as_str() {
                    "hostname" => options.host = value.clone(),
                    "user" => options.user = value.clone(),
                    "port" => options.port = value.parse().unwrap_or(22),
                    "identityfile" => options.private_keys.push(expand_home(&value, ssh_dir)),
                    "proxyjump" if value != "none" => {
                        // 只支持单级别名跳板；user@host:port 形式和多级链不导入
                        let first = value.split(',').next().unwrap_or_default();
                        if !first.contains('@') && !first.contains(':') {
                            options.jump_host = format!("{GROUP_ID}:{first}");
                        }
                    }
                    "proxycommand" if value != "none" => options.proxy_command = raw_value.to_string(),
                    "forwardagent" => options.agent_forward = value.eq_ignore_ascii_case("yes"),
                    "serveraliveinterval" => options.keepalive_interval = value.parse().unwrap_or(30),
                    _ => {}
                }
            }
        }
    }

    /// 同名主机在多个块 / 多个文件里出现时共用一个 profile，避免重复 id
    fn profile_index(&mut self, alias: &str) -> usize {
        let id = format!("{GROUP_ID}:{alias}");
        if let Some(index) = self.profiles.iter().position(|profile| profile.id == id) {
            return index;
        }
        self.profiles.push(Profile {
            id,
            name: alias.to_string(),
            group: GROUP_ID.into(),
            icon: "server".into(),
            is_builtin: true,
            kind: ProfileKind::Ssh(SshOptions { host: alias.to_string(), ..Default::default() }),
            ..Default::default()
        });
        self.profiles.len() - 1
    }

    /// 就地展开 Include。被包含文件从外层块的语境开始，读完回到外层块（OpenSSH 同样在 Include 结束后恢复）
    fn include(&mut self, value: &str, current: &[usize], depth: usize, in_host_include: bool) {
        if depth >= MAX_INCLUDE_DEPTH {
            crate::log::warn("~/.ssh/config 的 Include 嵌套超过 16 层，更深的文件已忽略");
            return;
        }
        // ponytail: 按空白分隔多个路径，带空格的引号路径不支持
        for pattern in value.split_whitespace() {
            for path in self.expand_include(pattern.trim_matches('"')) {
                let Ok(content) = std::fs::read_to_string(&path) else { continue };
                let mut inner = current.to_vec();
                self.parse_lines(&content, &mut inner, depth + 1, in_host_include);
            }
        }
    }

    /// Include 的一个路径：~ 展开、相对路径相对 ~/.ssh，文件名部分支持 * ? 通配，按字母序
    fn expand_include(&self, pattern: &str) -> Vec<PathBuf> {
        let path = match pattern.strip_prefix("~/") {
            Some(rest) => home(self.ssh_dir).join(rest),
            // 绝对路径 join 后仍是它自己
            None => self.ssh_dir.join(pattern),
        };
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else { return Vec::new() };
        if !name.contains(['*', '?']) {
            return vec![path];
        }
        // ponytail: 只有最后一段支持通配，目录层的通配（如 ~/.ssh/*/config）不展开
        let Some(dir) = path.parent() else { return Vec::new() };
        let Ok(entries) = std::fs::read_dir(dir) else { return Vec::new() };
        let pattern: Vec<char> = name.chars().collect();
        let mut matched = Vec::new();
        for entry in entries.flatten() {
            let file_name = entry.file_name().to_string_lossy().into_owned();
            // 同 glob(3)：通配符不匹配开头的点
            if file_name.starts_with('.') && !name.starts_with('.') {
                continue;
            }
            let text: Vec<char> = file_name.chars().collect();
            if wildcard_match(&pattern, &text) {
                matched.push(entry.path());
            }
        }
        matched.sort();
        matched
    }
}

/// * 任意多个字符、? 单个字符
fn wildcard_match(pattern: &[char], text: &[char]) -> bool {
    match (pattern.first(), text.first()) {
        (None, None) => true,
        (Some('*'), _) => wildcard_match(&pattern[1..], text) || (!text.is_empty() && wildcard_match(pattern, &text[1..])),
        (Some('?'), Some(_)) => wildcard_match(&pattern[1..], &text[1..]),
        (Some(expected), Some(actual)) if expected == actual => wildcard_match(&pattern[1..], &text[1..]),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ssh(profile: &Profile) -> &SshOptions {
        let ProfileKind::Ssh(options) = &profile.kind else { panic!() };
        options
    }

    fn names(profiles: &[Profile]) -> Vec<&str> {
        profiles.iter().map(|profile| profile.name.as_str()).collect()
    }

    /// 临时的 home 目录，返回其中的 .ssh
    fn temp_ssh_dir(name: &str, files: &[(&str, &str)]) -> PathBuf {
        let home = std::env::temp_dir().join(format!("cterm-sshcfg-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        let ssh_dir = home.join(".ssh");
        for (path, content) in files {
            let path = ssh_dir.join(path);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, content).unwrap();
        }
        ssh_dir
    }

    #[test]
    fn parses_hosts_and_skips_wildcards() {
        let profiles = parse(
            "Host *\n  User nobody\n\nHost web web-alias\n  HostName 192.0.2.5\n  User deploy\n  Port 2222\n  ProxyJump bastion\n\nHost bastion\n  HostName=bastion.example.com\n  IdentityFile /tmp/key\n  ProxyCommand ssh -W %h:%p \"gw.example.com\"\n",
            Path::new("/nonexistent/.ssh"),
        );
        assert_eq!(names(&profiles), ["web", "web-alias", "bastion"]);
        let web = ssh(&profiles[0]);
        assert_eq!((web.host.as_str(), web.user.as_str(), web.port), ("192.0.2.5", "deploy", 2222));
        assert_eq!(web.jump_host, "ssh-config:bastion");
        let bastion = ssh(&profiles[2]);
        assert_eq!(bastion.host, "bastion.example.com");
        assert_eq!(bastion.private_keys, ["/tmp/key"]);
        // 命令里的引号原样保留
        assert_eq!(bastion.proxy_command, "ssh -W %h:%p \"gw.example.com\"");
    }

    #[test]
    fn include_expands_in_place_with_glob_home_and_relative_paths() {
        let ssh_dir = temp_ssh_dir(
            "glob",
            &[
                ("config.d/b", "Host b-host\n  HostName 192.0.2.3\n"),
                ("config.d/a", "Host a-host\n  HostName 192.0.2.2\n  IdentityFile ~/.ssh/id_a\n"),
                ("config.d/.hidden", "Host hidden\n"),
                ("extra.conf", "Host extra\n  ProxyCommand none\n"),
            ],
        );
        let profiles = parse("Include ~/.ssh/config.d/* extra.conf missing.conf\nHost main\n  HostName 192.0.2.1\n", &ssh_dir);
        assert_eq!(names(&profiles), ["a-host", "b-host", "extra", "main"]);
        assert_eq!(ssh(&profiles[0]).host, "192.0.2.2");
        assert_eq!(ssh(&profiles[0]).private_keys, [ssh_dir.join("id_a").display().to_string()]);
        assert_eq!(ssh(&profiles[2]).proxy_command, "");
        let _ = std::fs::remove_dir_all(ssh_dir.parent().unwrap());
    }

    #[test]
    fn include_inside_host_block_belongs_to_that_block() {
        let ssh_dir = temp_ssh_dir(
            "block",
            &[
                ("web.conf", "User deploy\nHost inner\n  HostName 198.51.100.1\n"),
                ("all.conf", "Host starred\n  HostName 198.51.100.2\n"),
            ],
        );
        let profiles = parse("Host web\n  HostName 192.0.2.5\n  Include web.conf\n  Port 2200\nHost *\n  Include all.conf\n", &ssh_dir);
        // 具体主机块里的 Include：开头的配置项归 web，其中的 Host 不导入；读完回到 web 块（Port 仍归 web）
        // 通配块里的 Include：其中的 Host 对所有主机都可能生效，照常导入
        assert_eq!(names(&profiles), ["web", "starred"]);
        let web = ssh(&profiles[0]);
        assert_eq!((web.user.as_str(), web.port), ("deploy", 2200));
        let _ = std::fs::remove_dir_all(ssh_dir.parent().unwrap());
    }

    #[test]
    fn include_loop_stops_and_duplicate_hosts_merge() {
        let ssh_dir = temp_ssh_dir("loop", &[("loop.conf", "Include loop.conf\nHost looped\n  User u\n")]);
        let profiles = parse("Include loop.conf\nHost looped\n  Port 2022\n", &ssh_dir);
        assert_eq!(names(&profiles), ["looped"]);
        assert_eq!((ssh(&profiles[0]).user.as_str(), ssh(&profiles[0]).port), ("u", 2022));
        let _ = std::fs::remove_dir_all(ssh_dir.parent().unwrap());
    }

    #[test]
    fn wildcards() {
        let matches = |pattern: &str, text: &str| wildcard_match(&pattern.chars().collect::<Vec<_>>(), &text.chars().collect::<Vec<_>>());
        assert!(matches("*", "orbstack"));
        assert!(matches("*.conf", "a.conf"));
        assert!(!matches("*.conf", "a.conf.bak"));
        assert!(matches("h?st*", "host1"));
        assert!(!matches("h?st", "hst"));
    }
}
