//! SSH（russh）。所有交互提示（主机指纹、密码、口令、键盘交互）都直接写在终端里，
//! 用户在终端里作答，界面层不需要知道 SSH 的任何细节。

use std::io;
use std::path::PathBuf;
use std::pin::Pin;
use std::process::Stdio;
use std::task::{Context, Poll};
use std::sync::mpsc::Sender;
use std::sync::{Arc, LazyLock};
use std::time::Duration;

use russh::client::{self, AuthResult, Handle, KeyboardInteractiveAuthResponse};
use russh::keys::agent::client::AgentClient;
use russh::keys::known_hosts::{check_known_hosts_path, learn_known_hosts_path};
use russh::keys::{HashAlg, PrivateKeyWithHashAlg, PublicKey, PublicKeyOrCertificate};
use russh::{Channel, ChannelMsg, Disconnect};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader, ReadBuf};
use tokio::net::{TcpListener, TcpStream};
use tokio::process::{Child, ChildStdin, ChildStdout};
use tokio::sync::{mpsc, Mutex};

use crate::i18n::tr;
use crate::config::{ForwardedPort, Profile, ProfileKind, SshOptions, SshSettings};
use crate::{log, secrets};
use crate::session::{Output, Transport, WinSize};

pub static RUNTIME: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_name("cterm-net")
        .enable_all()
        .build()
        .expect("tokio runtime")
});

enum Command {
    Data(Vec<u8>),
    Resize(WinSize),
    Close,
}

pub struct SshTransport {
    commands: mpsc::UnboundedSender<Command>,
    shared: Arc<SshShared>,
}

/// 认证完成后的连接，供 SFTP 等在同一条连接上开新通道（不用再认证一次）
#[derive(Default)]
pub struct SshShared {
    handle: std::sync::OnceLock<Arc<Handle<HostCheck>>>,
}

impl SshShared {
    pub(crate) async fn open_subsystem(&self, name: &str) -> Result<russh::ChannelStream<client::Msg>, String> {
        let handle = self.handle.get().ok_or_else(|| tr("SSH 尚未连接成功"))?;
        let channel = handle.channel_open_session().await.map_err(|err| trf!("打开通道失败：{err}", err = err))?;
        channel.request_subsystem(true, name).await.map_err(|err| trf!("服务器不支持 {name}：{err}", name = name, err = err))?;
        Ok(channel.into_stream())
    }
}

impl Transport for SshTransport {
    fn write(&mut self, data: &[u8]) -> io::Result<()> {
        self.commands.send(Command::Data(data.to_vec())).map_err(|_| io::Error::other(tr("连接已关闭")))
    }

    fn resize(&mut self, size: WinSize) {
        let _ = self.commands.send(Command::Resize(size));
    }

    fn close(&mut self) {
        let _ = self.commands.send(Command::Close);
    }

    fn ssh(&self) -> Option<Arc<SshShared>> {
        Some(self.shared.clone())
    }
}

/// 在终端里提问并读取用户输入的一行
struct Prompter {
    out: Sender<Output>,
    commands: mpsc::UnboundedReceiver<Command>,
    size: WinSize,
}

impl Prompter {
    fn print(&self, text: &str) {
        let _ = self.out.send(Output::Data(text.replace('\n', "\r\n").into_bytes()));
    }

    fn info(&self, text: &str) {
        let _ = self.out.send(dim(text));
    }

    /// Ctrl-C / 关闭标签 → None
    async fn read_line(&mut self, prompt: &str, echo: bool) -> Option<String> {
        self.print(prompt);
        let mut line: Vec<u8> = Vec::new();
        loop {
            match self.commands.recv().await {
                None | Some(Command::Close) => return None,
                Some(Command::Resize(size)) => self.size = size,
                Some(Command::Data(bytes)) => {
                    for byte in bytes {
                        match byte {
                            b'\r' | b'\n' => {
                                self.print("\n");
                                return Some(String::from_utf8_lossy(&line).into_owned());
                            }
                            0x03 => {
                                self.print("^C\n");
                                return None;
                            }
                            0x7f | 0x08 => {
                                // 按 UTF-8 回退一个完整字符
                                while let Some(last) = line.pop() {
                                    if last & 0xc0 != 0x80 {
                                        break;
                                    }
                                }
                                if echo {
                                    self.print("\x08 \x08");
                                }
                            }
                            byte if byte >= 0x20 => {
                                line.push(byte);
                                if echo {
                                    let _ = self.out.send(Output::Data(vec![byte]));
                                }
                            }
                            _ => {}
                        }
                    }
                }
            }
        }
    }

    async fn confirm(&mut self, prompt: &str) -> bool {
        matches!(self.read_line(prompt, true).await.as_deref().map(str::trim), Some("y" | "yes" | "Y" | "YES"))
    }
}

