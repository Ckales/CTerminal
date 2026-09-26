// ZMODEM 走完整的会话管道：输出里识别起始头 → 接管收发 → 完成后交还终端。
// 本机没有 lrzsz，远端用 core 自己的发送端 / 接收端扮演 sz / rz（CRC、ZDLE 转义的已知字节断言在 zmodem.rs 单元测试里）。

use std::fs;
use std::io;
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use cterm_core::frame::Palette;
use cterm_core::session::{screen_text, Output, Session, SessionEvent, TermOptions, Transport, WinSize};
use cterm_core::zmodem::{Direction, Transfer, CANCEL_SEQUENCE};

/// 会话写出的字节交给“远端”线程
struct Wire {
    to_remote: Sender<Vec<u8>>,
}

impl Transport for Wire {
    fn write(&mut self, data: &[u8]) -> io::Result<()> {
        let _ = self.to_remote.send(data.to_vec());
        Ok(())
    }
    fn resize(&mut self, _size: WinSize) {}
    fn close(&mut self) {}
}

struct Harness {
    session: Arc<Session>,
    events: Receiver<SessionEvent>,
    /// 远端收到的全部原始字节
    raw: Arc<Mutex<Vec<u8>>>,
    dir: PathBuf,
}

impl Harness {
    /// dir：临时目录（下载存到 dir/downloads）；preamble：远端程序启动时先打印的文字；remote：扮演 sz / rz 的状态机
    fn start(dir: PathBuf, preamble: &'static [u8], remote: Transfer) -> Harness {

        let (event_tx, events) = mpsc::channel();
        let sink = Arc::new(move |event: SessionEvent| {
            let _ = event_tx.send(event);
        });
        let size = WinSize { cols: 100, rows: 10, cell_width: 8, cell_height: 16 };
        let options = TermOptions { scrollback: 100, cursor: "block".into(), word_separators: " ".into(), scroll_on_input: true, palette: Palette::default(), highlights: Vec::new(), bold_is_bright: true };
        let (session, tx) = Session::new(options, size, sink);
        session.set_downloads_dir(dir.join("downloads"));
        let (to_remote, from_session) = mpsc::channel();
        session.attach(Box::new(Wire { to_remote }));
        let raw = Arc::new(Mutex::new(Vec::new()));
        spawn_remote(remote, preamble, tx, from_session, raw.clone());
        Harness { session, events, raw, dir }
    }

    fn wait_for_event(&self, expected: SessionEvent) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline {
            if let Ok(event) = self.events.recv_timeout(Duration::from_millis(50)) {
                if event == expected {
                    return;
                }
            }
        }
        panic!("没有等到事件 {expected:?}");
    }

    fn wait_for_screen(&self, needle: &str) -> String {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let text = screen_text(&self.session.frame());
            if text.contains(needle) {
                return text;
            }
            assert!(Instant::now() < deadline, "屏幕上没有出现 {needle:?}：\n{text}");
            thread::sleep(Duration::from_millis(20));
        }
    }
}

fn temp_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cterm-zmodem-session-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("downloads")).unwrap();
    dir
}

/// 远端传输结束后打印的提示符（screen_text 会去掉行尾空格，所以不以空格结尾）
const PROMPT: &str = "done$";

impl Drop for Harness {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

/// 远端：先打印 preamble，然后跑 ZMODEM 状态机；结束后打印 shell 提示符，之后收到的字节只记录
fn spawn_remote(mut remote: Transfer, preamble: &'static [u8], tx: Sender<Output>, from_session: Receiver<Vec<u8>>, raw: Arc<Mutex<Vec<u8>>>) {
    thread::spawn(move || {
        let _ = tx.send(Output::Data(preamble.to_vec()));
        let mut prompted = false;
        let deadline = Instant::now() + Duration::from_secs(20);
        while Instant::now() < deadline {
            remote.step();
            let wire = remote.take_wire();
            if !wire.is_empty() && tx.send(Output::Data(wire)).is_err() {
                return;
            }
            if remote.finished() && !prompted {
                prompted = true;
                let _ = tx.send(Output::Data(format!("\r\n{PROMPT}").into_bytes()));
            }
            let wait = if remote.busy() { Duration::ZERO } else { Duration::from_millis(10) };
            match from_session.recv_timeout(wait) {
                Ok(bytes) => {
                    raw.lock().unwrap().extend_from_slice(&bytes);
                    if !remote.finished() {
                        remote.input(&bytes);
                    }
                }
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => return,
            }
        }
    });
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|window| window == needle)
}

