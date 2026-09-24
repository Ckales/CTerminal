//! Rust 侧的提示语翻译（SSH 交互提示、连接错误等会直接显示给用户）。
//! 与界面层同一套做法：源码写中文，英文时查表，{name} 为占位符。

use std::fmt::Display;
use std::sync::atomic::{AtomicBool, Ordering};

static ENGLISH: AtomicBool = AtomicBool::new(false);

/// code: zh / en（由界面层按设置解析后传入）
pub fn set_language(code: &str) {
    ENGLISH.store(code == "en", Ordering::Relaxed);
}

/// 带占位符的翻译：trf!("连接 {host} 失败", host = name)
#[macro_export]
macro_rules! trf {
    ($source:expr, $($name:ident = $value:expr),* $(,)?) => {
        $crate::i18n::trf_args($source, &[$((stringify!($name), &$value as &(dyn std::fmt::Display + Sync))),*])
    };
}

pub fn tr(source: &str) -> String {
    trf_args(source, &[])
}

pub fn trf_args(source: &str, args: &[(&str, &(dyn Display + Sync))]) -> String {
    let mut text = if ENGLISH.load(Ordering::Relaxed) {
        english(source).unwrap_or(source).to_string()
    } else {
        source.to_string()
    };
    for (name, value) in args {
        text = text.replace(&format!("{{{name}}}"), &value.to_string());
    }
    text
}