/// 暗色的一行提示（连接过程信息、代理命令的 stderr）
fn dim(text: &str) -> Output {
    Output::Data(format!("\x1b[2m{text}\x1b[0m\n").replace('\n', "\r\n").into_bytes())
}

type SharedPrompter = Arc<Mutex<Prompter>>;

struct HostCheck {
    host: String,
    port: u16,
    known_hosts: PathBuf,
    verify: bool,
    prompter: SharedPrompter,
    /// 远程端口转发：服务器端口 → 本地目标
    remote_forwards: Vec<ForwardedPort>,
    /// 本次已接受的主机密钥。重新协商密钥时会再次校验，此时主循环正占着 prompter，不能再提问
    accepted: Option<PublicKey>,
}

impl client::Handler for HostCheck {
    type Error = russh::Error;

    async fn check_server_key(&mut self, server_key: &PublicKeyOrCertificate) -> Result<bool, Self::Error> {
        if !self.verify {
            return Ok(true);
        }
        let key = server_key.public_key();
        if self.accepted.as_ref() == Some(&key) {
            return Ok(true);
        }
        let accepted = self.verify_key(&key).await;
        if accepted {
            self.accepted = Some(key);
        }
        Ok(accepted)
    }

    async fn auth_banner(&mut self, banner: &str, _session: &mut client::Session) -> Result<(), Self::Error> {
        self.prompter.lock().await.print(banner);
        Ok(())
    }

    async fn server_channel_open_forwarded_tcpip(
        &mut self,
        channel: Channel<client::Msg>,
        _connected_address: &str,
        connected_port: u32,
        _originator_address: &str,
        _originator_port: u32,
        _reply: client::ChannelOpenHandle,
        _session: &mut client::Session,
    ) -> Result<(), Self::Error> {
        let target = self
            .remote_forwards
            .iter()
            .find(|forward| forward.port as u32 == connected_port)
            .map(|forward| (forward.target_address.clone(), forward.target_port));
        if let Some((address, port)) = target {
            tokio::spawn(async move {
                if let Ok(mut socket) = TcpStream::connect((address.as_str(), port)).await {
                    let mut stream = channel.into_stream();
                    let _ = tokio::io::copy_bidirectional(&mut socket, &mut stream).await;
                }
            });
        }
        Ok(())
    }
}

impl HostCheck {
    async fn verify_key(&self, key: &PublicKey) -> bool {
        let checked = check_known_hosts_path(&self.host, self.port, key, &self.known_hosts);
        if let Ok(true) = checked {
            return true;
        }
        let fingerprint = key.fingerprint(HashAlg::Sha256);
        let algorithm = key.algorithm();
        let mut prompter = self.prompter.lock().await;
        match checked {
            Ok(true) => true,
            Ok(false) => {
                let unknown = trf!("无法确认主机 {host}:{port} 的真实性。", host = self.host, port = self.port);
                let print = trf!("{algorithm} 密钥指纹：{fingerprint}", algorithm = algorithm, fingerprint = fingerprint);
                prompter.print(&format!("\x1b[33m{unknown}\x1b[0m\n{print}\n"));
                let answer = prompter.read_line(&tr("是否信任并保存到 known_hosts？(yes/no/once) "), true).await;
                match answer.as_deref().map(str::trim) {
                    Some("yes" | "y") => {
                        if let Err(err) = learn_known_hosts_path(&self.host, self.port, key, &self.known_hosts) {
                            prompter.info(&trf!("写入 known_hosts 失败：{err}", err = err));
                        }
                        true
                    }
                    Some("once" | "o") => true,
                    _ => false,
                }
            }
            Err(russh::keys::Error::KeyChanged { line }) => {
                let warning = trf!("警告：主机 {host}:{port} 的密钥已变更！", host = self.host, port = self.port);
                let reason = tr("可能有人正在进行中间人攻击，也可能是服务器重装了系统。");
                let recorded = trf!("known_hosts 第 {line} 行记录的密钥与本次不同。", line = line);
                let print = trf!("新的 {algorithm} 密钥指纹：{fingerprint}", algorithm = algorithm, fingerprint = fingerprint);
                prompter.print(&format!("\x1b[31;1m{warning}\x1b[0m\n\x1b[31m{reason}\n{recorded}\n{print}\x1b[0m\n"));
                prompter.confirm(&tr("仍然继续连接（本次）？(yes/no) ")).await
            }
            Err(err) => {
                prompter.info(&trf!("读取 known_hosts 失败：{err}", err = err));
                let print = trf!("{algorithm} 密钥指纹：{fingerprint}", algorithm = algorithm, fingerprint = fingerprint);
                prompter.confirm(&format!("{print}\n{}", tr("是否继续连接？(yes/no) "))).await
            }
        }
    }
}

