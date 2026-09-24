//! ZMODEM（rz / sz）：在会话输出里识别起始序列，接管这个会话的收发字节，完成或取消后交还终端。
//! 协议状态机用 zmodem2（调用方驱动、自己不碰 I/O）；这里负责文件读写、进度文字、超时和取消。
//! 在 session 层做，本地 shell / SSH / Telnet / 串口共用一份。

use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::PathBuf;
use std::time::{Duration, Instant};

use zmodem2::{Action, Event, FileInfo, Position, Receiver, Sender};

use crate::i18n::tr;
use crate::paths;

/// ZPAD ZPAD ZDLE 'B' '0'，后面一位 '0' = ZRQINIT（远端 sz 要发文件），'1' = ZRINIT（远端 rz 在等上传）
const HEADER_PREFIX: &[u8] = b"**\x18B0";
const CAN: u8 = 0x18;
/// 取消序列：5 个 CAN 让对方中止，再用退格擦掉对方可能回显出来的字符
pub const CANCEL_SEQUENCE: &[u8] = b"\x18\x18\x18\x18\x18\x08\x08\x08\x08\x08";
/// 对方多久没动静就重发握手
const RETRY_AFTER: Duration = Duration::from_secs(10);
/// 对方多久没动静就放弃
const GIVE_UP_AFTER: Duration = Duration::from_secs(60);
/// 进度行最短刷新间隔（用 \r 覆盖同一行，不刷屏）
const PROGRESS_INTERVAL: Duration = Duration::from_millis(500);
/// 单次 step 最多处理的字节数，处理完回到会话循环看一眼取消指令和新输入
const STEP_BUDGET: usize = 256 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    /// 远端 sz：我们接收
    Download,
    /// 远端 rz：我们上传
    Upload,
}

/// 界面 → 传输
#[derive(Debug, Clone, PartialEq)]
pub enum Control {
    /// 用户选好的上传文件；空 = 取消
    Upload(Vec<PathBuf>),
    Cancel,
}

pub struct Start {
    pub direction: Direction,
    /// 本块里起始头之前的字节数，照常交给终端显示
    pub shown: usize,
    /// 从起始头开始的字节，交给传输
    pub data: Vec<u8>,
}

/// 在输出流里找起始头。起始头可能被拆在两块数据之间，所以记住上一块末尾几个字节。
#[derive(Default)]
pub struct Detector {
    tail: Vec<u8>,
    /// 传输刚结束：跳过协议残留的行尾（\r \n XON）和发送方最后的 "OO"（over and out）
    skip_trailer: bool,
}

impl Detector {
    /// 返回这一块里要显示的部分，以及（如果有）传输的起点
    pub fn scan<'a>(&mut self, data: &'a [u8]) -> (&'a [u8], Option<Start>) {
        let mut data = data;
        if self.skip_trailer {
            let framing = data.iter().position(|byte| !matches!(byte, b'\r' | b'\n' | 0x8a | 0x8d | 0x11 | 0x13)).unwrap_or(data.len());
            data = &data[framing..];
            if data.is_empty() {
                return (data, None);
            }
            self.skip_trailer = false;
            data = data.strip_prefix(b"OO").unwrap_or(data);
        }
        // 快速路径：没有 CAN 就不可能有起始头（大量输出时不做拼接）
        if !data.contains(&CAN) && !self.tail.contains(&CAN) {
            self.remember_tail(data);
            return (data, None);
        }
        let mut joined = self.tail.clone();
        joined.extend_from_slice(data);
        let tail_len = self.tail.len();
        let mut found = None;
        for index in 0..joined.len() {
            let rest = &joined[index..];
            if rest.len() <= HEADER_PREFIX.len() || !rest.starts_with(HEADER_PREFIX) {
                continue;
            }
            let direction = match rest[HEADER_PREFIX.len()] {
                b'0' => Direction::Download,
                b'1' => Direction::Upload,
                _ => continue,
            };
            found = Some((index, direction));
            break;
        }
        let Some((index, direction)) = found else {
            self.remember_tail(data);
            return (data, None);
        };
        // 起始头如果从上一块末尾开始，那几个字节已经显示过了（只是几个 *），不再追回
        let shown = index.saturating_sub(tail_len);
        let start = Start { direction, shown, data: joined[index..].to_vec() };
        self.tail.clear();
        (&data[..shown], Some(start))
    }

    /// 传输结束后调用
    pub fn finish_transfer(&mut self) {
        self.tail.clear();
        self.skip_trailer = true;
    }

    fn remember_tail(&mut self, data: &[u8]) {
        let keep = HEADER_PREFIX.len();
        if data.len() >= keep {
            self.tail.clear();
            self.tail.extend_from_slice(&data[data.len() - keep..]);
            return;
        }
        self.tail.extend_from_slice(data);
        let excess = self.tail.len().saturating_sub(keep);
        self.tail.drain(..excess);
    }
}

