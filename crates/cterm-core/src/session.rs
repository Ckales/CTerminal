//! 终端会话引擎：任何连接（本地 PTY / SSH / Telnet / 串口）都归一成
//! 「输出字节流 + 写入 + resize」，统一喂给同一个 alacritty_terminal。

use std::io;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use alacritty_terminal::event::{Event, EventListener, WindowSize};
use alacritty_terminal::grid::Dimensions;
pub use alacritty_terminal::grid::Scroll;
use alacritty_terminal::index::{Boundary, Column, Direction, Line, Point, Side};
use alacritty_terminal::selection::{Selection, SelectionType};
use alacritty_terminal::sync::FairMutex;
use alacritty_terminal::term::search::{Match, RegexSearch};
use alacritty_terminal::term::{self, Term, TermMode};
use alacritty_terminal::vte::ansi::{CursorShape, CursorStyle, Processor};

use crate::frame::{self, Frame, Palette};
use crate::input::{self, KeyInput, MouseInput};
use crate::zmodem;

/// 连接层实现：只负责把字节送出去、改窗口大小、断开。
pub trait Transport: Send {
    fn write(&mut self, data: &[u8]) -> io::Result<()>;
    fn resize(&mut self, size: WinSize);
    fn close(&mut self);
    /// 本地进程 pid，远程连接没有
    fn pid(&self) -> Option<u32> {
        None
    }
    /// SSH 连接（SFTP 用），其他连接没有
    fn ssh(&self) -> Option<Arc<crate::ssh::SshShared>> {
        None
    }
}

/// 连接层 → 引擎
pub enum Output {
    Data(Vec<u8>),
    /// 连接结束，附带给用户看的原因（退出码 / 断线原因）
    Closed(String),
}

/// 引擎 → 界面
#[derive(Debug, Clone, PartialEq)]
pub enum SessionEvent {
    /// 有新内容，界面应在下一帧拉取 `frame()`；拉取前不会重复发送
    Wakeup,
    Title(String),
    Bell,
    /// OSC 52 请求写剪贴板
    Copy(String),
    Exit(String),
    /// 连接层的提示信息（如 SSH 正在认证），显示在终端里之外的状态栏
    Status(String),
    /// 远端 rz 在等上传：界面弹出文件面板，结果交给 `zmodem_upload`
    ZmodemUpload,
}

pub type EventSink = Arc<dyn Fn(SessionEvent) + Send + Sync>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WinSize {
    pub cols: u16,
    pub rows: u16,
    pub cell_width: u16,
    pub cell_height: u16,
}

impl Dimensions for WinSize {
    fn total_lines(&self) -> usize {
        self.rows as usize
    }
    fn screen_lines(&self) -> usize {
        self.rows as usize
    }
    fn columns(&self) -> usize {
        self.cols as usize
    }
}

pub struct TermOptions {
    pub scrollback: usize,
    /// block / underline / beam：程序没有设置光标样式时的默认值
    pub cursor: String,
    /// 双击选词时的分隔符
    pub word_separators: String,
    /// 输入时滚回底部
    pub scroll_on_input: bool,
    pub palette: Palette,
    pub bold_is_bright: bool,
}

type SharedTransport = Arc<Mutex<Option<Box<dyn Transport>>>>;

struct Listener {
    sink: EventSink,
    transport: SharedTransport,
    palette: Arc<Mutex<Palette>>,
    size: Arc<Mutex<WinSize>>,
}

impl Listener {
    fn write(&self, data: &[u8]) {
        if let Some(transport) = self.transport.lock().unwrap().as_mut() {
            let _ = transport.write(data);
        }
    }
}