/// 建立 SSH 连接。立即返回 transport；连接、认证在后台进行，过程信息写进终端。
pub fn connect(
    profile: &Profile,
    profiles: &[Profile],
    settings: &SshSettings,
    size: WinSize,
    out: Sender<Output>,
) -> Result<SshTransport, String> {
    let ProfileKind::Ssh(options) = &profile.kind else {
        return Err(tr("不是 SSH 配置"));
    };
    let (command_tx, command_rx) = mpsc::unbounded_channel();
    let prompter = Arc::new(Mutex::new(Prompter { out: out.clone(), commands: command_rx, size }));
    let shared = Arc::new(SshShared::default());
    let job = Job {
        profile_id: profile.id.clone(),
        options: options.clone(),
        profiles: profiles.to_vec(),
        settings: settings.clone(),
        prompter,
        shared: shared.clone(),
    };
    let target = format!("{}:{}", options.host, options.port);
    RUNTIME.spawn(async move {
        let reason = match job.run().await {
            Ok(reason) => {
                log::info(&format!("SSH {target} 会话结束：{}", if reason.is_empty() { "正常" } else { &reason }));
                reason
            }
            Err(err) => {
                log::warn(&format!("SSH {target} 失败：{err}"));
                format!("\x1b[31m{err}\x1b[0m")
            }
        };
        let _ = out.send(Output::Closed(reason));
    });
    Ok(SshTransport { commands: command_tx, shared })
}

struct Job {
    profile_id: String,
    options: SshOptions,
    profiles: Vec<Profile>,
    settings: SshSettings,
    prompter: SharedPrompter,
    shared: Arc<SshShared>,
}

fn known_hosts_path(settings: &SshSettings) -> PathBuf {
    if settings.known_hosts_file.is_empty() {
        return crate::paths::home_dir().join(".ssh").join("known_hosts");
    }
    PathBuf::from(&settings.known_hosts_file)
}

fn client_config(options: &SshOptions) -> Arc<client::Config> {
    Arc::new(client::Config {
        keepalive_interval: if options.keepalive_interval > 0 {
            Some(Duration::from_secs(options.keepalive_interval as u64))
        } else {
            None
        },
        keepalive_max: options.keepalive_count_max as usize,
        nodelay: true,
        ..Default::default()
    })
}

/// ProxyCommand 占位符，同 OpenSSH：%h 主机、%p 端口、%r 用户、%% 百分号
fn expand_proxy_command(template: &str, host: &str, port: u16, user: &str) -> Result<String, String> {
    let mut command = String::new();
    let mut chars = template.chars();
    while let Some(c) = chars.next() {
        if c != '%' {
            command.push(c);
            continue;
        }
        match chars.next() {
            Some('%') => command.push('%'),
            Some('h') => command.push_str(host),
            Some('p') => command.push_str(&port.to_string()),
            Some('r') => command.push_str(user),
            other => {
                let token = other.map(String::from).unwrap_or_default();
                return Err(trf!("代理命令含不支持的占位符：%{token}", token = token));
            }
        }
    }
    Ok(command)
}

/// ProxyCommand 子进程：stdin/stdout 组成 SSH 的传输流，stderr 暗色显示在终端里。
/// 连接结束时 russh 丢弃这个流，子进程随之被杀掉并由 tokio 回收
struct ProxyStream {
    stdin: ChildStdin,
    stdout: ChildStdout,
    _child: Child,
}

impl ProxyStream {
    fn spawn(command: &str, out: Sender<Output>) -> io::Result<ProxyStream> {
        let mut process = proxy_process(command);
        process.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).kill_on_drop(true);
        let mut child = process.spawn()?;
        let stdin = child.stdin.take().expect("stdin 已设为 piped");
        let stdout = child.stdout.take().expect("stdout 已设为 piped");
        let stderr = child.stderr.take().expect("stderr 已设为 piped");
        // 一直读到 EOF：中途不读会让子进程写 stderr 时阻塞或收到 SIGPIPE
        tokio::spawn(async move {
            let mut reader = BufReader::new(stderr);
            let mut buffer = Vec::new();
            while reader.read_until(b'\n', &mut buffer).await.is_ok_and(|count| count > 0) {
                let _ = out.send(dim(String::from_utf8_lossy(&buffer).trim_end()));
                buffer.clear();
            }
        });
        Ok(ProxyStream { stdin, stdout, _child: child })
    }
}

/// 同 OpenSSH 用 exec 替换掉 shell，关闭时杀到的就是代理命令本身
#[cfg(unix)]
fn proxy_process(command: &str) -> tokio::process::Command {
    let mut process = tokio::process::Command::new("sh");
    process.arg("-c").arg(format!("exec {command}"));
    process
}