#[test]
fn remote_sz_downloads_into_downloads_dir() {
    let source = std::env::temp_dir().join(format!("cterm-zmodem-sz-source-{}", std::process::id()));
    fs::create_dir_all(&source).unwrap();
    let content: Vec<u8> = (0..100_000u32).map(|index| (index * 7 % 256) as u8).collect();
    fs::write(source.join("report.bin"), &content).unwrap();

    // 远端 sz = 我们的发送端
    let mut remote = Transfer::new(Direction::Upload, PathBuf::new()).unwrap();
    remote.select_files(vec![source.join("report.bin")]);
    let dir = temp_dir("sz");
    fs::write(dir.join("downloads/report.bin"), b"keep me").unwrap();
    let harness = Harness::start(dir, b"$ sz report.bin\r\nrz\r", remote);

    let screen = harness.wait_for_screen(PROMPT);
    let saved = harness.dir.join("downloads/report (1).bin");
    assert_eq!(fs::read(&saved).unwrap(), content);
    assert_eq!(fs::read(harness.dir.join("downloads/report.bin")).unwrap(), b"keep me", "重名不覆盖");
    assert!(screen.contains("report.bin"), "{screen}");
    assert!(screen.contains("100%") || screen.contains("report (1).bin"), "{screen}");
    // 协议字节和结束时的 OO 都不显示
    assert!(!screen.contains("B00"), "{screen}");
    assert!(!screen.contains("OO"), "{screen}");

    // 交还终端后键盘输入照常发到远端
    harness.session.input(b"ls\r");
    thread::sleep(Duration::from_millis(100));
    assert!(contains(&harness.raw.lock().unwrap(), b"ls\r"));
    let _ = fs::remove_dir_all(&source);
}

#[test]
fn remote_rz_uploads_selected_files() {
    let harness_dir = std::env::temp_dir().join(format!("cterm-zmodem-rz-remote-{}", std::process::id()));
    let _ = fs::remove_dir_all(&harness_dir);
    // 远端 rz = 我们的接收端，收到的文件放 harness_dir
    let remote = Transfer::new(Direction::Download, harness_dir.clone()).unwrap();
    let harness = Harness::start(temp_dir("rz"), b"$ rz\r\nrz waiting to receive.", remote);
    harness.wait_for_event(SessionEvent::ZmodemUpload);

    // 等文件面板期间的键盘输入不进线路
    harness.session.input(b"typed while waiting");
    let local_a = harness.dir.join("a.txt");
    let local_b = harness.dir.join("b.bin");
    fs::write(&local_a, b"hello from cterminal\n").unwrap();
    fs::write(&local_b, vec![0x18u8; 5000]).unwrap();
    harness.session.zmodem_upload(vec![local_a, local_b]);

    let screen = harness.wait_for_screen(PROMPT);
    assert_eq!(fs::read(harness_dir.join("a.txt")).unwrap(), b"hello from cterminal\n");
    assert_eq!(fs::read(harness_dir.join("b.bin")).unwrap(), vec![0x18u8; 5000]);
    assert!(screen.contains("a.txt") && screen.contains("b.bin"), "{screen}");
    assert!(!contains(&harness.raw.lock().unwrap(), b"typed while waiting"));
    let _ = fs::remove_dir_all(&harness_dir);
}

#[test]
fn ctrl_c_cancels_and_returns_terminal() {
    let harness_dir = std::env::temp_dir().join(format!("cterm-zmodem-cancel-remote-{}", std::process::id()));
    let remote = Transfer::new(Direction::Download, harness_dir.clone()).unwrap();
    let harness = Harness::start(temp_dir("cancel"), b"rz\r", remote);
    harness.wait_for_event(SessionEvent::ZmodemUpload);

    // Ctrl-C：发 5 个 CAN + 退格，远端中止并回到提示符
    harness.session.input(b"\x03");
    harness.wait_for_screen(PROMPT);
    assert!(contains(&harness.raw.lock().unwrap(), CANCEL_SEQUENCE));

    harness.session.input(b"echo ok\r");
    thread::sleep(Duration::from_millis(100));
    assert!(contains(&harness.raw.lock().unwrap(), b"echo ok\r"));
    let _ = fs::remove_dir_all(&harness_dir);
}