impl EventListener for Listener {
    fn send_event(&self, event: Event) {
        match event {
            Event::PtyWrite(text) => self.write(text.as_bytes()),
            Event::Title(title) => (self.sink)(SessionEvent::Title(title)),
            Event::ResetTitle => (self.sink)(SessionEvent::Title(String::new())),
            Event::Bell => (self.sink)(SessionEvent::Bell),
            Event::ClipboardStore(_, text) => (self.sink)(SessionEvent::Copy(text)),
            Event::ColorRequest(index, format) => {
                let rgb = self.palette.lock().unwrap().request_color(index);
                self.write(format(rgb).as_bytes());
            }
            Event::TextAreaSizeRequest(format) => {
                let size = *self.size.lock().unwrap();
                let window = WindowSize {
                    num_lines: size.rows,
                    num_cols: size.cols,
                    cell_width: size.cell_width,
                    cell_height: size.cell_height,
                };
                self.write(format(window).as_bytes());
            }
            _ => {}
        }
    }
}

pub struct Session {
    term: Arc<FairMutex<Term<Listener>>>,
    transport: SharedTransport,
    palette: Arc<Mutex<Palette>>,
    size: Arc<Mutex<WinSize>>,
    wake_pending: Arc<AtomicBool>,
    /// 当前搜索关键词与命中，用于高亮和“下一个”的起点
    search: Mutex<Option<(String, Match)>>,
    bold_is_bright: bool,
    scroll_on_input: bool,
    /// ZMODEM 传输进行中：键盘输入不进线路，Ctrl-C 取消
    zmodem_active: AtomicBool,
    zmodem_control: Sender<zmodem::Control>,
    downloads_dir: Mutex<PathBuf>,
}

impl Session {
    /// 创建会话，返回会话本身和给连接层的输出通道。
    /// 连接层建好后调用 `attach` 挂上 Transport。
    pub fn new(options: TermOptions, size: WinSize, sink: EventSink) -> (Arc<Session>, Sender<Output>) {
        let transport: SharedTransport = Arc::new(Mutex::new(None));
        let palette = Arc::new(Mutex::new(options.palette));
        let size_cell = Arc::new(Mutex::new(size));
        let listener = Listener {
            sink: sink.clone(),
            transport: transport.clone(),
            palette: palette.clone(),
            size: size_cell.clone(),
        };
        let shape = match options.cursor.as_str() {
            "underline" => CursorShape::Underline,
            "beam" => CursorShape::Beam,
            _ => CursorShape::Block,
        };
        let config = term::Config {
            scrolling_history: options.scrollback,
            default_cursor_style: CursorStyle { shape, blinking: false },
            semantic_escape_chars: options.word_separators.clone(),
            ..Default::default()
        };
        let term = Arc::new(FairMutex::new(Term::new(config, &size, listener)));
        let (control_tx, control_rx) = mpsc::channel();

        let session = Arc::new(Session {
            term,
            transport,
            palette,
            size: size_cell,
            wake_pending: Arc::new(AtomicBool::new(false)),
            search: Mutex::new(None),
            bold_is_bright: options.bold_is_bright,
            scroll_on_input: options.scroll_on_input,
            zmodem_active: AtomicBool::new(false),
            zmodem_control: control_tx,
            downloads_dir: Mutex::new(crate::paths::downloads_dir()),
        });

        let (tx, rx) = mpsc::channel();
        let engine = session.clone();
        thread::Builder::new()
            .name("cterm-parser".into())
            .spawn(move || engine.run_parser(rx, control_rx, sink))
            .expect("spawn parser thread");
        (session, tx)
    }

    pub fn attach(&self, transport: Box<dyn Transport>) {
        *self.transport.lock().unwrap() = Some(transport);
    }