/// ponytail: cmd 没有 exec，关闭时只杀掉 cmd.exe；代理命令本身靠 stdin 关闭后自行退出
#[cfg(windows)]
fn proxy_process(command: &str) -> tokio::process::Command {
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let mut process = tokio::process::Command::new("cmd");
    // 原样传给 cmd，不做 Rust 的参数转义（否则命令里的引号会被改写）
    process.arg("/C").raw_arg(command).creation_flags(CREATE_NO_WINDOW);
    process
}

impl AsyncRead for ProxyStream {
    fn poll_read(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.stdout).poll_read(cx, buf)
    }
}

impl AsyncWrite for ProxyStream {
    fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.stdin).poll_write(cx, buf)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.stdin).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.stdin).poll_shutdown(cx)
    }
}

impl Job {
    async fn run(self) -> Result<String, String> {
        let handle = Arc::new(self.open(&self.options, &self.profile_id, 0).await?);
        let _ = self.shared.handle.set(handle.clone());

        let mut channel = handle.channel_open_session().await.map_err(|err| trf!("打开会话失败：{err}", err = err))?;
        if self.options.agent_forward {
            let _ = channel.agent_forward(false).await;
        }
        let size = self.prompter.lock().await.size;
        channel
            .request_pty(
                false,
                "xterm-256color",
                size.cols as u32,
                size.rows as u32,
                (size.cols as u32) * (size.cell_width as u32),
                (size.rows as u32) * (size.cell_height as u32),
                &[],
            )
            .await
            .map_err(|err| trf!("申请终端失败：{err}", err = err))?;
        channel.request_shell(false).await.map_err(|err| trf!("启动 shell 失败：{err}", err = err))?;

        for forward in &self.options.forwarded_ports {
            self.start_forward(&handle, forward).await;
        }

        let mut prompter = self.prompter.lock().await;
        let mut scripts: Vec<_> = self.options.login_scripts.iter().filter(|script| !script.send.is_empty()).cloned().collect();
        // 没有等待条件的登录脚本立即发送
        while scripts.first().is_some_and(|script| script.expect.is_empty()) {
            let script = scripts.remove(0);
            let _ = channel.data_bytes(format!("{}\r", script.send).into_bytes()).await;
        }
        let mut recent_output = String::new();
        let mut exit_code = None;

        let reason = loop {
            tokio::select! {
                command = prompter.commands.recv() => match command {
                    Some(Command::Data(bytes)) => {
                        if channel.data_bytes(bytes).await.is_err() {
                            break tr("连接已断开");
                        }
                    }
                    Some(Command::Resize(size)) => {
                        let _ = channel
                            .window_change(
                                size.cols as u32,
                                size.rows as u32,
                                (size.cols as u32) * (size.cell_width as u32),
                                (size.rows as u32) * (size.cell_height as u32),
                            )
                            .await;
                    }
                    Some(Command::Close) | None => {
                        let _ = channel.close().await;
                        let _ = handle.disconnect(Disconnect::ByApplication, "", "").await;
                        break String::new();
                    }
                },
                message = channel.wait() => match message {
                    Some(ChannelMsg::Data { data }) | Some(ChannelMsg::ExtendedData { data, .. }) => {
                        if !scripts.is_empty() {
                            recent_output.push_str(&String::from_utf8_lossy(&data));
                            if let Some(script) = scripts.first() {
                                if recent_output.contains(&script.expect) {
                                    let _ = channel.data_bytes(format!("{}\r", script.send).into_bytes()).await;
                                    scripts.remove(0);
                                    recent_output.clear();
                                }
                            }
                            if recent_output.len() > 8192 {
                                let cut = recent_output.len() - 4096;
                                let boundary = (cut..recent_output.len()).find(|&index| recent_output.is_char_boundary(index)).unwrap_or(0);
                                recent_output.drain(..boundary);
                            }
                        }
                        let _ = prompter.out.send(Output::Data(data.to_vec()));
                    }
                    Some(ChannelMsg::ExitStatus { exit_status }) => exit_code = Some(exit_status),
                    Some(ChannelMsg::Eof) | Some(ChannelMsg::Close) | None => {
                        break match exit_code {
                            Some(0) | None => String::new(),
                            Some(code) => trf!("远端 shell 已退出，退出码 {code}", code = code),
                        };
                    }
                    Some(_) => {}
                },
            }
        };
        Ok(reason)
    }