fn english(source: &str) -> Option<&'static str> {
    let translated = match source {
        "无法启动 {command}：{err}" => "Failed to start {command}: {err}",
        "正在连接 {host}:{port} …" => "Connecting to {host}:{port} …",
        "连接 {host}:{port} 失败：{err}" => "Failed to connect to {host}:{port}: {err}",
        "连接 {host}:{port} 超时" => "Connection to {host}:{port} timed out",
        "无法打开串口 {port}：{err}" => "Failed to open serial port {port}: {err}",
        "进程已退出，退出码 {code}" => "Process exited with code {code}",
        "进程异常结束：{err}" => "Process ended abnormally: {err}",
        "配置文件格式错误：{err}" => "Config file is not valid JSON: {err}",
        "配置文件内容错误：{err}" => "Config file has invalid content: {err}",
        "读取配置失败：{err}" => "Failed to read config: {err}",
        "创建配置目录失败：{err}" => "Failed to create config directory: {err}",
        "写入配置失败：{err}" => "Failed to write config: {err}",
        "串口已断开：{err}" => "Serial port disconnected: {err}",
        "无法解析主机名" => "Could not resolve host name",
        "连接已被远端关闭" => "Connection closed by the remote host",
        "连接中断：{err}" => "Connection lost: {err}",
        "无法访问系统钥匙串：{err}" => "Cannot access the system keychain: {err}",
        "保存到钥匙串失败：{err}" => "Failed to save to the keychain: {err}",
        "从钥匙串删除失败：{err}" => "Failed to delete from the keychain: {err}",
        "{action}失败：{err}" => "{action} failed: {err}",
        "启动 SFTP" => "Starting SFTP",
        "读取主目录" => "Reading home directory",
        "读取目录" => "Reading directory",
        "新建文件夹" => "Creating folder",
        "重命名" => "Renaming",
        "删除" => "Deleting",
        "打开远端文件" => "Opening remote file",
        "创建本地文件" => "Creating local file",
        "下载" => "Downloading",
        "写入本地文件" => "Writing local file",
        "保存文件" => "Saving file",
        "读取本地目录" => "Reading local directory",
        "打开本地文件" => "Opening local file",
        "创建远端文件" => "Creating remote file",
        "读取本地文件" => "Reading local file",
        "上传" => "Uploading",
        "SSH 尚未连接成功" => "SSH is not connected yet",
        "打开通道失败：{err}" => "Failed to open channel: {err}",
        "服务器不支持 {name}：{err}" => "The server does not support {name}: {err}",
        "连接已关闭" => "Connection closed",
        "无法确认主机 {host}:{port} 的真实性。" => "The authenticity of host {host}:{port} can't be established.",
        "{algorithm} 密钥指纹：{fingerprint}" => "{algorithm} key fingerprint is {fingerprint}",
        "是否信任并保存到 known_hosts？(yes/no/once) " => "Trust it and save to known_hosts? (yes/no/once) ",
        "写入 known_hosts 失败：{err}" => "Failed to write known_hosts: {err}",
        "警告：主机 {host}:{port} 的密钥已变更！" => "WARNING: the host key for {host}:{port} has changed!",
        "可能有人正在进行中间人攻击，也可能是服务器重装了系统。" => "Someone could be eavesdropping on you (man-in-the-middle), or the server was reinstalled.",
        "known_hosts 第 {line} 行记录的密钥与本次不同。" => "The key recorded on line {line} of known_hosts is different.",
        "新的 {algorithm} 密钥指纹：{fingerprint}" => "New {algorithm} key fingerprint: {fingerprint}",
        "仍然继续连接（本次）？(yes/no) " => "Continue connecting anyway (this time only)? (yes/no) ",
        "读取 known_hosts 失败：{err}" => "Failed to read known_hosts: {err}",
        "是否继续连接？(yes/no) " => "Continue connecting? (yes/no) ",
        "不是 SSH 配置" => "Not an SSH profile",
        "打开会话失败：{err}" => "Failed to open session: {err}",
        "申请终端失败：{err}" => "Failed to request a terminal: {err}",
        "启动 shell 失败：{err}" => "Failed to start shell: {err}",
        "连接已断开" => "Disconnected",
        "远端 shell 已退出，退出码 {code}" => "Remote shell exited with code {code}",
        "跳板机层级过深，可能存在循环引用" => "Too many jump hosts; there may be a loop",
        "找不到跳板机配置" => "Jump host profile not found",
        "跳板机必须是 SSH 配置" => "The jump host must be an SSH profile",
        "经由 {jump} 连接 {host}:{port} …" => "Connecting to {host}:{port} via {jump} …",
        "跳板机转发失败：{err}" => "Jump host forwarding failed: {err}",
        "经跳板机连接超时" => "Connection through the jump host timed out",
        "经跳板机连接失败：{err}" => "Connection through the jump host failed: {err}",
        "{host} 的用户名：" => "Username for {host}: ",
        "已取消" => "Cancelled",
        "认证出错：{err}" => "Authentication error: {err}",
        "私钥不存在：{path}" => "Private key not found: {path}",
        "钥匙串中保存的密码已失效" => "The password saved in the keychain no longer works",
        "{user}@{host} 的密码：" => "{user}@{host}'s password: ",
        "密码错误" => "Wrong password",
        "认证失败：没有可用的认证方式通过" => "Authentication failed: no method succeeded",
        "无法读取私钥 {path}：{err}" => "Cannot read private key {path}: {err}",
        "私钥 {path} 的口令：" => "Passphrase for {path}: ",
        "口令错误" => "Wrong passphrase",
        "保存到系统钥匙串，下次自动使用？(y/N) " => "Save to the system keychain for next time? (y/N) ",
        "已保存" => "Saved",
        "远程转发 {bind}:{port} → {target}:{target_port}" => "Remote forward {bind}:{port} → {target}:{target_port}",
        "远程转发 {port} 失败：{err}" => "Remote forward {port} failed: {err}",
        "监听 {bind}:{port} 失败：{err}" => "Failed to listen on {bind}:{port}: {err}",
        "SOCKS 代理 {bind}:{port}" => "SOCKS proxy {bind}:{port}",
        "本地转发 {bind}:{port} → {target}:{target_port}" => "Local forward {bind}:{port} → {target}:{target_port}",
        _ => return None,
    };
    Some(translated)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn templates_and_fallback() {
        set_language("en");
        assert_eq!(crate::trf!("连接 {host}:{port} 超时", host = "example.com", port = 22), "Connection to example.com:22 timed out");
        assert_eq!(tr("没有翻译的句子"), "没有翻译的句子");
        set_language("zh");
        assert_eq!(crate::trf!("连接 {host}:{port} 超时", host = "example.com", port = 22), "连接 example.com:22 超时");
    }
}