/// 一次 rz / sz 会话
pub struct Transfer {
    role: Role,
    /// 收到但还没交给状态机的字节
    input: Vec<u8>,
    /// 待发给远端
    wire: Vec<u8>,
    /// 待显示在终端（已带颜色和 \r）
    display: Vec<u8>,
    finished: bool,
    /// 上次 step 用完了预算，还有活要干
    busy: bool,
    last_activity: Instant,
    last_retry: Instant,
    /// 输入里连续 CAN 的个数，到 5 表示对方取消
    cancel_run: usize,
}

enum Role {
    Download(Download),
    /// 远端 rz 已就绪，等用户选文件
    AwaitFiles,
    Upload(Upload),
    Done,
}

enum Flow {
    Idle,
    Busy,
    Done,
}

impl Transfer {
    pub fn new(direction: Direction, downloads_dir: PathBuf) -> Result<Transfer, String> {
        let role = match direction {
            Direction::Download => {
                // 缓冲 0 + CANOVIO：让 sz 连续发送，不必每 1KB 等一次确认
                let receiver = Receiver::with_flow_control(0, true).map_err(protocol_error)?;
                Role::Download(Download { receiver, dir: downloads_dir, file: None })
            }
            Direction::Upload => Role::AwaitFiles,
        };
        let now = Instant::now();
        let mut transfer = Transfer {
            role,
            input: Vec::new(),
            wire: Vec::new(),
            display: Vec::new(),
            finished: false,
            busy: false,
            last_activity: now,
            last_retry: now,
            cancel_run: 0,
        };
        if direction == Direction::Upload {
            transfer.show_line(&tr("ZMODEM：对方在等待上传，请选择文件…"));
        }
        Ok(transfer)
    }

    pub fn finished(&self) -> bool {
        self.finished
    }

    pub fn busy(&self) -> bool {
        self.busy
    }

    pub fn waiting_for_files(&self) -> bool {
        matches!(self.role, Role::AwaitFiles)
    }

