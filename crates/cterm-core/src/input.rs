//! 键盘 / 鼠标 / 粘贴 → 终端输入字节（xterm 约定）

use alacritty_terminal::term::TermMode;

pub const MOD_SHIFT: u8 = 1;
pub const MOD_ALT: u8 = 1 << 1;
pub const MOD_CTRL: u8 = 1 << 2;
pub const MOD_META: u8 = 1 << 3;

/// 界面传来的按键。
/// `key`：特殊键名（Enter / ArrowUp / F5 …）或单个字符（字母键给小写，用于 Ctrl 组合）；
/// `text`：系统给出的实际输入文本（已考虑 Shift / 键盘布局），可能为空。
#[derive(Debug, Clone, Default)]
pub struct KeyInput {
    pub key: String,
    pub text: String,
    pub mods: u8,
    /// Option/Alt 当 Meta 用（发 ESC 前缀）
    pub alt_is_meta: bool,
}

/// 修饰键参数：xterm 的 1 + shift + alt*2 + ctrl*4 + meta*8，MOD_* 位值正好对应
fn modifier_param(mods: u8) -> u8 {
    1 + (mods & 0x0f)
}

/// CSI 类序列：无修饰 `ESC [ {code}{final}` / `ESC O {final}`，有修饰 `ESC [ 1;{m}{final}`
fn cursor_key(final_byte: char, mods: u8, app_cursor: bool) -> Vec<u8> {
    if mods == 0 {
        let prefix = if app_cursor { "\x1bO" } else { "\x1b[" };
        return format!("{prefix}{final_byte}").into_bytes();
    }
    format!("\x1b[1;{}{final_byte}", modifier_param(mods)).into_bytes()
}

fn tilde_key(code: u8, mods: u8) -> Vec<u8> {
    if mods == 0 {
        return format!("\x1b[{code}~").into_bytes();
    }
    format!("\x1b[{code};{}~", modifier_param(mods)).into_bytes()
}

pub fn encode_key(input: &KeyInput, mode: TermMode) -> Option<Vec<u8>> {
    let app_cursor = mode.contains(TermMode::APP_CURSOR);
    // 只看终端相关的修饰键；Cmd 组合由快捷键层处理，到这里说明没绑定，不发送
    if input.mods & MOD_META != 0 {
        return None;
    }
    let mods = input.mods;
    let alt = mods & MOD_ALT != 0 && input.alt_is_meta;
    let ctrl = mods & MOD_CTRL != 0;
    let shift = mods & MOD_SHIFT != 0;
    let esc_prefix = |mut bytes: Vec<u8>| {
        if alt {
            bytes.insert(0, 0x1b);
        }
        bytes
    };

    let bytes = match input.key.as_str() {
        "Enter" => esc_prefix(b"\r".to_vec()),
        "Backspace" => {
            if ctrl {
                esc_prefix(vec![0x08])
            } else {
                esc_prefix(vec![0x7f])
            }
        }
        "Tab" => {
            if shift {
                b"\x1b[Z".to_vec()
            } else {
                esc_prefix(b"\t".to_vec())
            }
        }
        "Escape" => esc_prefix(vec![0x1b]),
        "ArrowUp" => cursor_key('A', mods, app_cursor),
        "ArrowDown" => cursor_key('B', mods, app_cursor),
        "ArrowRight" => cursor_key('C', mods, app_cursor),
        "ArrowLeft" => cursor_key('D', mods, app_cursor),
        "Home" => cursor_key('H', mods, app_cursor),
        "End" => cursor_key('F', mods, app_cursor),
        "Insert" => tilde_key(2, mods),
        "Delete" => tilde_key(3, mods),
        "PageUp" => tilde_key(5, mods),
        "PageDown" => tilde_key(6, mods),
        "F1" => cursor_key('P', mods, true),
        "F2" => cursor_key('Q', mods, true),
        "F3" => cursor_key('R', mods, true),
        "F4" => cursor_key('S', mods, true),
        "F5" => tilde_key(15, mods),
        "F6" => tilde_key(17, mods),
        "F7" => tilde_key(18, mods),
        "F8" => tilde_key(19, mods),
        "F9" => tilde_key(20, mods),
        "F10" => tilde_key(21, mods),
        "F11" => tilde_key(23, mods),
        "F12" => tilde_key(24, mods),
        _ => {
            if ctrl {
                let control = control_byte(&input.key)?;
                return Some(esc_prefix(vec![control]));
            }
            if input.text.is_empty() {
                return None;
            }
            if alt {
                // Alt 当 Meta 时用未经 Option 变换的键，否则 ⌥B 会发出 "∫"
                let base = if input.key.chars().count() == 1 { &input.key } else { &input.text };
                let base = if shift { base.to_uppercase() } else { base.to_string() };
                return Some(esc_prefix(base.into_bytes()));
            }
            input.text.as_bytes().to_vec()
        }
    };
    Some(bytes)
}