    fn run_parser(&self, rx: Receiver<Output>, control: Receiver<zmodem::Control>, sink: EventSink) {
        let mut parser: Processor = Processor::new();
        let mut detector = zmodem::Detector::default();
        loop {
            let received = match parser.sync_timeout().sync_timeout() {
                Some(deadline) => rx.recv_timeout(deadline.saturating_duration_since(Instant::now())),
                None => rx.recv().map_err(|_| RecvTimeoutError::Disconnected),
            };
            match received {
                Ok(Output::Data(bytes)) => {
                    let mut processed = bytes.len();
                    let mut closed = None;
                    let mut transfer;
                    {
                        let mut term = self.term.lock();
                        transfer = advance(&mut parser, &mut term, &mut detector, &bytes);
                        // 单次持锁最多吞 64KB：界面拉帧最多等约 3ms；吞吐几乎不受影响（实测 ~100MB/s，见 tests/throughput.rs）
                        while transfer.is_none() && processed < 1 << 16 {
                            match rx.try_recv() {
                                Ok(Output::Data(more)) => {
                                    processed += more.len();
                                    transfer = advance(&mut parser, &mut term, &mut detector, &more);
                                }
                                Ok(Output::Closed(reason)) => {
                                    closed = Some(reason);
                                    break;
                                }
                                Err(_) => break,
                            }
                        }
                    }
                    if parser.sync_bytes_count() < processed {
                        self.wake(&sink);
                    }
                    if let Some(reason) = closed {
                        self.finish(&mut parser, &sink, reason);
                        return;
                    }
                    // 一条命令里连着几个 sz 时，上一个结束后的输出里可能紧跟下一个起始头
                    while let Some(start) = transfer {
                        match self.run_transfer(&rx, &control, &sink, &mut parser, &mut detector, start) {
                            Ok(next) => transfer = next,
                            Err(reason) => {
                                self.finish(&mut parser, &sink, reason);
                                return;
                            }
                        }
                    }
                }
                Ok(Output::Closed(reason)) => {
                    self.finish(&mut parser, &sink, reason);
                    return;
                }
                Err(RecvTimeoutError::Timeout) => {
                    parser.stop_sync(&mut *self.term.lock());
                    self.wake(&sink);
                }
                Err(RecvTimeoutError::Disconnected) => {
                    self.finish(&mut parser, &sink, String::new());
                    return;
                }
            }
        }
    }

    /// 接管会话收发直到 rz / sz 结束，返回紧跟着的下一次传输（如有）；连接在传输中断开时返回断开原因
    fn run_transfer(
        &self,
        rx: &Receiver<Output>,
        control: &Receiver<zmodem::Control>,
        sink: &EventSink,
        parser: &mut Processor,
        detector: &mut zmodem::Detector,
        start: zmodem::Start,
    ) -> Result<Option<zmodem::Start>, String> {
        let downloads_dir = self.downloads_dir.lock().unwrap().clone();
        let mut transfer = match zmodem::Transfer::new(start.direction, downloads_dir) {
            Ok(transfer) => transfer,
            Err(err) => {
                // 状态机都建不起来就当普通输出显示
                crate::log::warn(&format!("ZMODEM 启动失败：{err}"));
                parser.advance(&mut *self.term.lock(), &start.data);
                self.wake(sink);
                return Ok(None);
            }
        };
        crate::log::info(&format!("ZMODEM 开始：{:?}", start.direction));
        // 丢掉上一次传输残留的指令
        while control.try_recv().is_ok() {}
        self.zmodem_active.store(true, Ordering::Release);
        transfer.input(&start.data);
        if transfer.waiting_for_files() {
            sink(SessionEvent::ZmodemUpload);
        }
        let closed = loop {
            transfer.step();
            self.flush_transfer(&mut transfer, parser, sink);
            if transfer.finished() {
                break None;
            }
            let wait = if transfer.busy() { Duration::ZERO } else { Duration::from_millis(100) };
            match rx.recv_timeout(wait) {
                Ok(Output::Data(bytes)) => transfer.input(&bytes),
                Ok(Output::Closed(reason)) => {
                    transfer.connection_lost();
                    self.flush_transfer(&mut transfer, parser, sink);
                    break Some(reason);
                }
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => {
                    transfer.connection_lost();
                    self.flush_transfer(&mut transfer, parser, sink);
                    break Some(String::new());
                }
            }
            while let Ok(command) = control.try_recv() {
                match command {
                    zmodem::Control::Upload(files) => transfer.select_files(files),
                    zmodem::Control::Cancel => transfer.cancel(),
                }
            }
        };
        self.zmodem_active.store(false, Ordering::Release);
        crate::log::info("ZMODEM 结束");
        if let Some(reason) = closed {
            return Err(reason);
        }
        // 传输后面紧跟的输出（shell 提示符）照常显示
        detector.finish_transfer();
        let leftover = transfer.take_leftover();
        let next = advance(parser, &mut self.term.lock(), detector, &leftover);
        self.wake(sink);
        Ok(next)
    }