    pub fn take_wire(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.wire)
    }

    pub fn take_display(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.display)
    }

    /// 传输结束后剩下的字节（通常是 shell 提示符），交还终端
    pub fn take_leftover(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.input)
    }

    /// 远端发来的字节
    pub fn input(&mut self, data: &[u8]) {
        if self.finished {
            self.input.extend_from_slice(data);
            return;
        }
        self.last_activity = Instant::now();
        // 合法的 ZMODEM 数据里 CAN（=ZDLE）后面总跟着转义字符，连续 5 个只可能是对方取消
        for (index, &byte) in data.iter().enumerate() {
            self.cancel_run = if byte == CAN { self.cancel_run + 1 } else { 0 };
            if self.cancel_run >= 5 {
                self.fail(tr("对方取消了传输"));
                let rest = &data[index + 1..];
                let rest = rest.iter().position(|&byte| byte != CAN && byte != 0x08).map_or(&[][..], |at| &rest[at..]);
                self.input = rest.to_vec();
                return;
            }
        }
        self.input.extend_from_slice(data);
    }

    /// 用户选好了上传的文件（空 = 取消）
    pub fn select_files(&mut self, files: Vec<PathBuf>) {
        if !matches!(self.role, Role::AwaitFiles) {
            return;
        }
        if files.is_empty() {
            self.cancel();
            return;
        }
        // 清掉“请选择文件”那一行
        self.display.extend_from_slice(b"\r\x1b[K");
        match Upload::new(files) {
            Ok(upload) => self.role = Role::Upload(upload),
            Err(err) => self.fail(err),
        }
        self.last_activity = Instant::now();
    }

    /// 本地取消（Ctrl-C / 关闭文件面板）
    pub fn cancel(&mut self) {
        if self.finished {
            return;
        }
        self.wire.extend_from_slice(CANCEL_SEQUENCE);
        self.end_with_error(tr("ZMODEM 已取消"));
    }

    /// 连接断了
    pub fn connection_lost(&mut self) {
        self.fail(tr("连接已断开"));
    }

    /// 推进状态机。会话循环在有新输入、收到指令或定时（约 100ms）时调用
    pub fn step(&mut self) {
        self.busy = false;
        if self.finished {
            return;
        }
        let flow = match &mut self.role {
            Role::Download(download) => download.step(&mut self.input, &mut self.wire, &mut self.display),
            Role::Upload(upload) => upload.step(&mut self.input, &mut self.wire, &mut self.display),
            Role::AwaitFiles | Role::Done => Ok(Flow::Idle),
        };
        match flow {
            Ok(Flow::Idle) => self.check_timeout(),
            Ok(Flow::Busy) => {
                self.busy = true;
                self.last_activity = Instant::now();
            }
            Ok(Flow::Done) => {
                self.finished = true;
                self.role = Role::Done;
            }
            Err(err) => self.fail(err),
        }
    }

    fn check_timeout(&mut self) {
        // 等用户在文件面板里选择时不算超时
        if matches!(self.role, Role::AwaitFiles) {
            self.last_activity = Instant::now();
            return;
        }
        let idle = self.last_activity.elapsed();
        if idle >= GIVE_UP_AFTER {
            self.wire.extend_from_slice(CANCEL_SEQUENCE);
            self.fail(tr("对方没有响应"));
            return;
        }
        if idle < RETRY_AFTER || self.last_retry.elapsed() < RETRY_AFTER {
            return;
        }
        self.last_retry = Instant::now();
        // 握手阶段重发 ZRINIT / ZRQINIT；其他阶段状态机自己忽略
        let result = match &mut self.role {
            Role::Download(download) => download.receiver.timeout(),
            Role::Upload(upload) => upload.sender.timeout(),
            Role::AwaitFiles | Role::Done => Ok(()),
        };
        if let Err(err) = result {
            self.fail(protocol_error(err));
        }
    }

    fn fail(&mut self, reason: String) {
        if self.finished {
            return;
        }
        self.end_with_error(crate::trf!("ZMODEM 传输失败：{err}", err = reason));
    }

    fn end_with_error(&mut self, message: String) {
        // 还没交给状态机的协议字节（比如 rz 的 ZRINIT）不能交还终端，否则会被当成新的起始头
        self.input.clear();
        // 没收完的文件删掉：它是这次传输刚新建的，不会碰到用户原有文件
        if let Role::Download(download) = &mut self.role {
            if let Some(incoming) = download.file.take() {
                drop(incoming.file);
                let _ = fs::remove_file(&incoming.path);
            }
        }
        self.role = Role::Done;
        self.finished = true;
        self.show_line(&message);
        self.display.extend_from_slice(b"\r\n");
    }

    fn show_line(&mut self, text: &str) {
        self.display.extend_from_slice(dim_line(text).as_bytes());
    }
}

struct Download {
    receiver: Receiver,
    dir: PathBuf,
    file: Option<Incoming>,
}

