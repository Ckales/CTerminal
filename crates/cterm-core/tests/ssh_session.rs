//! SSH 端到端：进程内起一个 russh 服务器（主机密钥运行时生成，仓库里不放任何密钥），
//! 走完「未知主机确认 → 写入 known_hosts → 密码输错重试 → 交互 shell → 调整大小」。

use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::PathBuf;
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};

use cterm_core::config::{Config, Profile, ProfileKind, SshOptions};
use cterm_core::connect;
use cterm_core::session::{screen_text, Session, SessionEvent, WinSize};
use cterm_core::sftp::Sftp;
use cterm_core::ssh::RUNTIME;
use russh_sftp::protocol::{Attrs, Data, File as SftpFile, FileAttributes, Handle, Name, OpenFlags, Status, StatusCode, Version};
use russh::server::{self, Auth, Msg, Server as _, Session as ServerSession};
use russh::{Channel, ChannelId};

#[derive(Clone, Default)]
struct TestServer {
    sizes: Arc<Mutex<Vec<(u32, u32)>>>,
    channels: Arc<Mutex<HashMap<ChannelId, Channel<Msg>>>>,
    /// SFTP 子系统映射到的本地目录
    sftp_root: PathBuf,
    /// 只回显 shell 通道的数据，SFTP 通道的数据由子系统处理
    shells: Arc<Mutex<Vec<ChannelId>>>,
}

impl server::Server for TestServer {
    type Handler = Self;
    fn new_client(&mut self, _: Option<std::net::SocketAddr>) -> Self {
        self.clone()
    }
}

impl server::Handler for TestServer {
    type Error = russh::Error;

    async fn auth_password(&mut self, user: &str, password: &str) -> Result<Auth, Self::Error> {
        if user == "tester" && password == "s3cret" {
            return Ok(Auth::Accept);
        }
        Ok(Auth::reject())
    }

    async fn channel_open_session(&mut self, channel: Channel<Msg>, reply: server::ChannelOpenHandle, _session: &mut ServerSession) -> Result<(), Self::Error> {
        self.channels.lock().unwrap().insert(channel.id(), channel);
        reply.accept().await;
        Ok(())
    }

    async fn subsystem_request(&mut self, channel_id: ChannelId, name: &str, session: &mut ServerSession) -> Result<(), Self::Error> {
        let channel = self.channels.lock().unwrap().remove(&channel_id);
        match (name, channel) {
            ("sftp", Some(channel)) => {
                session.channel_success(channel_id)?;
                let handler = FsSftp { root: self.sftp_root.clone(), ..Default::default() };
                tokio::spawn(russh_sftp::server::run(channel.into_stream(), handler));
            }
            _ => session.channel_failure(channel_id)?,
        }
        Ok(())
    }

    async fn pty_request(
        &mut self,
        _channel: ChannelId,
        _term: &str,
        cols: u32,
        rows: u32,
        _pix_width: u32,
        _pix_height: u32,
        _modes: &[(russh::Pty, u32)],
        _session: &mut ServerSession,
    ) -> Result<(), Self::Error> {
        self.sizes.lock().unwrap().push((cols, rows));
        Ok(())
    }

    async fn window_change_request(
        &mut self,
        _channel: ChannelId,
        cols: u32,
        rows: u32,
        _pix_width: u32,
        _pix_height: u32,
        _session: &mut ServerSession,
    ) -> Result<(), Self::Error> {
        self.sizes.lock().unwrap().push((cols, rows));
        Ok(())
    }

    async fn shell_request(&mut self, channel: ChannelId, session: &mut ServerSession) -> Result<(), Self::Error> {
        self.shells.lock().unwrap().push(channel);
        session.data(channel, b"welcome to test\r\n$ ".to_vec())?;
        Ok(())
    }

    async fn data(&mut self, channel: ChannelId, data: &[u8], session: &mut ServerSession) -> Result<(), Self::Error> {
        if !self.shells.lock().unwrap().contains(&channel) {
            return Ok(());
        }
        let text = String::from_utf8_lossy(data).to_string();
        if text.contains("bye") {
            session.exit_status_request(channel, 0)?;
            session.eof(channel)?;
            session.close(channel)?;
            return Ok(());
        }
        let echoed = text.replace('\r', "\r\n");
        session.data(channel, echoed.into_bytes())?;
        Ok(())
    }
}

fn start_server() -> (u16, TestServer) {
    start_server_with_root(PathBuf::new())
}

