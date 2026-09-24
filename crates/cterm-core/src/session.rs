//! 终端会话引擎：任何连接（本地 PTY / SSH / Telnet / 串口）都归一成
//! 「输出字节流 + 写入 + resize」，统一喂给同一个 alacritty_terminal。

use std::io;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Instant;

use alacritty_terminal::event::{Event, EventListener, WindowSize};
use alacritty_terminal::grid::Dimensions;
pub use alacritty_terminal::grid::Scroll;
use alacritty_terminal::index::{Column, Direction, Line, Point, Side};
use alacritty_terminal::selection::{Selection, SelectionType};
use alacritty_terminal::sync::FairMutex;
use alacritty_terminal::term::search::{Match, RegexSearch};
use alacritty_terminal::term::{self, Term, TermMode};
use alacritty_terminal::vte::ansi::{CursorShape, CursorStyle, Processor};

use crate::frame::{self, Frame, Palette};
use crate::input::{self, KeyInput, MouseInput};

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
    /// 当前搜索命中，用于高亮和“下一个”的起点
    search: Mutex<Option<Match>>,
    bold_is_bright: bool,
    scroll_on_input: bool,
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

        let session = Arc::new(Session {
            term,
            transport,
            palette,
            size: size_cell,
            wake_pending: Arc::new(AtomicBool::new(false)),
            search: Mutex::new(None),
            bold_is_bright: options.bold_is_bright,
            scroll_on_input: options.scroll_on_input,
        });

        let (tx, rx) = mpsc::channel();
        let engine = session.clone();
        thread::Builder::new()
            .name("cterm-parser".into())
            .spawn(move || engine.run_parser(rx, sink))
            .expect("spawn parser thread");
        (session, tx)
    }

    pub fn attach(&self, transport: Box<dyn Transport>) {
        *self.transport.lock().unwrap() = Some(transport);
    }

    fn run_parser(&self, rx: Receiver<Output>, sink: EventSink) {
        let mut parser: Processor = Processor::new();
        loop {
            let received = match parser.sync_timeout().sync_timeout() {
                Some(deadline) => rx.recv_timeout(deadline.saturating_duration_since(Instant::now())),
                None => rx.recv().map_err(|_| RecvTimeoutError::Disconnected),
            };
            match received {
                Ok(Output::Data(bytes)) => {
                    let mut processed = bytes.len();
                    let mut closed = None;
                    {
                        let mut term = self.term.lock();
                        parser.advance(&mut *term, &bytes);
                        // 单次持锁最多吞 64KB：界面拉帧最多等约 3ms；吞吐几乎不受影响（实测 ~100MB/s，见 tests/throughput.rs）
                        while processed < 1 << 16 {
                            match rx.try_recv() {
                                Ok(Output::Data(more)) => {
                                    processed += more.len();
                                    parser.advance(&mut *term, &more);
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
        let current_match = self.search.lock().unwrap().clone();
        let term = self.term.lock();
        let palette = self.palette.lock().unwrap();
        frame::build(&term, &palette, current_match.as_ref(), self.bold_is_bright)
    }

    pub fn write(&self, data: &[u8]) {
        if let Some(transport) = self.transport.lock().unwrap().as_mut() {
            let _ = transport.write(data);
        }
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
        let origin = match (&previous, backwards) {
            (Some(found), false) => *found.end(),
            (Some(found), true) => *found.start(),
            (None, _) => {
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
        *guard = found;
        Ok(hit)
    }

    pub fn search_clear(&self) {
        *self.search.lock().unwrap() = None;
    }

    pub fn mode(&self) -> TermMode {
        *self.term.lock().mode()
    }
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