struct Incoming {
    file: File,
    path: PathBuf,
    progress: Progress,
}

impl Download {
    fn step(&mut self, input: &mut Vec<u8>, wire: &mut Vec<u8>, display: &mut Vec<u8>) -> Result<Flow, String> {
        let mut budget = STEP_BUDGET;
        loop {
            match self.receiver.poll() {
                Action::WriteWire(bytes) => {
                    wire.extend_from_slice(bytes);
                    let written = bytes.len();
                    self.receiver.wire_written(written);
                    continue;
                }
                Action::WriteFile(bytes) => {
                    let Some(incoming) = self.file.as_mut() else {
                        return Err(tr("收到了不属于任何文件的数据"));
                    };
                    incoming.file.write_all(bytes).map_err(|err| crate::trf!("写入 {path} 失败：{err}", path = incoming.path.display(), err = err))?;
                    let written = bytes.len();
                    self.receiver.file_written(written).map_err(protocol_error)?;
                    incoming.progress.advance(written as u64, display);
                    budget = budget.saturating_sub(written);
                    if budget == 0 {
                        return Ok(Flow::Busy);
                    }
                    continue;
                }
                Action::Event(Event::FileStarted(info)) => {
                    let name = String::from_utf8_lossy(info.name).to_string();
                    let size = info.size.map_or(0, |size| size.get() as u64);
                    self.open(&name, size, display)?;
                    continue;
                }
                Action::Event(Event::FileCompleted) => {
                    if let Some(incoming) = self.file.take() {
                        incoming.file.sync_all().map_err(|err| crate::trf!("写入 {path} 失败：{err}", path = incoming.path.display(), err = err))?;
                        let saved = crate::trf!("已保存到 {path}", path = incoming.path.display());
                        incoming.progress.finish(&saved, display);
                    }
                    continue;
                }
                Action::Event(Event::SessionCompleted) => {
                    // 状态机先报事件再给要发的 ZFIN，发完再结束
                    while let Action::WriteWire(bytes) = self.receiver.poll() {
                        wire.extend_from_slice(bytes);
                        let written = bytes.len();
                        self.receiver.wire_written(written);
                    }
                    return Ok(Flow::Done);
                }
                Action::Event(Event::Aborted) => return Err(tr("对方取消了传输")),
                Action::Event(_) => continue,
                _ => {}
            }
            // 状态机空闲：喂输入
            if input.is_empty() {
                return Ok(Flow::Idle);
            }
            let consumed = self.receiver.submit_wire(input).map_err(protocol_error)?;
            input.drain(..consumed);
            if consumed == 0 {
                return Ok(Flow::Idle);
            }
        }
    }

    /// 远端给的文件名只取最后一段，防止 ../ 或绝对路径写到下载目录之外；重名加序号，不覆盖
    fn open(&mut self, name: &str, size: u64, display: &mut Vec<u8>) -> Result<(), String> {
        let safe_name = safe_file_name(name);
        fs::create_dir_all(&self.dir).map_err(|err| crate::trf!("无法创建目录 {path}：{err}", path = self.dir.display(), err = err))?;
        let path = paths::unique_path(&self.dir, &safe_name);
        let file = File::options()
            .write(true)
            .create_new(true)
            .open(&path)
            .map_err(|err| crate::trf!("无法创建 {path}：{err}", path = path.display(), err = err))?;
        let mut progress = Progress::new("↓", safe_name, size);
        progress.show(display);
        self.file = Some(Incoming { file, path, progress });
        Ok(())
    }
}

struct Upload {
    sender: Sender,
    queue: Vec<PathBuf>,
    current: Option<Outgoing>,
    buffer: Vec<u8>,
}

struct Outgoing {
    file: File,
    progress: Progress,
}