    fn flush_transfer(&self, transfer: &mut zmodem::Transfer, parser: &mut Processor, sink: &EventSink) {
        let wire = transfer.take_wire();
        if !wire.is_empty() {
            self.write_transport(&wire);
        }
        let display = transfer.take_display();
        if !display.is_empty() {
            parser.advance(&mut *self.term.lock(), &display);
            self.wake(sink);
        }
    }

    fn finish(&self, parser: &mut Processor, sink: &EventSink, reason: String) {
        parser.stop_sync(&mut *self.term.lock());
        self.wake(sink);
        sink(SessionEvent::Exit(reason));
    }

    fn wake(&self, sink: &EventSink) {
        if !self.wake_pending.swap(true, Ordering::AcqRel) {
            sink(SessionEvent::Wakeup);
        }
    }

    /// 拉取当前可见内容。调用后才会再次发送 Wakeup。
    pub fn frame(&self) -> Frame {
        self.wake_pending.store(false, Ordering::Release);
        // 锁顺序与 search() 一致：先 search 再 term
        let current_match = self.search.lock().unwrap().clone().map(|(_, found)| found);
        let term = self.term.lock();
        let palette = self.palette.lock().unwrap();
        frame::build(&term, &palette, current_match.as_ref(), self.bold_is_bright)
    }

    pub fn write(&self, data: &[u8]) {
        // ZMODEM 传输期间键盘、鼠标、粘贴都不能进线路（会破坏协议）；Ctrl-C 取消传输
        if self.zmodem_active.load(Ordering::Acquire) {
            if data.contains(&0x03) {
                let _ = self.zmodem_control.send(zmodem::Control::Cancel);
            }
            return;
        }
        self.write_transport(data);
    }

    fn write_transport(&self, data: &[u8]) {
        if let Some(transport) = self.transport.lock().unwrap().as_mut() {
            let _ = transport.write(data);
        }
    }

    /// 界面选好了要上传的文件（远端 rz 在等）；空列表 = 取消
    pub fn zmodem_upload(&self, files: Vec<PathBuf>) {
        let _ = self.zmodem_control.send(zmodem::Control::Upload(files));
    }

    /// 测试用：ZMODEM 接收的文件存到这里，不碰真实的下载文件夹
    pub fn set_downloads_dir(&self, dir: PathBuf) {
        *self.downloads_dir.lock().unwrap() = dir;
    }

    /// 用户输入：输入前滚回底部
    pub fn input(&self, data: &[u8]) {
        if self.scroll_on_input {
            self.scroll_to_bottom_if_needed();
        }
        self.write(data);
    }

    pub fn paste(&self, text: &str) {
        let bracketed = self.term.lock().mode().contains(TermMode::BRACKETED_PASTE);
        let data = input::paste_bytes(text, bracketed);
        self.input(&data);
    }

    /// 按键编码；返回 false 表示这个键不产生终端输入（交给界面处理）
    pub fn key(&self, key: &KeyInput) -> bool {
        let mode = *self.term.lock().mode();
        match input::encode_key(key, mode) {
            Some(bytes) => {
                self.input(&bytes);
                true
            }
            None => false,
        }
    }

    /// 鼠标事件：终端程序开启了鼠标上报时编码发送并返回 true，否则返回 false 让界面做选区
    pub fn mouse(&self, event: &MouseInput) -> bool {
        let mode = *self.term.lock().mode();
        match input::encode_mouse(event, mode) {
            Some(bytes) => {
                self.write(&bytes);
                true
            }
            None => false,
        }
    }