fn control_byte(key: &str) -> Option<u8> {
    let mut chars = key.chars();
    let character = chars.next()?;
    if chars.next().is_some() {
        return None;
    }
    match character.to_ascii_lowercase() {
        c @ 'a'..='z' => Some(c as u8 - b'a' + 1),
        '@' | ' ' | '2' => Some(0),
        '[' | '3' => Some(0x1b),
        '\\' | '4' => Some(0x1c),
        ']' | '5' => Some(0x1d),
        '^' | '6' => Some(0x1e),
        '_' | '-' | '/' | '7' => Some(0x1f),
        '?' | '8' => Some(0x7f),
        _ => None,
    }
}

/// 粘贴：统一换行为 \r；开启括号粘贴时包裹，并去掉内容里的结束标记防注入
pub fn paste_bytes(text: &str, bracketed: bool) -> Vec<u8> {
    let normalized = text.replace("\r\n", "\r").replace('\n', "\r");
    if !bracketed {
        return normalized.into_bytes();
    }
    let cleaned = normalized.replace("\x1b[201~", "");
    format!("\x1b[200~{cleaned}\x1b[201~").into_bytes()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseAction {
    Press,
    Release,
    Move,
}

#[derive(Debug, Clone)]
pub struct MouseInput {
    pub action: MouseAction,
    /// 0 左 1 中 2 右；64/65 滚轮上/下
    pub button: u8,
    pub col: u16,
    pub row: u16,
    pub mods: u8,
}

impl MouseInput {
    pub fn wheel(up: bool, col: u16, row: u16) -> Self {
        MouseInput { action: MouseAction::Press, button: if up { 64 } else { 65 }, col, row, mods: 0 }
    }
}

/// 终端开启鼠标上报时编码；Shift 按住时让给界面做选区（与 xterm 一致）
pub fn encode_mouse(event: &MouseInput, mode: TermMode) -> Option<Vec<u8>> {
    if !mode.intersects(TermMode::MOUSE_MODE) || event.mods & MOD_SHIFT != 0 {
        return None;
    }
    let is_wheel = event.button >= 64;
    if event.action == MouseAction::Move {
        let wants = mode.contains(TermMode::MOUSE_MOTION)
            || (mode.contains(TermMode::MOUSE_DRAG) && event.button < 3);
        if !wants {
            return None;
        }
    }

    let mut code = event.button;
    if event.action == MouseAction::Move {
        code += 32;
    }
    if event.mods & MOD_ALT != 0 {
        code += 8;
    }
    if event.mods & MOD_CTRL != 0 {
        code += 16;
    }
    let col = event.col as u32 + 1;
    let row = event.row as u32 + 1;

    if mode.contains(TermMode::SGR_MOUSE) {
        let suffix = if event.action == MouseAction::Release && !is_wheel { 'm' } else { 'M' };
        return Some(format!("\x1b[<{code};{col};{row}{suffix}").into_bytes());
    }

    if event.action == MouseAction::Release {
        if is_wheel {
            return None;
        }
        code = 3 + (code - event.button);
    }
    let mut bytes = b"\x1b[M".to_vec();
    bytes.push(32 + code);
    for value in [col, row] {
        if mode.contains(TermMode::UTF8_MOUSE) {
            let mut buffer = [0u8; 4];
            let character = char::from_u32(32 + value)?;
            bytes.extend_from_slice(character.encode_utf8(&mut buffer).as_bytes());
        } else {
            // 经典 X10 编码只能表示 223 列以内
            if value > 223 {
                return None;
            }
            bytes.push(32 + value as u8);
        }
    }
    Some(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(key: &str, text: &str, mods: u8) -> KeyInput {
        KeyInput { key: key.into(), text: text.into(), mods, alt_is_meta: true }
    }

    #[test]
    fn arrows_respect_app_cursor_and_modifiers() {
        assert_eq!(encode_key(&key("ArrowUp", "", 0), TermMode::empty()).unwrap(), b"\x1b[A");
        assert_eq!(encode_key(&key("ArrowUp", "", 0), TermMode::APP_CURSOR).unwrap(), b"\x1bOA");
        assert_eq!(encode_key(&key("ArrowLeft", "", MOD_CTRL), TermMode::empty()).unwrap(), b"\x1b[1;5D");
        assert_eq!(encode_key(&key("PageUp", "", MOD_SHIFT), TermMode::empty()).unwrap(), b"\x1b[5;2~");
    }

    #[test]
    fn control_and_meta() {
        assert_eq!(encode_key(&key("c", "c", MOD_CTRL), TermMode::empty()).unwrap(), vec![3]);
        assert_eq!(encode_key(&key("[", "[", MOD_CTRL), TermMode::empty()).unwrap(), vec![0x1b]);
        assert_eq!(encode_key(&key("b", "∫", MOD_ALT), TermMode::empty()).unwrap(), b"\x1bb");
        assert_eq!(encode_key(&key("Backspace", "", MOD_ALT), TermMode::empty()).unwrap(), b"\x1b\x7f");
        assert_eq!(encode_key(&key("Tab", "", MOD_SHIFT), TermMode::empty()).unwrap(), b"\x1b[Z");
        // Option 不当 Meta 时按系统输入文本发送
        let mut plain = key("b", "∫", MOD_ALT);
        plain.alt_is_meta = false;
        assert_eq!(encode_key(&plain, TermMode::empty()).unwrap(), "∫".as_bytes());
        // Cmd 组合不进终端
        assert!(encode_key(&key("c", "c", MOD_META), TermMode::empty()).is_none());
    }

    #[test]
    fn text_passes_through() {
        assert_eq!(encode_key(&key("", "中文", 0), TermMode::empty()).unwrap(), "中文".as_bytes());
    }

    #[test]
    fn bracketed_paste_strips_end_marker() {
        assert_eq!(paste_bytes("a\nb", false), b"a\rb");
        assert_eq!(paste_bytes("x\x1b[201~y", true), b"\x1b[200~xy\x1b[201~");
    }

    #[test]
    fn mouse_sgr_and_x10() {
        let press = MouseInput { action: MouseAction::Press, button: 0, col: 4, row: 2, mods: 0 };
        let sgr = TermMode::MOUSE_REPORT_CLICK | TermMode::SGR_MOUSE;
        assert_eq!(encode_mouse(&press, sgr).unwrap(), b"\x1b[<0;5;3M");
        let release = MouseInput { action: MouseAction::Release, ..press.clone() };
        assert_eq!(encode_mouse(&release, sgr).unwrap(), b"\x1b[<0;5;3m");
        assert_eq!(encode_mouse(&press, TermMode::MOUSE_REPORT_CLICK).unwrap(), vec![0x1b, b'[', b'M', 32, 37, 35]);
        // 未开启上报 / 按住 Shift 时不编码
        assert!(encode_mouse(&press, TermMode::empty()).is_none());
        let shifted = MouseInput { mods: MOD_SHIFT, ..press };
        assert!(encode_mouse(&shifted, sgr).is_none());
    }

    #[test]
    fn function_and_editing_keys() {
        let plain = TermMode::empty();
        assert_eq!(encode_key(&key("F1", "", 0), plain).unwrap(), b"\x1bOP");
        // F1-F4 即使不在应用光标模式也用 SS3；带修饰时改用 CSI 1;m
        assert_eq!(encode_key(&key("F4", "", MOD_SHIFT), plain).unwrap(), b"\x1b[1;2S");
        assert_eq!(encode_key(&key("F5", "", 0), plain).unwrap(), b"\x1b[15~");
        assert_eq!(encode_key(&key("F12", "", MOD_CTRL), plain).unwrap(), b"\x1b[24;5~");
        assert_eq!(encode_key(&key("Home", "", 0), TermMode::APP_CURSOR).unwrap(), b"\x1bOH");
        assert_eq!(encode_key(&key("End", "", 0), plain).unwrap(), b"\x1b[F");
        assert_eq!(encode_key(&key("Delete", "", MOD_CTRL | MOD_SHIFT), plain).unwrap(), b"\x1b[3;6~");
        // 应用光标模式下带修饰的方向键仍是 CSI 1;m
        assert_eq!(encode_key(&key("ArrowRight", "", MOD_ALT), TermMode::APP_CURSOR).unwrap(), b"\x1b[1;3C");
        assert_eq!(encode_key(&key("Enter", "", MOD_ALT), plain).unwrap(), b"\x1b\r");
        assert_eq!(encode_key(&key("Backspace", "", MOD_CTRL), plain).unwrap(), vec![0x08]);
        assert_eq!(encode_key(&key("Escape", "", 0), plain).unwrap(), vec![0x1b]);
    }

    #[test]
    fn control_symbols_and_combinations() {
        let plain = TermMode::empty();
        assert_eq!(encode_key(&key(" ", " ", MOD_CTRL), plain).unwrap(), vec![0]);
        assert_eq!(encode_key(&key("/", "/", MOD_CTRL), plain).unwrap(), vec![0x1f]);
        assert_eq!(encode_key(&key("?", "?", MOD_CTRL), plain).unwrap(), vec![0x7f]);
        // Ctrl 字母不分大小写
        assert_eq!(encode_key(&key("C", "C", MOD_CTRL | MOD_SHIFT), plain).unwrap(), vec![3]);
        assert_eq!(encode_key(&key("c", "c", MOD_CTRL | MOD_ALT), plain).unwrap(), vec![0x1b, 3]);
        // 没有对应控制字符的键不发送，交给界面
        assert!(encode_key(&key("é", "é", MOD_CTRL), plain).is_none());
        assert!(encode_key(&key("Shift", "", 0), plain).is_none());
        assert_eq!(encode_key(&key("b", "B", MOD_ALT | MOD_SHIFT), plain).unwrap(), b"\x1bB");
    }

    #[test]
    fn paste_normalizes_newlines() {
        assert_eq!(paste_bytes("a\r\nb\nc\rd", false), b"a\rb\rc\rd");
        assert_eq!(paste_bytes("", true), b"\x1b[200~\x1b[201~");
        assert_eq!(paste_bytes("l1\r\nl2", true), b"\x1b[200~l1\rl2\x1b[201~");
    }

    #[test]
    fn mouse_release_wheel_motion_and_modifiers() {
        let click = TermMode::MOUSE_REPORT_CLICK;
        let press = MouseInput { action: MouseAction::Press, button: 2, col: 0, row: 0, mods: MOD_ALT | MOD_CTRL };
        // X10：右键 2 + Alt 8 + Ctrl 16
        assert_eq!(encode_mouse(&press, click).unwrap(), [0x1b, b'[', b'M', 32 + 26, 33, 33]);
        // X10 松开统一报 3，保留修饰位
        let release = MouseInput { action: MouseAction::Release, ..press.clone() };
        assert_eq!(encode_mouse(&release, click).unwrap(), [0x1b, b'[', b'M', 32 + 27, 33, 33]);
        // 滚轮：SGR 用 64/65，没有松开事件
        let wheel = MouseInput::wheel(false, 9, 9);
        assert_eq!(encode_mouse(&wheel, click | TermMode::SGR_MOUSE).unwrap(), b"\x1b[<65;10;10M");
        let wheel_release = MouseInput { action: MouseAction::Release, ..wheel };
        assert!(encode_mouse(&wheel_release, click).is_none());
        // 移动：只有 1002 在按键拖动时、1003 任何时候才上报
        let drag = MouseInput { action: MouseAction::Move, button: 0, col: 1, row: 1, mods: 0 };
        let hover = MouseInput { button: 3, ..drag.clone() };
        assert!(encode_mouse(&drag, click).is_none());
        assert_eq!(encode_mouse(&drag, TermMode::MOUSE_DRAG | TermMode::SGR_MOUSE).unwrap(), b"\x1b[<32;2;2M");
        assert!(encode_mouse(&hover, TermMode::MOUSE_DRAG).is_none());
        assert_eq!(encode_mouse(&hover, TermMode::MOUSE_MOTION | TermMode::SGR_MOUSE).unwrap(), b"\x1b[<35;2;2M");
    }

    #[test]
    fn mouse_large_coordinates() {
        let far = MouseInput { action: MouseAction::Press, button: 0, col: 299, row: 0, mods: 0 };
        // 经典编码超过 223 列无法表示
        assert!(encode_mouse(&far, TermMode::MOUSE_REPORT_CLICK).is_none());
        // UTF-8 扩展：32 + 300 = U+014C，两字节
        let utf8 = encode_mouse(&far, TermMode::MOUSE_REPORT_CLICK | TermMode::UTF8_MOUSE).unwrap();
        assert_eq!(utf8, [0x1b, b'[', b'M', 32, 0xc5, 0x8c, 33]);
        assert_eq!(encode_mouse(&far, TermMode::MOUSE_REPORT_CLICK | TermMode::SGR_MOUSE).unwrap(), b"\x1b[<0;300;1M");
    }
}