impl Upload {
    fn new(files: Vec<PathBuf>) -> Result<Upload, String> {
        let mut sender = Sender::new().map_err(protocol_error)?;
        // SSH / TCP / PTY 都是可靠链路，对方支持连续接收时不必每 10 个包等一次确认
        sender.set_streaming_window(usize::MAX);
        let mut upload = Upload { sender, queue: files, current: None, buffer: Vec::new() };
        upload.queue.reverse();
        upload.start_next()?;
        Ok(upload)
    }

    /// 开始下一个文件；没有了就结束会话
    fn start_next(&mut self) -> Result<(), String> {
        let Some(path) = self.queue.pop() else {
            self.current = None;
            return self.sender.finish().map_err(protocol_error);
        };
        let file = File::open(&path).map_err(|err| crate::trf!("无法打开 {path}：{err}", path = path.display(), err = err))?;
        let size = file.metadata().map_err(|err| crate::trf!("无法打开 {path}：{err}", path = path.display(), err = err))?.len();
        let Ok(size32) = u32::try_from(size) else {
            return Err(crate::trf!("{path} 超过 4GB，ZMODEM 不支持", path = path.display()));
        };
        let name = path.file_name().map(|name| name.to_string_lossy().to_string()).unwrap_or_default();
        self.sender.start_file(FileInfo::new(name.as_bytes(), Some(Position::new(size32)))).map_err(protocol_error)?;
        self.current = Some(Outgoing { file, progress: Progress::new("↑", name, size) });
        Ok(())
    }

    fn step(&mut self, input: &mut Vec<u8>, wire: &mut Vec<u8>, display: &mut Vec<u8>) -> Result<Flow, String> {
        let mut budget = STEP_BUDGET;
        loop {
            match self.sender.poll() {
                Action::WriteWire(bytes) => {
                    wire.extend_from_slice(bytes);
                    let written = bytes.len();
                    self.sender.wire_written(written);
                    budget = budget.saturating_sub(written);
                    if budget == 0 {
                        return Ok(Flow::Busy);
                    }
                    continue;
                }
                Action::ReadFile { offset, max_len } => {
                    let Some(outgoing) = self.current.as_mut() else {
                        return Err(tr("对方请求了不存在的文件数据"));
                    };
                    let offset = offset.get() as u64;
                    outgoing.file.seek(SeekFrom::Start(offset)).map_err(|err| crate::trf!("读取文件失败：{err}", err = err))?;
                    self.buffer.clear();
                    (&outgoing.file).take(max_len as u64).read_to_end(&mut self.buffer).map_err(|err| crate::trf!("读取文件失败：{err}", err = err))?;
                    if self.buffer.is_empty() {
                        return Err(tr("文件在上传过程中被截短了"));
                    }
                    self.sender.submit_file(&self.buffer).map_err(protocol_error)?;
                    let sent = offset + self.buffer.len() as u64;
                    outgoing.progress.set(sent, display);
                    continue;
                }
                Action::Event(Event::FileCompleted) => {
                    if let Some(outgoing) = self.current.take() {
                        outgoing.progress.finish(&tr("已上传"), display);
                    }
                    self.start_next()?;
                    continue;
                }
                Action::Event(Event::SessionCompleted) => {
                    // 最后的 "OO" 在事件之后才给出
                    while let Action::WriteWire(bytes) = self.sender.poll() {
                        wire.extend_from_slice(bytes);
                        let written = bytes.len();
                        self.sender.wire_written(written);
                    }
                    return Ok(Flow::Done);
                }
                Action::Event(Event::Aborted) => return Err(tr("对方取消了传输")),
                Action::Event(_) => continue,
                _ => {}
            }
            if input.is_empty() {
                return Ok(Flow::Idle);
            }
            let consumed = self.sender.submit_wire(input).map_err(protocol_error)?;
            input.drain(..consumed);
            if consumed == 0 {
                return Ok(Flow::Idle);
            }
        }
    }
}

/// 单个文件的进度行：同一行用 \r 覆盖，最多每 0.5 秒刷新一次
struct Progress {
    arrow: &'static str,
    name: String,
    size: u64,
    done: u64,
    started: Instant,
    shown_at: Instant,
}