    /// 连接并认证；配置了跳板机时先连跳板机，再经它转发到目标
    async fn open(&self, options: &SshOptions, profile_id: &str, depth: usize) -> Result<Handle<HostCheck>, String> {
        if depth > 5 {
            return Err(tr("跳板机层级过深，可能存在循环引用"));
        }
        let user = self.resolve_user(options).await?;
        let handler = HostCheck {
            host: options.host.clone(),
            port: options.port,
            known_hosts: known_hosts_path(&self.settings),
            verify: self.settings.verify_host_keys,
            prompter: self.prompter.clone(),
            remote_forwards: options.forwarded_ports.iter().filter(|forward| forward.kind == "remote").cloned().collect(),
            accepted: None,
        };
        let config = client_config(options);
        let timeout = Duration::from_secs(options.ready_timeout.max(5) as u64);

        // 优先级同 OpenSSH：跳板机 > ProxyCommand > 直连
        let mut handle = if !options.jump_host.is_empty() {
            let jump = self
                .profiles
                .iter()
                .find(|candidate| candidate.id == options.jump_host)
                .ok_or_else(|| tr("找不到跳板机配置"))?;
            let ProfileKind::Ssh(jump_options) = &jump.kind else {
                return Err(tr("跳板机必须是 SSH 配置"));
            };
            let jump_handle = Box::pin(self.open(jump_options, &jump.id, depth + 1)).await?;
            self.prompter.lock().await.info(&trf!("经由 {jump} 连接 {host}:{port} …", jump = jump.name, host = options.host, port = options.port));
            log::info(&format!("SSH 经跳板机 {} 连接 {}:{}", jump.name, options.host, options.port));
            let tunnel = jump_handle
                .channel_open_direct_tcpip(options.host.clone(), options.port as u32, "127.0.0.1", 0)
                .await
                .map_err(|err| trf!("跳板机转发失败：{err}", err = err))?;
            let connecting = client::connect_stream(config, tunnel.into_stream(), handler);
            let handle = tokio::time::timeout(timeout, connecting)
                .await
                .map_err(|_| tr("经跳板机连接超时"))?
                .map_err(|err| trf!("经跳板机连接失败：{err}", err = err))?;
            // 跳板机连接要比目标活得久：交给后台任务持有，目标断开后一起结束
            tokio::spawn(async move {
                let jump_handle = jump_handle;
                while !jump_handle.is_closed() {
                    tokio::time::sleep(Duration::from_secs(5)).await;
                }
            });
            handle
        } else if !options.proxy_command.is_empty() {
            let command = expand_proxy_command(&options.proxy_command, &options.host, options.port, &user)?;
            let out = {
                let prompter = self.prompter.lock().await;
                prompter.info(&trf!("经由代理命令连接 {host}:{port} …", host = options.host, port = options.port));
                prompter.out.clone()
            };
            // 命令本身可能带凭据（如 sshpass），日志里不记
            log::info(&format!("SSH 经 ProxyCommand 连接 {}:{}", options.host, options.port));
            let stream = ProxyStream::spawn(&command, out).map_err(|err| trf!("无法启动代理命令：{err}", err = err))?;
            let connecting = client::connect_stream(config, stream, handler);
            tokio::time::timeout(timeout, connecting)
                .await
                .map_err(|_| trf!("连接 {host}:{port} 超时", host = options.host, port = options.port))?
                .map_err(|err| trf!("经代理命令连接失败：{err}", err = err))?
        } else {
            self.prompter.lock().await.info(&trf!("正在连接 {host}:{port} …", host = options.host, port = options.port));
            log::info(&format!("SSH 连接 {}:{}", options.host, options.port));
            let connecting = client::connect(config, (options.host.as_str(), options.port), handler);
            tokio::time::timeout(timeout, connecting)
                .await
                .map_err(|_| trf!("连接 {host}:{port} 超时", host = options.host, port = options.port))?
                .map_err(|err| trf!("连接 {host}:{port} 失败：{err}", host = options.host, port = options.port, err = err))?
        };

        self.authenticate(&mut handle, options, profile_id, &user).await?;
        log::info(&format!("SSH {user}@{}:{} 已连接并通过认证", options.host, options.port));
        Ok(handle)
    }

    async fn resolve_user(&self, options: &SshOptions) -> Result<String, String> {
        if !options.user.is_empty() {
            return Ok(options.user.clone());
        }
        let mut prompter = self.prompter.lock().await;
        let user = prompter.read_line(&trf!("{host} 的用户名：", host = options.host), true).await;
        user.filter(|user| !user.trim().is_empty()).map(|user| user.trim().to_string()).ok_or_else(|| tr("已取消"))
    }