    /// 滚轮：鼠标上报 > 备用屏幕方向键 > 滚动回看
    pub fn scroll(&self, lines: i32, col: u16, row: u16) {
        let mode = *self.term.lock().mode();
        if mode.intersects(TermMode::MOUSE_MODE) {
            let event = MouseInput::wheel(lines > 0, col, row);
            for _ in 0..lines.unsigned_abs().min(10) {
                if let Some(bytes) = input::encode_mouse(&event, mode) {
                    self.write(&bytes);
                }
            }
            return;
        }
        if mode.contains(TermMode::ALT_SCREEN | TermMode::ALTERNATE_SCROLL) {
            let arrow: &[u8] = match (lines > 0, mode.contains(TermMode::APP_CURSOR)) {
                (true, true) => b"\x1bOA",
                (true, false) => b"\x1b[A",
                (false, true) => b"\x1bOB",
                (false, false) => b"\x1b[B",
            };
            let data = arrow.repeat(lines.unsigned_abs() as usize);
            self.write(&data);
            return;
        }
        self.scroll_display(Scroll::Delta(lines));
    }

    pub fn scroll_display(&self, scroll: Scroll) {
        self.term.lock().scroll_display(scroll);
        self.wake_pending.store(false, Ordering::Release);
    }

    fn scroll_to_bottom_if_needed(&self) {
        let mut term = self.term.lock();
        if term.grid().display_offset() != 0 {
            term.scroll_display(Scroll::Bottom);
        }
    }

    pub fn resize(&self, size: WinSize) {
        if size.cols == 0 || size.rows == 0 {
            return;
        }
        {
            let mut current = self.size.lock().unwrap();
            if *current == size {
                return;
            }
            *current = size;
        }
        self.term.lock().resize(size);
        if let Some(transport) = self.transport.lock().unwrap().as_mut() {
            transport.resize(size);
        }
    }

    pub fn close(&self) {
        if let Some(mut transport) = self.transport.lock().unwrap().take() {
            transport.close();
        }
    }

    pub fn ssh(&self) -> Option<Arc<crate::ssh::SshShared>> {
        self.transport.lock().unwrap().as_ref()?.ssh()
    }

    /// 本地 shell 的当前目录
    pub fn cwd(&self) -> Option<String> {
        let pid = self.transport.lock().unwrap().as_ref()?.pid()?;
        crate::local::process_cwd(pid)
    }

    pub fn set_palette(&self, palette: Palette) {
        *self.palette.lock().unwrap() = palette;
    }

    pub fn clear(&self) {
        // 清屏 + 清回看：发 Ctrl-L 让 shell 重绘提示符，再清掉本地历史
        let mut term = self.term.lock();
        term.grid_mut().clear_history();
        drop(term);
        self.input(b"\x0c");
    }

    // ---------- 选区 ----------

    /// col/row 为视口坐标；kind: 0 普通 1 单词 2 整行 3 块
    pub fn select_start(&self, col: u16, row: u16, right_half: bool, kind: u8) {
        let mut term = self.term.lock();
        let point = viewport_point(&term, col, row);
        let side = if right_half { Side::Right } else { Side::Left };
        let ty = match kind {
            1 => SelectionType::Semantic,
            2 => SelectionType::Lines,
            3 => SelectionType::Block,
            _ => SelectionType::Simple,
        };
        term.selection = Some(Selection::new(ty, point, side));
    }

    pub fn select_update(&self, col: u16, row: u16, right_half: bool) {
        let mut term = self.term.lock();
        let point = viewport_point(&term, col, row);
        let side = if right_half { Side::Right } else { Side::Left };
        if let Some(selection) = term.selection.as_mut() {
            selection.update(point, side);
        }
    }

    pub fn select_all(&self) {
        let mut term = self.term.lock();
        let start = Point::new(term.topmost_line(), Column(0));
        let end = Point::new(term.bottommost_line(), term.last_column());
        let mut selection = Selection::new(SelectionType::Simple, start, Side::Left);
        selection.update(end, Side::Right);
        term.selection = Some(selection);
    }

    pub fn select_clear(&self) {
        self.term.lock().selection = None;
    }

    pub fn selection_text(&self) -> Option<String> {
        let text = self.term.lock().selection_to_string()?;
        if text.is_empty() {
            return None;
        }
        Some(text)
    }

    /// 取视口某一行的纯文本（给链接识别用）
    pub fn line_text(&self, row: u16) -> String {
        let term = self.term.lock();
        let line = Line(row as i32 - term.grid().display_offset() as i32);
        if line > term.bottommost_line() {
            return String::new();
        }
        let start = Point::new(line, Column(0));
        let end = Point::new(line, term.last_column());
        term.bounds_to_string(start, end).trim_end_matches('\n').to_string()
    }

