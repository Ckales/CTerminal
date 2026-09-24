//! 终端会话的桥接：只做类型翻译，规则都在 cterm-core。

use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex};

use cterm_core::config::Profile;
use cterm_core::session::Scroll;
use cterm_core::input::{KeyInput, MouseAction, MouseInput};
use cterm_core::session::{Session, SessionEvent, WinSize};
use flutter_rust_bridge::frb;

use crate::api::settings::current_config;
use crate::frb_generated::StreamSink;

static SESSIONS: LazyLock<Mutex<HashMap<u32, Arc<Session>>>> = LazyLock::new(|| Mutex::new(HashMap::new()));

fn session(id: u32) -> Option<Arc<Session>> {
    SESSIONS.lock().unwrap().get(&id).cloned()
}

pub(crate) fn session_by_id(id: u32) -> Option<Arc<Session>> {
    session(id)
}

pub struct TermSize {
    pub cols: u16,
    pub rows: u16,
    pub cell_width: u16,
    pub cell_height: u16,
}

impl TermSize {
    fn to_core(&self) -> WinSize {
        WinSize { cols: self.cols.max(1), rows: self.rows.max(1), cell_width: self.cell_width, cell_height: self.cell_height }
    }
}

/// kind: wakeup / title / bell / copy / exit / status / zmodem-upload
pub struct TermEvent {
    pub kind: String,
    pub text: String,
}

pub struct TermRun {
    pub col: u16,
    pub width: u16,
    pub text: String,
    pub fg: u32,
    pub bg: u32,
    pub flags: u16,
}

pub struct TermLine {
    pub hash: i64,
    pub runs: Vec<TermRun>,
}

pub struct TermFrame {
    pub cols: u16,
    pub rows: u16,
    pub lines: Vec<TermLine>,
    pub cursor_col: u16,
    pub cursor_row: u16,
    pub cursor_shape: u8,
    pub cursor_visible: bool,
    pub display_offset: u32,
    pub history_size: u32,
    pub alt_screen: bool,
    pub mouse_reporting: bool,
    pub foreground: u32,
    pub background: u32,
    pub cursor_color: u32,
}

/// 打开会话。id 由 Dart 分配，事件流在会话结束（exit）后自然停止。
pub fn term_open(id: u32, profile_json: String, size: TermSize, sink: StreamSink<TermEvent>) -> Result<(), String> {
    let profile: Profile = serde_json::from_str(&profile_json).map_err(|err| format!("配置无效：{err}"))?;
    let config = current_config();
    let events = Arc::new(move |event: SessionEvent| {
        let (kind, text) = match event {
            SessionEvent::Wakeup => ("wakeup", String::new()),
            SessionEvent::Title(title) => ("title", title),
            SessionEvent::Bell => ("bell", String::new()),
            SessionEvent::Copy(text) => ("copy", text),
            SessionEvent::Exit(reason) => ("exit", reason),
            SessionEvent::Status(text) => ("status", text),
            SessionEvent::ZmodemUpload => ("zmodem-upload", String::new()),
        };
        let _ = sink.add(TermEvent { kind: kind.into(), text });
    });
    let session = cterm_core::connect::open(&profile, &config, size.to_core(), events);
    SESSIONS.lock().unwrap().insert(id, session);
    Ok(())
}

#[frb(sync)]
pub fn term_frame(id: u32) -> Option<TermFrame> {
    let frame = session(id)?.frame();
    let mut lines = Vec::with_capacity(frame.lines.len());
    for line in frame.lines {
        let mut runs = Vec::with_capacity(line.runs.len());
        for run in line.runs {
            runs.push(TermRun { col: run.col, width: run.width, text: run.text, fg: run.fg, bg: run.bg, flags: run.flags });
        }
        lines.push(TermLine { hash: line.hash as i64, runs });
    }
    Some(TermFrame {
        cols: frame.cols,
        rows: frame.rows,
        lines,
        cursor_col: frame.cursor.col,
        cursor_row: frame.cursor.row,
        cursor_shape: frame.cursor.shape,
        cursor_visible: frame.cursor.visible,
        display_offset: frame.display_offset,
        history_size: frame.history_size,
        alt_screen: frame.alt_screen,
        mouse_reporting: frame.mouse_reporting,
        foreground: frame.foreground,
        background: frame.background,
        cursor_color: frame.cursor_color,
    })
}

/// 直接写入（快捷键动作发出的固定序列）
#[frb(sync)]
pub fn term_input(id: u32, data: Vec<u8>) {
    if let Some(session) = session(id) {
        session.input(&data);
    }
}

#[frb(sync)]
pub fn term_paste(id: u32, text: String) {
    if let Some(session) = session(id) {
        session.paste(&text);
    }
}