    async fn authenticate(&self, handle: &mut Handle<HostCheck>, options: &SshOptions, profile_id: &str, user: &str) -> Result<(), String> {
        let method = options.auth.as_str();
        let auto = method == "auto";
        let fail = |err: russh::Error| trf!("认证出错：{err}", err = err);
        let target = format!("{user}@{}:{}", options.host, options.port);
        let passed = |how: &str| log::info(&format!("SSH {target} 认证通过：{how}"));
        let rejected = |how: &str| log::info(&format!("SSH {target} 认证未通过：{how}"));

        if let Ok(AuthResult::Success) = handle.authenticate_none(user).await {
            passed("none");
            return Ok(());
        }

        if (auto || method == "agent") && self.settings.use_agent {
            if self.try_agent(handle, user).await {
                passed("ssh-agent");
                return Ok(());
            }
            rejected("ssh-agent");
        }

        if auto || method == "publicKey" {
            let mut keys: Vec<PathBuf> = options.private_keys.iter().map(PathBuf::from).collect();
            let explicit = !keys.is_empty();
            if !explicit && auto {
                for name in ["id_ed25519", "id_ecdsa", "id_rsa"] {
                    keys.push(crate::paths::home_dir().join(".ssh").join(name));
                }
            }
            for path in keys {
                if !path.exists() {
                    if explicit {
                        self.prompter.lock().await.info(&trf!("私钥不存在：{path}", path = path.display()));
                    }
                    continue;
                }
                let Some(key) = self.load_key(&path, profile_id, explicit || method == "publicKey").await else { continue };
                let hash = handle.best_supported_rsa_hash().await.map_err(fail)?.flatten();
                let result = handle
                    .authenticate_publickey(user, PrivateKeyWithHashAlg::new(Arc::new(key), hash))
                    .await
                    .map_err(fail)?;
                if result.success() {
                    passed(&format!("私钥 {}", path.display()));
                    return Ok(());
                }
                rejected(&format!("私钥 {}", path.display()));
            }
        }

        if auto || method == "password" || method == "keyboardInteractive" {
            let password_key = secrets::key("password", profile_id);
            if let Some(saved) = secrets::get(&password_key) {
                if method != "keyboardInteractive" && handle.authenticate_password(user, saved.clone()).await.map_err(fail)?.success() {
                    passed("钥匙串中的密码");
                    return Ok(());
                }
                if method != "password" && self.keyboard_interactive(handle, user, Some(&saved)).await? {
                    passed("键盘交互（钥匙串中的密码）");
                    return Ok(());
                }
                rejected("钥匙串中的密码已失效");
                self.prompter.lock().await.info(&tr("钥匙串中保存的密码已失效"));
            } else if method != "password" {
                if self.keyboard_interactive(handle, user, None).await? {
                    passed("键盘交互");
                    return Ok(());
                }
                rejected("键盘交互");
            }
            if method != "keyboardInteractive" {
                for _ in 0..3 {
                    let prompt = trf!("{user}@{host} 的密码：", user = user, host = options.host);
                    let Some(password) = self.prompter.lock().await.read_line(&prompt, false).await else {
                        return Err(tr("已取消"));
                    };
                    if handle.authenticate_password(user, password.clone()).await.map_err(fail)?.success() {
                        passed("输入的密码");
                        self.offer_save(&password_key, &password).await;
                        return Ok(());
                    }
                    rejected("输入的密码");
                    self.prompter.lock().await.info(&tr("密码错误"));
                }
            }
        }
        Err(tr("认证失败：没有可用的认证方式通过"))
    }

    async fn try_agent(&self, handle: &mut Handle<HostCheck>, user: &str) -> bool {
        #[cfg(unix)]
        let agent = AgentClient::connect_env().await;
        #[cfg(windows)]
        let agent = AgentClient::connect_named_pipe(r"\\.\pipe\openssh-ssh-agent").await;
        let Ok(mut agent) = agent else { return false };
        let Ok(identities) = agent.request_identities().await else { return false };
        for identity in identities {
            let key: PublicKey = identity.public_key().into_owned();
            let hash = handle.best_supported_rsa_hash().await.ok().flatten().flatten();
            if let Ok(result) = handle.authenticate_publickey_with(user, key, hash, &mut agent).await {
                if result.success() {
                    return true;
                }
            }
        }
        false
    }

    /// 加载私钥；加密的私钥先查钥匙串，再（允许时）提示输入口令
    async fn load_key(&self, path: &PathBuf, profile_id: &str, may_prompt: bool) -> Option<russh::keys::PrivateKey> {
        match russh::keys::load_secret_key(path, None) {
            Ok(key) => return Some(key),
            Err(russh::keys::Error::KeyIsEncrypted) => {}
            Err(err) => {
                self.prompter.lock().await.info(&trf!("无法读取私钥 {path}：{err}", path = path.display(), err = err));
                return None;
            }
        }
        let secret_key = secrets::key(&format!("passphrase:{}", path.display()), profile_id);
        if let Some(saved) = secrets::get(&secret_key) {
            if let Ok(key) = russh::keys::load_secret_key(path, Some(&saved)) {
                return Some(key);
            }
        }
        if !may_prompt {
            return None;
        }
        for _ in 0..3 {
            let prompt = trf!("私钥 {path} 的口令：", path = path.display());
            let passphrase = self.prompter.lock().await.read_line(&prompt, false).await?;
            if let Ok(key) = russh::keys::load_secret_key(path, Some(&passphrase)) {
                self.offer_save(&secret_key, &passphrase).await;
                return Some(key);
            }
            self.prompter.lock().await.info(&tr("口令错误"));
        }
        None
    }