impl Progress {
    fn new(arrow: &'static str, name: String, size: u64) -> Progress {
        let now = Instant::now();
        Progress { arrow, name, size, done: 0, started: now, shown_at: now }
    }

    fn advance(&mut self, bytes: u64, display: &mut Vec<u8>) {
        self.set(self.done + bytes, display);
    }

    fn set(&mut self, done: u64, display: &mut Vec<u8>) {
        self.done = done;
        if self.shown_at.elapsed() >= PROGRESS_INTERVAL {
            self.show(display);
        }
    }

    fn show(&mut self, display: &mut Vec<u8>) {
        self.shown_at = Instant::now();
        // 空文件算 100%
        let percent = (self.done * 100).checked_div(self.size).map_or(100, |percent| percent.min(100));
        let seconds = self.started.elapsed().as_secs_f64().max(0.001);
        let speed = format_size((self.done as f64 / seconds) as u64);
        let text = format!("ZMODEM {} {}  {percent}%  {} / {}  {speed}/s", self.arrow, self.name, format_size(self.done), format_size(self.size));
        display.extend_from_slice(dim_line(&text).as_bytes());
    }

    fn finish(self, result: &str, display: &mut Vec<u8>) {
        let text = format!("ZMODEM {} {}  {}  {result}", self.arrow, self.name, format_size(self.size));
        display.extend_from_slice(dim_line(&text).as_bytes());
        display.extend_from_slice(b"\r\n");
    }
}

/// 回到行首、dim 样式、清掉行尾残留
fn dim_line(text: &str) -> String {
    format!("\r\x1b[2m{text}\x1b[0m\x1b[K")
}

fn format_size(bytes: u64) -> String {
    const UNITS: [&str; 4] = ["B", "KB", "MB", "GB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        return format!("{bytes} B");
    }
    format!("{value:.1} {}", UNITS[unit])
}

fn safe_file_name(name: &str) -> String {
    let last = name.rsplit(['/', '\\']).next().unwrap_or_default();
    let cleaned: String = last.chars().filter(|c| !c.is_control() && !"<>:\"|?*".contains(*c)).collect();
    let cleaned = cleaned.trim().trim_start_matches('.').to_string();
    if cleaned.is_empty() {
        return "zmodem-download".to_string();
    }
    cleaned
}