/// 返回 false 表示这个键不产生终端输入
#[frb(sync)]
pub fn term_key(id: u32, key: String, text: String, mods: u8, alt_is_meta: bool) -> bool {
    let Some(session) = session(id) else { return false };
    session.key(&KeyInput { key, text, mods, alt_is_meta })
}

/// action: 0 按下 1 抬起 2 移动；返回 true 表示已作为鼠标上报发给程序
#[frb(sync)]
pub fn term_mouse(id: u32, action: u8, button: u8, col: u16, row: u16, mods: u8) -> bool {
    let Some(session) = session(id) else { return false };
    let action = match action {
        0 => MouseAction::Press,
        1 => MouseAction::Release,
        _ => MouseAction::Move,
    };
    session.mouse(&MouseInput { action, button, col, row, mods })
}

/// lines > 0 向上
#[frb(sync)]
pub fn term_scroll(id: u32, lines: i32, col: u16, row: u16) {
    if let Some(session) = session(id) {
        session.scroll(lines, col, row);
    }
}

/// top / bottom / page-up / page-down / up / down
#[frb(sync)]
pub fn term_scroll_to(id: u32, target: String) {
    let Some(session) = session(id) else { return };
    let scroll = match target.as_str() {
        "top" => Scroll::Top,
        "bottom" => Scroll::Bottom,
        "page-up" => Scroll::PageUp,
        "page-down" => Scroll::PageDown,
        "up" => Scroll::Delta(1),
        "down" => Scroll::Delta(-1),
        _ => return,
    };
    session.scroll_display(scroll);
}

/// 滚动条拖动：offset = 距离底部的行数
#[frb(sync)]
pub fn term_scroll_offset(id: u32, offset: u32) {
    let Some(session) = session(id) else { return };
    session.scroll_display(Scroll::Bottom);
    session.scroll_display(Scroll::Delta(offset as i32));
}

#[frb(sync)]
pub fn term_resize(id: u32, size: TermSize) {
    if let Some(session) = session(id) {
        session.resize(size.to_core());
    }
}

/// kind: 0 普通 1 单词 2 整行 3 块
#[frb(sync)]
pub fn term_select_start(id: u32, col: u16, row: u16, right_half: bool, kind: u8) {
    if let Some(session) = session(id) {
        session.select_start(col, row, right_half, kind);
    }
}

#[frb(sync)]
pub fn term_select_update(id: u32, col: u16, row: u16, right_half: bool) {
    if let Some(session) = session(id) {
        session.select_update(col, row, right_half);
    }
}

#[frb(sync)]
pub fn term_select_all(id: u32) {
    if let Some(session) = session(id) {
        session.select_all();
    }
}

#[frb(sync)]
pub fn term_select_clear(id: u32) {
    if let Some(session) = session(id) {
        session.select_clear();
    }
}

#[frb(sync)]
pub fn term_selection_text(id: u32) -> Option<String> {
    session(id)?.selection_text()
}

#[frb(sync)]
pub fn term_line_text(id: u32, row: u16) -> String {
    match session(id) {
        Some(session) => session.line_text(row),
        None => String::new(),
    }
}

#[frb(sync)]
pub fn term_search(id: u32, pattern: String, backwards: bool) -> Result<bool, String> {
    let Some(session) = session(id) else { return Ok(false) };
    session.search(&pattern, backwards)
}

#[frb(sync)]
pub fn term_search_clear(id: u32) {
    if let Some(session) = session(id) {
        session.search_clear();
    }
}

#[frb(sync)]
pub fn term_clear(id: u32) {
    if let Some(session) = session(id) {
        session.clear();
    }
}

/// 远端 rz 在等上传时，界面选好的文件；空列表 = 取消
#[frb(sync)]
pub fn term_zmodem_upload(id: u32, paths: Vec<String>) {
    if let Some(session) = session(id) {
        session.zmodem_upload(paths.into_iter().map(std::path::PathBuf::from).collect());
    }
}

/// 关闭连接并释放会话
#[frb(sync)]
pub fn term_close(id: u32) {
    let removed = SESSIONS.lock().unwrap().remove(&id);
    if let Some(session) = removed {
        session.close();
    }
}

/// 本地 shell 当前工作目录（新标签页继承目录用），拿不到返回空
#[frb(sync)]
pub fn term_cwd(id: u32) -> String {
    match session(id) {
        Some(session) => session.cwd().unwrap_or_default(),
        None => String::new(),
    }
}

/// 配色 / 字体等设置变更后，已打开的会话立即换配色
#[frb(sync)]
pub fn term_apply_settings() {
    let palette = cterm_core::schemes::palette_for(&current_config());
    for session in SESSIONS.lock().unwrap().values() {
        session.set_palette(palette.clone());
    }
}