fn start_server_with_root(sftp_root: PathBuf) -> (u16, TestServer) {
    let server = TestServer { sftp_root, ..Default::default() };
    let key = russh::keys::PrivateKey::random(&mut rand::rng(), russh::keys::Algorithm::Ed25519).unwrap();
    let config = Arc::new(server::Config {
        keys: vec![key],
        auth_rejection_time: Duration::from_millis(10),
        auth_rejection_time_initial: Some(Duration::from_millis(0)),
        ..Default::default()
    });
    let listener = RUNTIME.block_on(tokio::net::TcpListener::bind(("127.0.0.1", 0))).unwrap();
    let port = listener.local_addr().unwrap().port();
    let mut running = server.clone();
    RUNTIME.spawn(async move {
        let _ = running.run_on_socket(config, &listener).await;
    });
    (port, server)
}

struct Client {
    session: Arc<Session>,
    events: mpsc::Receiver<SessionEvent>,
}

impl Client {
    fn open(port: u16, known_hosts: &std::path::Path) -> Client {
        let mut config = Config::default();
        config.ssh.known_hosts_file = known_hosts.display().to_string();
        config.ssh.use_agent = false;
        let profile = Profile {
            // 每次一个新 id：密码查询走系统钥匙串，保证查不到任何已保存的项
            id: format!("test-ssh-{}-{port}", std::process::id()),
            name: "test".into(),
            kind: ProfileKind::Ssh(SshOptions {
                host: "127.0.0.1".into(),
                port,
                user: "tester".into(),
                auth: "password".into(),
                ..Default::default()
            }),
            ..Default::default()
        };
        let (tx, events) = mpsc::channel();
        let sink = Arc::new(move |event: SessionEvent| {
            let _ = tx.send(event);
        });
        let size = WinSize { cols: 80, rows: 24, cell_width: 8, cell_height: 16 };
        let session = connect::open(&profile, &config, size, sink);
        Client { session, events }
    }

    fn screen(&self) -> String {
        screen_text(&self.session.frame())
    }

    fn wait_for(&self, needle: &str) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline {
            if self.screen().contains(needle) {
                return;
            }
            let _ = self.events.recv_timeout(Duration::from_millis(50));
        }
        panic!("等待「{needle}」超时，当前屏幕：\n{}", self.screen());
    }

    fn type_line(&self, text: &str) {
        self.session.input(format!("{text}\r").as_bytes());
    }

    fn wait_exit(&self) -> String {
        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline {
            if let Ok(SessionEvent::Exit(reason)) = self.events.recv_timeout(Duration::from_millis(100)) {
                return reason;
            }
        }
        panic!("会话没有结束，当前屏幕：\n{}", self.screen());
    }
}