    async fn keyboard_interactive(&self, handle: &mut Handle<HostCheck>, user: &str, saved: Option<&str>) -> Result<bool, String> {
        let fail = |err: russh::Error| trf!("认证出错：{err}", err = err);
        let mut response = handle.authenticate_keyboard_interactive_start(user, None).await.map_err(fail)?;
        let mut used_saved = false;
        loop {
            match response {
                KeyboardInteractiveAuthResponse::Success => return Ok(true),
                KeyboardInteractiveAuthResponse::Failure { .. } => return Ok(false),
                KeyboardInteractiveAuthResponse::InfoRequest { name, instructions, prompts } => {
                    let mut prompter = self.prompter.lock().await;
                    if !name.is_empty() {
                        prompter.info(&name);
                    }
                    if !instructions.is_empty() {
                        prompter.info(&instructions);
                    }
                    let mut answers = Vec::new();
                    for prompt in prompts {
                        let is_password = !prompt.echo && prompt.prompt.to_lowercase().contains("password");
                        if let (true, Some(saved), false) = (is_password, saved, used_saved) {
                            used_saved = true;
                            answers.push(saved.to_string());
                            continue;
                        }
                        if saved.is_some() {
                            // 只想用已保存的密码试一次，遇到别的提问（如验证码）交给后面的交互流程
                            if !is_password {
                                let answer = prompter.read_line(&prompt.prompt, prompt.echo).await.ok_or_else(|| tr("已取消"))?;
                                answers.push(answer);
                                continue;
                            }
                            return Ok(false);
                        }
                        let answer = prompter.read_line(&prompt.prompt, prompt.echo).await.ok_or_else(|| tr("已取消"))?;
                        answers.push(answer);
                    }
                    drop(prompter);
                    response = handle.authenticate_keyboard_interactive_respond(answers).await.map_err(fail)?;
                }
            }
        }
    }

    async fn offer_save(&self, key: &str, value: &str) {
        let mut prompter = self.prompter.lock().await;
        if prompter.confirm(&tr("保存到系统钥匙串，下次自动使用？(y/N) ")).await {
            match secrets::set(key, value) {
                Ok(()) => prompter.info(&tr("已保存")),
                Err(err) => prompter.info(&err),
            }
        }
    }

    async fn start_forward(&self, handle: &Arc<Handle<HostCheck>>, forward: &ForwardedPort) {
        let bind_host = if forward.host.is_empty() { "127.0.0.1".to_string() } else { forward.host.clone() };
        match forward.kind.as_str() {
            "remote" => {
                let result = handle.tcpip_forward(bind_host.clone(), forward.port as u32).await;
                let prompter = self.prompter.lock().await;
                match result {
                    Ok(_) => prompter.info(&trf!(
                        "远程转发 {bind}:{port} → {target}:{target_port}",
                        bind = bind_host,
                        port = forward.port,
                        target = forward.target_address,
                        target_port = forward.target_port,
                    )),
                    Err(err) => {
                        log::warn(&format!("SSH 远程转发 {}:{} 失败：{err}", bind_host, forward.port));
                        prompter.info(&trf!("远程转发 {port} 失败：{err}", port = forward.port, err = err));
                    }
                }
            }
            "local" | "dynamic" => {
                let listener = match TcpListener::bind((bind_host.as_str(), forward.port)).await {
                    Ok(listener) => listener,
                    Err(err) => {
                        log::warn(&format!("SSH 端口转发监听 {}:{} 失败：{err}", bind_host, forward.port));
                        self.prompter.lock().await.info(&trf!("监听 {bind}:{port} 失败：{err}", bind = bind_host, port = forward.port, err = err));
                        return;
                    }
                };
                let description = if forward.kind == "dynamic" {
                    trf!("SOCKS 代理 {bind}:{port}", bind = bind_host, port = forward.port)
                } else {
                    trf!("本地转发 {bind}:{port} → {target}:{target_port}", bind = bind_host, port = forward.port, target = forward.target_address, target_port = forward.target_port)
                };
                self.prompter.lock().await.info(&description);
                let handle = handle.clone();
                let forward = forward.clone();
                tokio::spawn(async move {
                    while !handle.is_closed() {
                        let Ok((socket, peer)) = listener.accept().await else { break };
                        let handle = handle.clone();
                        let forward = forward.clone();
                        tokio::spawn(async move {
                            let _ = forward_connection(&handle, socket, peer, &forward).await;
                        });
                    }
                });
            }
            _ => {}
        }
    }
}