    // ---------- 搜索 ----------

    /// 返回是否找到。找到后滚动到匹配处并高亮。
    pub fn search(&self, pattern: &str, backwards: bool) -> Result<bool, String> {
        let mut guard = self.search.lock().unwrap();
        if pattern.is_empty() {
            *guard = None;
            return Ok(false);
        }
        let mut regex = RegexSearch::new(pattern).map_err(|err| err.to_string())?;
        let mut term = self.term.lock();
        let previous = guard.take();
        let direction = if backwards { Direction::Left } else { Direction::Right };
        let origin = match &previous {
            // 同一关键词再搜 = 下一个 / 上一个：从当前命中外侧一格开始（search_next 含起点，否则原地命中）
            Some((last, found)) if last == pattern && backwards => found.start().sub(&*term, Boundary::None, 1),
            Some((last, found)) if last == pattern => found.end().add(&*term, Boundary::None, 1),
            // 关键词变了（边输入边搜）：从当前命中处重新找，仍能匹配就留在原处
            Some((_, found)) if backwards => *found.start(),
            Some((_, found)) => *found.end(),
            None => {
                // 首次搜索从视口底部往上找，先命中最近的输出
                let offset = term.grid().display_offset() as i32;
                Point::new(Line(term.screen_lines() as i32 - 1 - offset), term.last_column())
            }
        };
        let direction = if previous.is_none() { Direction::Left } else { direction };
        let side = if direction == Direction::Right { Side::Right } else { Side::Left };
        let found = term.search_next(&mut regex, origin, direction, side, None);
        if let Some(found) = &found {
            term.scroll_to_point(*found.start());
        }
        let hit = found.is_some();
        *guard = found.map(|found| (pattern.to_string(), found));
        Ok(hit)
    }

    pub fn search_clear(&self) {
        *self.search.lock().unwrap() = None;
    }

    pub fn mode(&self) -> TermMode {
        *self.term.lock().mode()
    }
}

/// 输出交给终端解析；遇到 ZMODEM 起始头时只解析它之前的部分，返回传输起点
fn advance(parser: &mut Processor, term: &mut Term<Listener>, detector: &mut zmodem::Detector, bytes: &[u8]) -> Option<zmodem::Start> {
    let (shown, start) = detector.scan(bytes);
    parser.advance(term, shown);
    start
}

fn viewport_point<T>(term: &Term<T>, col: u16, row: u16) -> Point {
    let offset = term.grid().display_offset() as i32;
    let line = Line((row as i32).min(term.screen_lines() as i32 - 1) - offset);
    let column = Column((col as usize).min(term.columns() - 1));
    Point::new(line, column)
}