fn protocol_error(err: zmodem2::Error) -> String {
    crate::trf!("协议错误：{err}", err = err)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// lrzsz 的 sz 启动时发的 ZRQINIT 十六进制头（CRC16 = 0000）
    const SZ_START: &[u8] = b"rz\r**\x18B00000000000000\r\x8a\x11";

    fn is_start(data: &[u8]) -> Option<Direction> {
        let mut detector = Detector::default();
        detector.scan(data).1.map(|start| start.direction)
    }

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("cterm-zmodem-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn detects_start_headers() {
        let mut detector = Detector::default();
        let (shown, start) = detector.scan(SZ_START);
        assert_eq!(shown, b"rz\r");
        let start = start.unwrap();
        assert_eq!(start.direction, Direction::Download);
        assert_eq!(start.data, &SZ_START[3..]);

        // lrzsz 的 rz 发的 ZRINIT：标志 CANFDX|CANOVIO|CANFC32 = 0x23，CRC16 = be50
        assert_eq!(is_start(b"**\x18B0100000023be50\r\x8a\x11"), Some(Direction::Upload));
        assert_eq!(is_start(b"plain text ** \x18 B0"), None);
        assert_eq!(is_start(b"**\x18B02"), None);
    }

    #[test]
    fn detects_header_split_across_chunks() {
        let mut detector = Detector::default();
        let (shown, start) = detector.scan(b"hello **\x18");
        assert_eq!(shown, b"hello **\x18");
        assert!(start.is_none());
        let (shown, start) = detector.scan(b"B00000000000000\r\x8a\x11");
        assert!(shown.is_empty());
        let start = start.unwrap();
        assert_eq!(start.direction, Direction::Download);
        assert!(start.data.starts_with(b"**\x18B00"));
    }

    #[test]
    fn strips_trailer_after_transfer() {
        let mut detector = Detector::default();
        detector.finish_transfer();
        // 协议头的行尾残留单独到达时整块跳过，之后的 OO 也不显示
        assert_eq!(detector.scan(b"\r\n\x11").0, b"");
        assert_eq!(detector.scan(b"OO$ ").0, b"$ ");
        assert_eq!(detector.scan(b"OO").0, b"OO");
    }

    #[test]
    fn known_byte_sequences() {
        // 我们的发送端第一件事就是发 ZRQINIT
        let mut sender = Sender::new().unwrap();
        let Action::WriteWire(bytes) = sender.poll() else { panic!("sender should start with ZRQINIT") };
        // 十六进制头 + CRC16 与 lrzsz 相同；行尾 lrzsz 用 \r\x8a\x11，zmodem2 用 \r\n\x11，两边都接受
        assert_eq!(&bytes[..bytes.len() - 2], b"**\x18B00000000000000\r");

        // 接收端的 ZRINIT：缓冲 0、CANFDX|CANOVIO|CANFC32，CRC16 与 lrzsz 的 rz 相同
        let mut receiver = Receiver::with_flow_control(0, true).unwrap();
        let Action::WriteWire(bytes) = receiver.poll() else { panic!("receiver should start with ZRINIT") };
        assert_eq!(&bytes[..bytes.len() - 2], b"**\x18B0100000023be50\r");
    }

    #[test]
    fn file_names_stay_inside_downloads() {
        assert_eq!(safe_file_name("../../etc/passwd"), "passwd");
        assert_eq!(safe_file_name("/abs/path/a.txt"), "a.txt");
        assert_eq!(safe_file_name(r"C:\Users\x\b.bin"), "b.bin");
        assert_eq!(safe_file_name(".."), "zmodem-download");
        assert_eq!(safe_file_name(".hidden"), "hidden");
        assert_eq!(safe_file_name("a\u{1b}[31m.txt"), "a[31m.txt");
    }

    /// 两个 Transfer 首尾相接：一个扮演远端 sz（发送），一个是我们（接收）
    fn pump(ours: &mut Transfer, theirs: &mut Transfer) {
        for _ in 0..100_000 {
            ours.step();
            theirs.step();
            let to_them = ours.take_wire();
            let to_us = theirs.take_wire();
            if to_them.is_empty() && to_us.is_empty() && ours.finished() && theirs.finished() {
                return;
            }
            theirs.input(&to_them);
            ours.input(&to_us);
        }
        panic!("transfer did not finish");
    }

    #[test]
    fn round_trip_between_our_sender_and_receiver() {
        let dir = temp_dir("roundtrip");
        let source_dir = dir.join("source");
        let downloads = dir.join("downloads");
        fs::create_dir_all(&source_dir).unwrap();
        // 覆盖 ZDLE 需要转义的所有字节，跨多个子包；再加一个空文件和一个重名文件
        let mut big = Vec::new();
        for index in 0..200_000u32 {
            big.push((index % 256) as u8);
        }
        fs::write(source_dir.join("data.bin"), &big).unwrap();
        fs::write(source_dir.join("empty.txt"), b"").unwrap();
        fs::create_dir_all(&downloads).unwrap();
        fs::write(downloads.join("data.bin"), b"existing").unwrap();

        let mut remote = Transfer::new(Direction::Upload, PathBuf::new()).unwrap();
        remote.select_files(vec![source_dir.join("data.bin"), source_dir.join("empty.txt")]);
        let mut local = Transfer::new(Direction::Download, downloads.clone()).unwrap();
        pump(&mut local, &mut remote);

        let shown = String::from_utf8_lossy(&local.take_display()).to_string();
        assert!(!shown.contains("失败"), "{shown}");
        assert_eq!(fs::read(downloads.join("data.bin")).unwrap(), b"existing", "不覆盖已有文件");
        assert_eq!(fs::read(downloads.join("data (1).bin")).unwrap(), big);
        assert_eq!(fs::read(downloads.join("empty.txt")).unwrap(), b"");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn data_subpacket_escaping_and_crc32() {
        let dir = temp_dir("crc");
        fs::write(dir.join("hello.txt"), b"hello").unwrap();
        fs::write(dir.join("ctrl.bin"), [0x18, 0x11, 0x13, 0x7f]).unwrap();
        let mut remote = Transfer::new(Direction::Upload, PathBuf::new()).unwrap();
        remote.select_files(vec![dir.join("hello.txt"), dir.join("ctrl.bin")]);
        let mut local = Transfer::new(Direction::Download, dir.join("downloads")).unwrap();
        let mut sent = Vec::new();
        for _ in 0..1000 {
            local.step();
            remote.step();
            let to_remote = local.take_wire();
            let to_local = remote.take_wire();
            sent.extend_from_slice(&to_local);
            remote.input(&to_remote);
            local.input(&to_local);
            if local.finished() && remote.finished() {
                break;
            }
        }
        assert!(local.finished() && remote.finished());
        // "hello" 是文件最后一个子包：ZDLE ZCRCW('k') 后跟 CRC32("hellok") 小端 = 0x0c8f61ee
        let window = sent.windows(11).find(|window| window.starts_with(b"hello\x18k")).expect("hello subpacket");
        assert_eq!(&window[7..], &[0xee, 0x61, 0x8f, 0x0c]);
        // CAN / XON / XOFF / DEL 都经 ZDLE 转义（值 ^ 0x40）
        assert!(sent.windows(8).any(|window| window == [0x18, 0x58, 0x18, 0x51, 0x18, 0x53, 0x18, 0x6c]));
        assert_eq!(fs::read(dir.join("downloads/ctrl.bin")).unwrap(), [0x18, 0x11, 0x13, 0x7f]);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn local_cancel_sends_can_and_removes_partial_file() {
        let dir = temp_dir("cancel");
        fs::write(dir.join("big.bin"), vec![7u8; 300_000]).unwrap();
        let downloads = dir.join("downloads");
        let mut remote = Transfer::new(Direction::Upload, PathBuf::new()).unwrap();
        remote.select_files(vec![dir.join("big.bin")]);
        let mut local = Transfer::new(Direction::Download, downloads.clone()).unwrap();
        // 跑到文件已经开始写
        for _ in 0..50 {
            local.step();
            remote.step();
            let to_remote = local.take_wire();
            remote.input(&to_remote);
            let to_local = remote.take_wire();
            local.input(&to_local);
            if fs::read_dir(&downloads).map(|entries| entries.count()).unwrap_or(0) > 0 {
                break;
            }
        }
        local.cancel();
        assert!(local.finished());
        assert!(local.take_wire().ends_with(CANCEL_SEQUENCE));
        assert_eq!(fs::read_dir(&downloads).unwrap().count(), 0, "partial file removed");

        // 对方收到 5 个 CAN 也认为被取消
        remote.input(CANCEL_SEQUENCE);
        assert!(remote.finished());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn upload_cancelled_in_file_panel() {
        let mut transfer = Transfer::new(Direction::Upload, PathBuf::new()).unwrap();
        assert!(transfer.waiting_for_files());
        transfer.select_files(Vec::new());
        assert!(transfer.finished());
        assert_eq!(transfer.take_wire(), CANCEL_SEQUENCE);
    }

    #[test]
    fn sizes() {
        assert_eq!(format_size(512), "512 B");
        assert_eq!(format_size(1536), "1.5 KB");
        assert_eq!(format_size(3 * 1024 * 1024), "3.0 MB");
    }
}