async fn forward_connection(
    handle: &Handle<HostCheck>,
    mut socket: TcpStream,
    peer: std::net::SocketAddr,
    forward: &ForwardedPort,
) -> io::Result<()> {
    let (host, port) = if forward.kind == "dynamic" {
        socks5_handshake(&mut socket).await?
    } else {
        (forward.target_address.clone(), forward.target_port)
    };
    let channel = handle
        .channel_open_direct_tcpip(host, port as u32, peer.ip().to_string(), peer.port() as u32)
        .await
        .map_err(io::Error::other)?;
    if forward.kind == "dynamic" {
        socket.write_all(&[5, 0, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
    }
    let mut stream = channel.into_stream();
    tokio::io::copy_bidirectional(&mut socket, &mut stream).await?;
    Ok(())
}

/// SOCKS5（无认证，仅 CONNECT）
async fn socks5_handshake<S: AsyncReadExt + AsyncWriteExt + Unpin>(socket: &mut S) -> io::Result<(String, u16)> {
    let mut header = [0u8; 2];
    socket.read_exact(&mut header).await?;
    if header[0] != 5 {
        return Err(io::Error::other("不是 SOCKS5 请求"));
    }
    let mut methods = vec![0u8; header[1] as usize];
    socket.read_exact(&mut methods).await?;
    socket.write_all(&[5, 0]).await?;

    let mut request = [0u8; 4];
    socket.read_exact(&mut request).await?;
    if request[1] != 1 {
        socket.write_all(&[5, 7, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
        return Err(io::Error::other("仅支持 CONNECT"));
    }
    let host = match request[3] {
        1 => {
            let mut address = [0u8; 4];
            socket.read_exact(&mut address).await?;
            std::net::Ipv4Addr::from(address).to_string()
        }
        3 => {
            let mut length = [0u8; 1];
            socket.read_exact(&mut length).await?;
            let mut name = vec![0u8; length[0] as usize];
            socket.read_exact(&mut name).await?;
            String::from_utf8_lossy(&name).into_owned()
        }
        4 => {
            let mut address = [0u8; 16];
            socket.read_exact(&mut address).await?;
            std::net::Ipv6Addr::from(address).to_string()
        }
        _ => return Err(io::Error::other("未知地址类型")),
    };
    let mut port = [0u8; 2];
    socket.read_exact(&mut port).await?;
    Ok((host, u16::from_be_bytes(port)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn proxy_command_tokens() {
        let expanded = expand_proxy_command("ssh -W %h:%p -l %r gw.example.com # 100%%", "192.0.2.7", 2222, "deploy");
        assert_eq!(expanded.as_deref(), Ok("ssh -W 192.0.2.7:2222 -l deploy gw.example.com # 100%"));
        assert!(expand_proxy_command("nc %x", "h", 22, "u").is_err());
        assert!(expand_proxy_command("nc %", "h", 22, "u").is_err());
    }

    #[test]
    fn socks5_domain_request() {
        RUNTIME.block_on(async {
            let (mut client, mut server) = tokio::io::duplex(256);
            let task = tokio::spawn(async move { socks5_handshake(&mut server).await.unwrap() });
            client.write_all(&[5, 1, 0]).await.unwrap();
            let mut reply = [0u8; 2];
            client.read_exact(&mut reply).await.unwrap();
            assert_eq!(reply, [5, 0]);
            let mut request = vec![5, 1, 0, 3, 11];
            request.extend_from_slice(b"example.com");
            request.extend_from_slice(&443u16.to_be_bytes());
            client.write_all(&request).await.unwrap();
            assert_eq!(task.await.unwrap(), ("example.com".to_string(), 443));
        });
    }

    #[test]
    fn prompter_reads_line_with_backspace_and_utf8() {
        RUNTIME.block_on(async {
            let (out_tx, out_rx) = std::sync::mpsc::channel();
            let (command_tx, command_rx) = mpsc::unbounded_channel();
            let size = WinSize { cols: 80, rows: 24, cell_width: 8, cell_height: 16 };
            let mut prompter = Prompter { out: out_tx, commands: command_rx, size };
            command_tx.send(Command::Data("ab中".as_bytes().to_vec())).unwrap();
            command_tx.send(Command::Data(vec![0x7f, b'c', b'\r'])).unwrap();
            assert_eq!(prompter.read_line("pw: ", false).await.as_deref(), Some("abc"));
            // 不回显：输出里只有提示和换行
            let echoed: Vec<u8> = out_rx.try_iter().flat_map(|output| match output {
                Output::Data(bytes) => bytes,
                Output::Closed(_) => Vec::new(),
            }).collect();
            assert_eq!(echoed, b"pw: \r\n");
            command_tx.send(Command::Data(vec![0x03])).unwrap();
            assert_eq!(prompter.read_line("again: ", true).await, None);
        });
    }
}