/// 调试 / 测试用：取整屏文本
pub fn screen_text(frame: &Frame) -> String {
    let mut out = String::new();
    for row in &frame.lines {
        let mut line = String::new();
        for run in &row.runs {
            line.push_str(&run.text);
        }
        out.push_str(line.trim_end());
        out.push('\n');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    use crate::frame::RUN_MATCH;

    /// 记录写出的字节和 resize，代替真实连接
    struct Recorder {
        written: Arc<Mutex<Vec<u8>>>,
        sizes: Arc<Mutex<Vec<WinSize>>>,
    }

    impl Transport for Recorder {
        fn write(&mut self, data: &[u8]) -> io::Result<()> {
            self.written.lock().unwrap().extend_from_slice(data);
            Ok(())
        }
        fn resize(&mut self, size: WinSize) {
            self.sizes.lock().unwrap().push(size);
        }
        fn close(&mut self) {}
    }

    const SIZE: WinSize = WinSize { cols: 20, rows: 5, cell_width: 8, cell_height: 16 };

    struct Harness {
        session: Arc<Session>,
        tx: Sender<Output>,
        events: Receiver<SessionEvent>,
        written: Arc<Mutex<Vec<u8>>>,
        sizes: Arc<Mutex<Vec<WinSize>>>,
    }

    impl Harness {
        fn new() -> Harness {
            let (event_tx, events) = mpsc::channel();
            let sink: EventSink = Arc::new(move |event| {
                let _ = event_tx.send(event);
            });
            let options = TermOptions {
                scrollback: 100,
                cursor: "block".into(),
                word_separators: " ".into(),
                scroll_on_input: true,
                palette: Palette::default(),
                bold_is_bright: true,
            };
            let (session, tx) = Session::new(options, SIZE, sink);
            let written = Arc::new(Mutex::new(Vec::new()));
            let sizes = Arc::new(Mutex::new(Vec::new()));
            session.attach(Box::new(Recorder { written: written.clone(), sizes: sizes.clone() }));
            Harness { session, tx, events, written, sizes }
        }

        /// 喂一段输出，等解析线程发出 Wakeup 后拉一帧（重置 Wakeup）；返回期间的其他事件
        fn feed(&self, text: &str) -> Vec<SessionEvent> {
            self.tx.send(Output::Data(text.as_bytes().to_vec())).unwrap();
            let mut others = Vec::new();
            loop {
                match self.events.recv_timeout(Duration::from_secs(5)).expect("parser should wake") {
                    SessionEvent::Wakeup => break,
                    other => others.push(other),
                }
            }
            self.session.frame();
            others
        }

        fn take_written(&self) -> Vec<u8> {
            std::mem::take(&mut *self.written.lock().unwrap())
        }

        /// 当前高亮的搜索命中在哪一行
        fn match_row(&self) -> Option<usize> {
            let frame = self.session.frame();
            frame.lines.iter().position(|line| line.runs.iter().any(|run| run.flags & RUN_MATCH != 0))
        }
    }

    #[test]
    fn search_walks_matches_and_reports_errors() {
        let harness = Harness::new();
        harness.feed("alpha\r\nbeta\r\nalpha beta");
        let session = &harness.session;
        // 首次搜索从底部往上，先命中最近的
        assert!(session.search("alpha", true).unwrap());
        assert_eq!(harness.match_row(), Some(2));
        assert!(session.search("alpha", true).unwrap());
        assert_eq!(harness.match_row(), Some(0));
        assert!(session.search("alpha", false).unwrap());
        assert_eq!(harness.match_row(), Some(2));
        // 关键词变长（边输入边搜）时留在当前命中，不跳走
        assert!(session.search("alpha b", true).unwrap());
        assert_eq!(harness.match_row(), Some(2));
        // 只有一个命中时“下一个”绕回自己
        assert!(session.search("alpha b", true).unwrap());
        assert_eq!(harness.match_row(), Some(2));
        assert!(!session.search("zzz", true).unwrap());
        assert_eq!(harness.match_row(), None);
        assert!(session.search("(", true).is_err());
        assert!(session.search("beta", true).unwrap());
        assert!(!session.search("", true).unwrap());
        assert_eq!(harness.match_row(), None);
    }

    #[test]
    fn selection_kinds_and_line_text() {
        let harness = Harness::new();
        harness.feed("alpha\r\nbeta\r\nalpha beta");
        let session = &harness.session;
        session.select_start(0, 1, false, 0);
        session.select_update(3, 1, true);
        assert_eq!(session.selection_text().unwrap(), "beta");
        // 双击选词：停在分隔符（空格）处
        session.select_start(7, 2, false, 1);
        assert_eq!(session.selection_text().unwrap(), "beta");
        session.select_start(2, 2, false, 2);
        assert_eq!(session.selection_text().unwrap().trim_end(), "alpha beta");
        // 超出视口的坐标夹到边界，不 panic
        session.select_start(99, 99, true, 0);
        session.select_clear();
        assert!(session.selection_text().is_none());
        assert_eq!(session.line_text(1), "beta");
        assert_eq!(session.line_text(4), "");
    }

    #[test]
    fn keys_paste_and_terminal_replies_go_to_transport() {
        let harness = Harness::new();
        let session = &harness.session;
        assert!(session.key(&KeyInput { key: "Enter".into(), ..Default::default() }));
        assert!(!session.key(&KeyInput { key: "c".into(), text: "c".into(), mods: input::MOD_META, alt_is_meta: false }));
        assert_eq!(harness.take_written(), b"\r");
        session.paste("a\nb");
        assert_eq!(harness.take_written(), b"a\rb");
        harness.feed("\x1b[?2004h");
        session.paste("a\nb");
        assert_eq!(harness.take_written(), b"\x1b[200~a\rb\x1b[201~");
        // 光标位置查询（DSR 6）由内核应答，经 Listener 写回连接
        harness.feed("ab\x1b[6n");
        assert_eq!(harness.take_written(), b"\x1b[1;3R");
    }

    #[test]
    fn wheel_goes_to_mouse_report_then_alt_screen_then_scrollback() {
        let harness = Harness::new();
        let session = &harness.session;
        let mut lines = String::new();
        for index in 0..20 {
            lines.push_str(&format!("line{index}\r\n"));
        }
        harness.feed(&lines);
        session.scroll(3, 0, 0);
        assert_eq!(session.frame().display_offset, 3);
        assert!(harness.take_written().is_empty());
        // 输入时回到底部
        session.input(b"x");
        assert_eq!(session.frame().display_offset, 0);
        harness.take_written();

        harness.feed("\x1b[?1049h");
        session.scroll(2, 0, 0);
        assert_eq!(harness.take_written(), b"\x1b[A\x1b[A");
        harness.feed("\x1b[?1h");
        session.scroll(-1, 0, 0);
        assert_eq!(harness.take_written(), b"\x1bOB");

        harness.feed("\x1b[?1000h\x1b[?1006h");
        session.scroll(1, 3, 4);
        assert_eq!(harness.take_written(), b"\x1b[<64;4;5M");
        // 一次滚动最多上报 10 次
        session.scroll(-50, 0, 0);
        assert_eq!(harness.take_written(), b"\x1b[<65;1;1M".repeat(10));
    }

    #[test]
    fn resize_skips_zero_and_unchanged_sizes() {
        let harness = Harness::new();
        let session = &harness.session;
        session.resize(WinSize { cols: 0, ..SIZE });
        session.resize(SIZE);
        assert!(harness.sizes.lock().unwrap().is_empty());
        let bigger = WinSize { cols: 30, ..SIZE };
        session.resize(bigger);
        session.resize(bigger);
        assert_eq!(*harness.sizes.lock().unwrap(), [bigger]);
        assert_eq!(session.frame().cols, 30);
    }

    #[test]
    fn wakeup_is_sent_once_until_frame_is_pulled() {
        let harness = Harness::new();
        let events = harness.feed("\x1b]0;hello\x07");
        assert_eq!(events, [SessionEvent::Title("hello".into())]);

        harness.tx.send(Output::Data(b"a".to_vec())).unwrap();
        assert_eq!(harness.events.recv_timeout(Duration::from_secs(5)).unwrap(), SessionEvent::Wakeup);
        harness.tx.send(Output::Data(b"b".to_vec())).unwrap();
        assert!(harness.events.recv_timeout(Duration::from_millis(200)).is_err(), "no second wakeup before frame()");
        harness.session.frame();
        harness.tx.send(Output::Data(b"c".to_vec())).unwrap();
        assert_eq!(harness.events.recv_timeout(Duration::from_secs(5)).unwrap(), SessionEvent::Wakeup);

        harness.session.frame();
        harness.tx.send(Output::Closed("bye".into())).unwrap();
        let mut exit = None;
        while let Ok(event) = harness.events.recv_timeout(Duration::from_secs(5)) {
            if let SessionEvent::Exit(reason) = event {
                exit = Some(reason);
                break;
            }
        }
        assert_eq!(exit.as_deref(), Some("bye"));
    }

    #[test]
    fn clear_drops_history_and_asks_shell_to_redraw() {
        let harness = Harness::new();
        harness.feed(&"x\r\n".repeat(20));
        assert!(harness.session.frame().history_size > 0);
        harness.session.clear();
        assert_eq!(harness.session.frame().history_size, 0);
        assert_eq!(harness.take_written(), b"\x0c");
    }
}
