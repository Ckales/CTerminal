//! 导入 ~/.ssh/config 的主机为只读 profile（不写入配置文件）

use crate::config::{Profile, ProfileKind, SshOptions};

pub const GROUP_ID: &str = "ssh-config";

pub fn import() -> Vec<Profile> {
    let path = crate::paths::home_dir().join(".ssh").join("config");
    match std::fs::read_to_string(path) {
        Ok(content) => parse(&content),
        Err(_) => Vec::new(),
    }
}

fn expand_home(path: &str) -> String {
    if let Some(rest) = path.strip_prefix("~/") {
        return crate::paths::home_dir().join(rest).display().to_string();
    }
    path.to_string()
}

pub fn parse(content: &str) -> Vec<Profile> {
    let mut profiles: Vec<Profile> = Vec::new();
    let mut current: Vec<usize> = Vec::new();
    for raw in content.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (key, value) = match line.split_once(|c: char| c.is_whitespace() || c == '=') {
            Some((key, value)) => (key.to_lowercase(), value.trim().trim_start_matches('=').trim().trim_matches('"').to_string()),
            None => continue,
        };
        if key == "host" {
            current.clear();
            for alias in value.split_whitespace() {
                // 通配符块是给其他主机的默认值，不是可连接的主机
                if alias.contains('*') || alias.contains('?') || alias.starts_with('!') {
                    continue;
                }
                profiles.push(Profile {
                    id: format!("{GROUP_ID}:{alias}"),
                    name: alias.to_string(),
                    group: GROUP_ID.into(),
                    icon: "server".into(),
                    is_builtin: true,
                    kind: ProfileKind::Ssh(SshOptions { host: alias.to_string(), ..Default::default() }),
                    ..Default::default()
                });
                current.push(profiles.len() - 1);
            }
            continue;
        }
        if key == "match" {
            current.clear();
            continue;
        }
        for &index in &current {
            let ProfileKind::Ssh(options) = &mut profiles[index].kind else { continue };
            match key.as_str() {
                "hostname" => options.host = value.clone(),
                "user" => options.user = value.clone(),
                "port" => options.port = value.parse().unwrap_or(22),
                "identityfile" => options.private_keys.push(expand_home(&value)),
                "proxyjump" if value != "none" => {
                    // 只支持单级别名跳板；user@host:port 形式和多级链不导入
                    let first = value.split(',').next().unwrap_or_default();
                    if !first.contains('@') && !first.contains(':') {
                        options.jump_host = format!("{GROUP_ID}:{first}");
                    }
                }
                "forwardagent" => options.agent_forward = value.eq_ignore_ascii_case("yes"),
                "serveraliveinterval" => options.keepalive_interval = value.parse().unwrap_or(30),
                _ => {}
            }
        }
    }
    profiles
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_hosts_and_skips_wildcards() {
        let profiles = parse(
            "Host *\n  User nobody\n\nHost web web-alias\n  HostName 192.0.2.5\n  User deploy\n  Port 2222\n  ProxyJump bastion\n\nHost bastion\n  HostName=bastion.example.com\n  IdentityFile /tmp/key\n",
        );
        let names: Vec<&str> = profiles.iter().map(|profile| profile.name.as_str()).collect();
        assert_eq!(names, ["web", "web-alias", "bastion"]);
        let ProfileKind::Ssh(web) = &profiles[0].kind else { panic!() };
        assert_eq!((web.host.as_str(), web.user.as_str(), web.port), ("192.0.2.5", "deploy", 2222));
        assert_eq!(web.jump_host, "ssh-config:bastion");
        let ProfileKind::Ssh(bastion) = &profiles[2].kind else { panic!() };
        assert_eq!(bastion.host, "bastion.example.com");
        assert_eq!(bastion.private_keys, ["/tmp/key"]);
    }
}