#[test]
fn unknown_host_then_password_retry_then_shell() {
    let (port, server) = start_server();
    let dir = std::env::temp_dir().join(format!("cterm-ssh-{}", std::process::id()));
    let known_hosts = dir.join("known_hosts");
    let _ = std::fs::remove_dir_all(&dir);

    let client = Client::open(port, &known_hosts);
    client.wait_for("无法确认主机");
    assert!(client.screen().contains("SHA256:"), "应显示指纹");
    client.type_line("yes");

    client.wait_for("的密码：");
    client.type_line("wrong");
    client.wait_for("密码错误");
    client.type_line("s3cret");
    client.wait_for("保存到系统钥匙串");
    client.type_line("n");

    client.wait_for("welcome to test");
    client.type_line("hello 世界");
    client.wait_for("hello 世界");
    assert!(!client.screen().contains("s3cret"), "密码不能回显到屏幕上");

    client.session.resize(WinSize { cols: 100, rows: 30, cell_width: 8, cell_height: 16 });
    let deadline = Instant::now() + Duration::from_secs(5);
    while !server.sizes.lock().unwrap().contains(&(100, 30)) {
        assert!(Instant::now() < deadline, "服务器没收到窗口变化：{:?}", server.sizes.lock().unwrap());
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(server.sizes.lock().unwrap()[0], (80, 24));

    client.type_line("bye");
    assert_eq!(client.wait_exit(), "");

    let recorded = std::fs::read_to_string(&known_hosts).unwrap();
    assert!(recorded.trim_start().starts_with(&format!("[127.0.0.1]:{port} ssh-ed25519 ")), "{recorded}");

    // 第二次连接：主机已知，不再提问，直接到密码
    let again = Client::open(port, &known_hosts);
    again.wait_for("的密码：");
    assert!(!again.screen().contains("无法确认主机"));
    again.session.close();
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn changed_host_key_warns_and_defaults_to_refuse() {
    let (port, _server) = start_server();
    let dir = std::env::temp_dir().join(format!("cterm-ssh-changed-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let known_hosts = dir.join("known_hosts");
    // 记录一个别的密钥，模拟服务器密钥被替换
    let other = russh::keys::PrivateKey::random(&mut rand::rng(), russh::keys::Algorithm::Ed25519).unwrap();
    std::fs::write(&known_hosts, format!("[127.0.0.1]:{port} {}\n", other.public_key().to_openssh().unwrap())).unwrap();

    let client = Client::open(port, &known_hosts);
    client.wait_for("密钥已变更");
    client.type_line("");
    let reason = client.wait_exit();
    assert!(!reason.is_empty(), "拒绝后应以错误结束");
    let _ = std::fs::remove_dir_all(&dir);
}

/// 测试用 SFTP 服务端：把客户端的绝对路径映射到本地临时目录
#[derive(Default)]
struct FsSftp {
    root: PathBuf,
    files: HashMap<String, std::fs::File>,
    dirs: HashMap<String, Option<PathBuf>>,
    next: u32,
}

fn ok(id: u32) -> Status {
    Status { id, status_code: StatusCode::Ok, error_message: "Ok".into(), language_tag: "en-US".into() }
}

fn io_status(err: std::io::Error) -> StatusCode {
    if err.kind() == std::io::ErrorKind::NotFound {
        return StatusCode::NoSuchFile;
    }
    StatusCode::Failure
}

impl FsSftp {
    fn local(&self, path: &str) -> PathBuf {
        self.root.join(path.trim_start_matches('/'))
    }

    fn handle(&mut self) -> String {
        self.next += 1;
        format!("h{}", self.next)
    }
}

impl russh_sftp::server::Handler for FsSftp {
    type Error = StatusCode;

    fn unimplemented(&self) -> Self::Error {
        StatusCode::OpUnsupported
    }

    async fn init(&mut self, _version: u32, _extensions: HashMap<String, String>) -> Result<Version, Self::Error> {
        Ok(Version::new())
    }

    async fn realpath(&mut self, id: u32, path: String) -> Result<Name, Self::Error> {
        let path = if path == "." || path.is_empty() { "/".to_string() } else { path };
        Ok(Name { id, files: vec![SftpFile::dummy(path)] })
    }

    async fn stat(&mut self, id: u32, path: String) -> Result<Attrs, Self::Error> {
        let metadata = std::fs::metadata(self.local(&path)).map_err(io_status)?;
        Ok(Attrs { id, attrs: FileAttributes::from(&metadata) })
    }

    async fn lstat(&mut self, id: u32, path: String) -> Result<Attrs, Self::Error> {
        let metadata = std::fs::symlink_metadata(self.local(&path)).map_err(io_status)?;
        Ok(Attrs { id, attrs: FileAttributes::from(&metadata) })
    }

    async fn fstat(&mut self, id: u32, handle: String) -> Result<Attrs, Self::Error> {
        let file = self.files.get(&handle).ok_or(StatusCode::Failure)?;
        let metadata = file.metadata().map_err(io_status)?;
        Ok(Attrs { id, attrs: FileAttributes::from(&metadata) })
    }

    async fn opendir(&mut self, id: u32, path: String) -> Result<Handle, Self::Error> {
        let local = self.local(&path);
        if !local.is_dir() {
            return Err(StatusCode::NoSuchFile);
        }
        let handle = self.handle();
        self.dirs.insert(handle.clone(), Some(local));
        Ok(Handle { id, handle })
    }

    async fn readdir(&mut self, id: u32, handle: String) -> Result<Name, Self::Error> {
        let Some(local) = self.dirs.get_mut(&handle).and_then(Option::take) else { return Err(StatusCode::Eof) };
        let mut files = Vec::new();
        for entry in std::fs::read_dir(local).map_err(io_status)?.flatten() {
            let metadata = entry.metadata().map_err(io_status)?;
            files.push(SftpFile::new(entry.file_name().to_string_lossy(), FileAttributes::from(&metadata)));
        }
        Ok(Name { id, files })
    }

    async fn open(&mut self, id: u32, filename: String, flags: OpenFlags, _attrs: FileAttributes) -> Result<Handle, Self::Error> {
        let file = std::fs::OpenOptions::new()
            .read(flags.contains(OpenFlags::READ) || !flags.contains(OpenFlags::WRITE))
            .write(flags.contains(OpenFlags::WRITE))
            .create(flags.contains(OpenFlags::CREATE))
            .truncate(flags.contains(OpenFlags::TRUNCATE))
            .open(self.local(&filename))
            .map_err(io_status)?;
        let handle = self.handle();
        self.files.insert(handle.clone(), file);
        Ok(Handle { id, handle })
    }

    async fn read(&mut self, id: u32, handle: String, offset: u64, len: u32) -> Result<Data, Self::Error> {
        let file = self.files.get_mut(&handle).ok_or(StatusCode::Failure)?;
        file.seek(SeekFrom::Start(offset)).map_err(io_status)?;
        let mut data = vec![0u8; len as usize];
        let count = file.read(&mut data).map_err(io_status)?;
        if count == 0 {
            return Err(StatusCode::Eof);
        }
        data.truncate(count);
        Ok(Data { id, data })
    }

    async fn write(&mut self, id: u32, handle: String, offset: u64, data: Vec<u8>) -> Result<Status, Self::Error> {
        let file = self.files.get_mut(&handle).ok_or(StatusCode::Failure)?;
        file.seek(SeekFrom::Start(offset)).map_err(io_status)?;
        file.write_all(&data).map_err(io_status)?;
        Ok(ok(id))
    }

    async fn close(&mut self, id: u32, handle: String) -> Result<Status, Self::Error> {
        self.files.remove(&handle);
        self.dirs.remove(&handle);
        Ok(ok(id))
    }

    async fn mkdir(&mut self, id: u32, path: String, _attrs: FileAttributes) -> Result<Status, Self::Error> {
        std::fs::create_dir(self.local(&path)).map_err(io_status)?;
        Ok(ok(id))
    }

    async fn rmdir(&mut self, id: u32, path: String) -> Result<Status, Self::Error> {
        std::fs::remove_dir(self.local(&path)).map_err(io_status)?;
        Ok(ok(id))
    }

    async fn remove(&mut self, id: u32, filename: String) -> Result<Status, Self::Error> {
        std::fs::remove_file(self.local(&filename)).map_err(io_status)?;
        Ok(ok(id))
    }

    async fn rename(&mut self, id: u32, oldpath: String, newpath: String) -> Result<Status, Self::Error> {
        std::fs::rename(self.local(&oldpath), self.local(&newpath)).map_err(io_status)?;
        Ok(ok(id))
    }
}

/// 连接并完成认证，返回能开 SFTP 的会话
fn connected(port: u16, dir: &std::path::Path) -> Client {
    let known_hosts = dir.join("known_hosts");
    let client = Client::open(port, &known_hosts);
    client.wait_for("无法确认主机");
    client.type_line("once");
    client.wait_for("的密码：");
    client.type_line("s3cret");
    client.wait_for("保存到系统钥匙串");
    client.type_line("n");
    client.wait_for("welcome to test");
    client
}

#[test]
fn sftp_list_upload_download_rename_remove() {
    let base = std::env::temp_dir().join(format!("cterm-sftp-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&base);
    let remote_root = base.join("remote");
    let local = base.join("local");
    std::fs::create_dir_all(remote_root.join("docs")).unwrap();
    std::fs::create_dir_all(local.join("folder/inner")).unwrap();
    std::fs::write(remote_root.join("hello.txt"), "你好 sftp").unwrap();
    std::fs::write(local.join("upload.bin"), vec![7u8; 600_000]).unwrap();
    std::fs::write(local.join("folder/inner/deep.txt"), "deep").unwrap();

    let (port, _server) = start_server_with_root(remote_root.clone());
    let client = connected(port, &base);
    let shared = client.session.ssh().expect("SSH 会话应提供 SFTP 通道");
    let sftp = Sftp::open(&shared).unwrap();

    assert_eq!(sftp.home().unwrap(), "/");
    let entries = sftp.list("/").unwrap();
    let names: Vec<&str> = entries.iter().map(|entry| entry.name.as_str()).collect();
    assert_eq!(names, ["docs", "hello.txt"], "目录在前");
    assert!(entries[0].is_dir && !entries[1].is_dir);
    assert_eq!(entries[1].size, "你好 sftp".len() as u64);

    let downloaded = local.join("hello.txt");
    sftp.download("/hello.txt", &downloaded, &|_, _| {}).unwrap();
    assert_eq!(std::fs::read_to_string(&downloaded).unwrap(), "你好 sftp");
    assert!(!local.join("hello.txt.part").exists());

    let last = Arc::new(Mutex::new((0u64, 0u64)));
    let recorder = last.clone();
    sftp.upload(&local.join("upload.bin"), "/docs/upload.bin", &move |done, total| *recorder.lock().unwrap() = (done, total)).unwrap();
    assert_eq!(*last.lock().unwrap(), (600_000, 600_000));
    assert_eq!(std::fs::read(remote_root.join("docs/upload.bin")).unwrap(), vec![7u8; 600_000]);

    sftp.upload(&local.join("folder"), "/folder", &|_, _| {}).unwrap();
    assert_eq!(std::fs::read_to_string(remote_root.join("folder/inner/deep.txt")).unwrap(), "deep");

    sftp.rename("/hello.txt", "/renamed.txt").unwrap();
    assert!(remote_root.join("renamed.txt").exists());
    sftp.mkdir("/new").unwrap();
    assert!(remote_root.join("new").is_dir());
    sftp.remove("/folder", true).unwrap();
    assert!(!remote_root.join("folder").exists());
    sftp.remove("/renamed.txt", false).unwrap();
    assert!(sftp.list("/nope").is_err());

    sftp.close();
    client.session.close();
    let _ = std::fs::remove_dir_all(&base);
}
