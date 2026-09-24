//! 把终端网格转成界面可以直接画的「行 → 同样式文本段」。颜色在这里就解析成 RGB，
//! 界面不需要知道 ANSI 调色板。

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

use alacritty_terminal::event::EventListener;
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::Point;
use alacritty_terminal::term::cell::{Cell, Flags};
use alacritty_terminal::term::color::Colors;
use alacritty_terminal::term::search::Match;
use alacritty_terminal::term::{Term, TermMode};
use alacritty_terminal::vte::ansi::{Color, CursorShape, NamedColor, Rgb};
use serde::{Deserialize, Serialize};

pub const RUN_BOLD: u16 = 1;
pub const RUN_ITALIC: u16 = 1 << 1;
pub const RUN_UNDERLINE: u16 = 1 << 2;
pub const RUN_STRIKE: u16 = 1 << 3;
pub const RUN_SELECTED: u16 = 1 << 4;
pub const RUN_MATCH: u16 = 1 << 5;
pub const RUN_UNDERCURL: u16 = 1 << 6;
/// 背景是默认背景色，界面可以不画背景块（窗口透明时要靠这个）
pub const RUN_DEFAULT_BG: u16 = 1 << 7;

/// 终端配色：颜色都是 0xRRGGBB
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Palette {
    pub foreground: u32,
    pub background: u32,
    pub cursor: u32,
    pub ansi: [u32; 16],
}

impl Default for Palette {
    /// 默认配色
    fn default() -> Self {
        Palette {
            foreground: 0xcacaca,
            background: 0x171717,
            cursor: 0xbbbbbb,
            ansi: [
                0x000000, 0xff615a, 0xb1e969, 0xebd99c, 0x5da9f6, 0xe86aff, 0x82fff7, 0xdedacf,
                0x313131, 0xf58c80, 0xddf88f, 0xeee5b2, 0xa5c7ff, 0xddaaff, 0xb7fff9, 0xffffff,
            ],
        }
    }
}

impl Palette {
    /// xterm 256 色：0-15 取配色，16-231 为 6x6x6 色立方，232-255 为灰阶
    pub fn indexed(&self, index: u8) -> u32 {
        let index = index as u32;
        if index < 16 {
            return self.ansi[index as usize];
        }
        if index < 232 {
            let value = index - 16;
            let level = |step: u32| if step == 0 { 0 } else { step * 40 + 55 };
            let red = level(value / 36);
            let green = level((value / 6) % 6);
            let blue = level(value % 6);
            return (red << 16) | (green << 8) | blue;
        }
        let gray = (index - 232) * 10 + 8;
        (gray << 16) | (gray << 8) | gray
    }

    /// 应答 OSC 4/10/11/12 颜色查询
    pub fn request_color(&self, index: usize) -> Rgb {
        let value = match index {
            0..=255 => self.indexed(index as u8),
            256 => self.foreground,
            257 => self.background,
            _ => self.cursor,
        };
        to_rgb(value)
    }
}

fn to_rgb(value: u32) -> Rgb {
    Rgb { r: (value >> 16) as u8, g: (value >> 8) as u8, b: value as u8 }
}

fn from_rgb(rgb: Rgb) -> u32 {
    ((rgb.r as u32) << 16) | ((rgb.g as u32) << 8) | rgb.b as u32
}

/// 两色按 amount (0..=255, 取 b 的比例) 混合
fn mix(a: u32, b: u32, amount: u32) -> u32 {
    let channel = |shift: u32| {
        let x = (a >> shift) & 0xff;
        let y = (b >> shift) & 0xff;
        ((x * (255 - amount) + y * amount) / 255) << shift
    };
    channel(16) | channel(8) | channel(0)
}

#[derive(Debug, Clone, PartialEq)]
pub struct Run {
    pub col: u16,
    /// 占几个格子；宽字符单独成段，宽度为 2
    pub width: u16,
    pub text: String,
    pub fg: u32,
    pub bg: u32,
    pub flags: u16,
}

#[derive(Debug, Clone, PartialEq)]
pub struct FrameLine {
    /// 内容哈希，界面据此复用上一帧排好版的行
    pub hash: u64,
    pub runs: Vec<Run>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct FrameCursor {
    pub col: u16,
    pub row: u16,
    /// 0 块 1 下划线 2 竖线 3 空心块；visible=false 时不画
    pub shape: u8,
    pub visible: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Frame {
    pub cols: u16,
    pub rows: u16,
    pub lines: Vec<FrameLine>,
    pub cursor: FrameCursor,
    pub display_offset: u32,
    pub history_size: u32,
    pub alt_screen: bool,
    pub mouse_reporting: bool,
    /// 默认前景 / 背景 / 光标色（已应用 OSC 10/11/12 覆盖）
    pub foreground: u32,
    pub background: u32,
    pub cursor_color: u32,
}

struct Resolver<'a> {
    palette: &'a Palette,
    overrides: &'a Colors,
    bold_is_bright: bool,
}

impl Resolver<'_> {
    fn color(&self, color: Color, bold: bool) -> u32 {
        match color {
            Color::Spec(rgb) => from_rgb(rgb),
            Color::Indexed(index) => {
                let index = if bold && self.bold_is_bright && index < 8 { index + 8 } else { index };
                self.overridden(index as usize).unwrap_or_else(|| self.palette.indexed(index))
            }
            Color::Named(named) => self.named(named, bold),
        }
    }

    fn overridden(&self, index: usize) -> Option<u32> {
        self.overrides[index].map(from_rgb)
    }

    fn named(&self, named: NamedColor, bold: bool) -> u32 {
        let index = named as usize;
        if index < 16 {
            let index = if bold && self.bold_is_bright && index < 8 { index + 8 } else { index };
            return self.overridden(index).unwrap_or(self.palette.ansi[index]);
        }
        let foreground = self.overridden(NamedColor::Foreground as usize).unwrap_or(self.palette.foreground);
        let background = self.overridden(NamedColor::Background as usize).unwrap_or(self.palette.background);
        match named {
            NamedColor::Foreground | NamedColor::BrightForeground => foreground,
            NamedColor::Background => background,
            NamedColor::Cursor => self.overridden(index).unwrap_or(self.palette.cursor),
            NamedColor::DimForeground => mix(foreground, background, 85),
            // DimBlack..DimWhite 与 Black..White 同序
            _ => {
                let base = index - NamedColor::DimBlack as usize;
                mix(self.palette.ansi[base], background, 85)
            }
        }
    }

    fn background(&self) -> u32 {
        self.overridden(NamedColor::Background as usize).unwrap_or(self.palette.background)
    }
}

pub fn build<T: EventListener>(term: &Term<T>, palette: &Palette, current_match: Option<&Match>, bold_is_bright: bool) -> Frame {
    let content = term.renderable_content();
    let resolver = Resolver { palette, overrides: content.colors, bold_is_bright };
    let default_bg = resolver.background();
    let cols = term.columns();
    let rows = term.screen_lines();
    let display_offset = content.display_offset;
    let selection = content.selection;

    let mut lines: Vec<FrameLine> = Vec::with_capacity(rows);
    let mut runs: Vec<Run> = Vec::new();
    let mut current_line = None;

    for indexed in content.display_iter {
        let point = indexed.point;
        if current_line != Some(point.line) {
            if current_line.is_some() {
                lines.push(finish_line(std::mem::take(&mut runs)));
            }
            current_line = Some(point.line);
        }
        let cell: &Cell = indexed.cell;
        if cell.flags.contains(Flags::WIDE_CHAR_SPACER) {
            continue;
        }

        let bold = cell.flags.contains(Flags::BOLD);
        let mut fg = resolver.color(cell.fg, bold);
        let mut bg = resolver.color(cell.bg, false);
        if cell.flags.contains(Flags::DIM) {
            fg = mix(fg, bg, 85);
        }
        if cell.flags.contains(Flags::INVERSE) {
            std::mem::swap(&mut fg, &mut bg);
        }
        if cell.flags.contains(Flags::HIDDEN) {
            fg = bg;
        }

        let mut flags = 0u16;
        if bold {
            flags |= RUN_BOLD;
        }
        if cell.flags.contains(Flags::ITALIC) {
            flags |= RUN_ITALIC;
        }
        if cell.flags.intersects(Flags::UNDERLINE | Flags::DOUBLE_UNDERLINE | Flags::DOTTED_UNDERLINE | Flags::DASHED_UNDERLINE) {
            flags |= RUN_UNDERLINE;
        }
        if cell.flags.contains(Flags::UNDERCURL) {
            flags |= RUN_UNDERCURL;
        }
        if cell.flags.contains(Flags::STRIKEOUT) {
            flags |= RUN_STRIKE;
        }
        if selection.is_some_and(|range| range.contains(point)) {
            flags |= RUN_SELECTED;
        }
        if current_match.is_some_and(|found| in_match(found, point)) {
            flags |= RUN_MATCH;
        }
        if bg == default_bg {
            flags |= RUN_DEFAULT_BG;
        }

        let wide = cell.flags.contains(Flags::WIDE_CHAR);
        let character = if cell.flags.contains(Flags::LEADING_WIDE_CHAR_SPACER) { ' ' } else { cell.c };
        let character = if character == '\t' { ' ' } else { character };
        let zerowidth = cell.zerowidth();
        // 只有纯 ASCII 能并段：别的字符字体回退后宽度不一定等于格宽，单独定位才不会错位
        let mergeable = !wide && character.is_ascii() && zerowidth.is_none();
        let col = point.column.0 as u16;

        if mergeable {
            if let Some(last) = runs.last_mut() {
                let last_mergeable = last.width as usize == last.text.len() && last.text.is_ascii();
                if last_mergeable && last.fg == fg && last.bg == bg && last.flags == flags && last.col + last.width == col {
                    last.text.push(character);
                    last.width += 1;
                    continue;
                }
            }
        }

        let mut text = String::new();
        text.push(character);
        if let Some(extra) = zerowidth {
            text.extend(extra.iter());
        }
        // 非 ASCII 单格字符宽度记 1，但 text.len()>1 字节，上面的 last_mergeable 会把它排除
        runs.push(Run { col, width: if wide { 2 } else { 1 }, text, fg, bg, flags });
    }
    if current_line.is_some() {
        lines.push(finish_line(runs));
    }

    let cursor_point = content.cursor.point;
    let cursor_row = cursor_point.line.0 + display_offset as i32;
    let visible = content.cursor.shape != CursorShape::Hidden && cursor_row >= 0 && (cursor_row as usize) < rows;
    let shape = match content.cursor.shape {
        CursorShape::Underline => 1,
        CursorShape::Beam => 2,
        CursorShape::HollowBlock => 3,
        _ => 0,
    };

    Frame {
        cols: cols as u16,
        rows: rows as u16,
        lines,
        cursor: FrameCursor {
            col: cursor_point.column.0 as u16,
            row: cursor_row.max(0) as u16,
            shape,
            visible,
        },
        display_offset: display_offset as u32,
        history_size: term.history_size() as u32,
        alt_screen: content.mode.contains(TermMode::ALT_SCREEN),
        mouse_reporting: content.mode.intersects(TermMode::MOUSE_MODE),
        foreground: resolver.named(NamedColor::Foreground, false),
        background: default_bg,
        cursor_color: resolver.named(NamedColor::Cursor, false),
    }
}

fn in_match(found: &Match, point: Point) -> bool {
    *found.start() <= point && point <= *found.end()
}

fn finish_line(runs: Vec<Run>) -> FrameLine {
    let mut hasher = DefaultHasher::new();
    for run in &runs {
        run.col.hash(&mut hasher);
        run.text.hash(&mut hasher);
        run.fg.hash(&mut hasher);
        run.bg.hash(&mut hasher);
        run.flags.hash(&mut hasher);
    }
    FrameLine { hash: hasher.finish(), runs }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn indexed_colors_follow_xterm() {
        let palette = Palette::default();
        assert_eq!(palette.indexed(1), 0xff615a);
        assert_eq!(palette.indexed(16), 0x000000);
        assert_eq!(palette.indexed(196), 0xff0000);
        assert_eq!(palette.indexed(231), 0xffffff);
        assert_eq!(palette.indexed(232), 0x080808);
        assert_eq!(palette.indexed(255), 0xeeeeee);
    }

    #[test]
    fn mix_endpoints() {
        assert_eq!(mix(0xffffff, 0x000000, 0), 0xffffff);
        assert_eq!(mix(0xffffff, 0x000000, 255), 0x000000);
    }

    use alacritty_terminal::event::VoidListener;
    use alacritty_terminal::term::Config;
    use alacritty_terminal::vte::ansi::Processor;

    use crate::session::WinSize;

    /// 喂一段 VT 输出，返回生成的帧
    fn render(output: &str, bold_is_bright: bool) -> Frame {
        let size = WinSize { cols: 20, rows: 3, cell_width: 8, cell_height: 16 };
        let mut term = Term::new(Config::default(), &size, VoidListener);
        let mut parser: Processor = Processor::new();
        parser.advance(&mut term, output.as_bytes());
        build(&term, &Palette::default(), None, bold_is_bright)
    }

    /// 各段文本（去掉行尾补齐的空格段）
    fn texts(line: &FrameLine) -> Vec<&str> {
        let mut texts = Vec::new();
        for run in &line.runs {
            let text = run.text.trim_end_matches(' ');
            if !text.is_empty() {
                texts.push(text);
            }
        }
        texts
    }

    #[test]
    fn ascii_merges_until_style_changes() {
        let frame = render("ab\x1b[31mcd\x1b[0me", true);
        let runs = &frame.lines[0].runs;
        assert_eq!(texts(&frame.lines[0]), ["ab", "cd", "e"]);
        assert_eq!(runs[1].col, 2);
        assert_eq!(runs[1].width, 2);
        assert_eq!(runs[1].fg, Palette::default().ansi[1]);
        assert!(runs[0].flags & RUN_DEFAULT_BG != 0);
        assert_eq!(frame.lines.len(), 3);
    }

    #[test]
    fn wide_and_non_ascii_chars_get_their_own_runs() {
        let frame = render("a中be\u{301}c", true);
        let runs = &frame.lines[0].runs;
        assert_eq!(texts(&frame.lines[0]), ["a", "中", "b", "e\u{301}", "c"]);
        // 宽字符占两格，占位格不单独出段
        assert_eq!((runs[1].col, runs[1].width), (1, 2));
        assert_eq!(runs[2].col, 3);
        // 组合字符跟在基字符里，只占一格
        assert_eq!((runs[3].col, runs[3].width), (4, 1));
        assert_eq!(runs[4].col, 5);
    }

    #[test]
    fn color_forms_resolve_to_rgb() {
        let frame = render("\x1b[38;2;1;2;3mA\x1b[38;5;196mB\x1b[1;31mC\x1b[0;1;38;5;1mD", true);
        let runs = &frame.lines[0].runs;
        let palette = Palette::default();
        assert_eq!(runs[0].fg, 0x010203);
        assert_eq!(runs[1].fg, 0xff0000);
        // 粗体 + 基本色 → 亮色（bold_is_bright），256 色写法的 0-7 同样处理，所以 C、D 同色并段
        assert_eq!(runs[2].fg, palette.ansi[9]);
        assert_eq!(runs[2].flags & RUN_BOLD, RUN_BOLD);
        assert_eq!(runs[2].text, "CD");
        let plain = render("\x1b[1;31mC", false);
        assert_eq!(plain.lines[0].runs[0].fg, palette.ansi[1]);
    }

    #[test]
    fn inverse_hidden_and_decorations() {
        let palette = Palette::default();
        let frame = render("\x1b[7mI\x1b[0;8mH\x1b[0;4;9;3mU", true);
        let runs = &frame.lines[0].runs;
        assert_eq!((runs[0].fg, runs[0].bg), (palette.background, palette.foreground));
        assert_eq!(runs[0].flags & RUN_DEFAULT_BG, 0);
        assert_eq!(runs[1].fg, runs[1].bg);
        assert_eq!(runs[2].flags & (RUN_UNDERLINE | RUN_STRIKE | RUN_ITALIC), RUN_UNDERLINE | RUN_STRIKE | RUN_ITALIC);
    }

    #[test]
    fn line_hash_tracks_content() {
        let frame = render("same\r\nsame\r\nother", true);
        assert_eq!(frame.lines[0].hash, frame.lines[1].hash);
        assert_ne!(frame.lines[0].hash, frame.lines[2].hash);
    }

    #[test]
    fn cursor_and_default_colors() {
        let frame = render("ab\x1b[?25l", true);
        assert_eq!((frame.cursor.col, frame.cursor.row), (2, 0));
        assert!(!frame.cursor.visible);
        let frame = render("\x1b[6 q", true);
        assert_eq!(frame.cursor.shape, 2);
        assert!(frame.cursor.visible);
        // OSC 11 改背景后，默认背景标记跟着新背景走
        let frame = render("\x1b]11;#102030\x07x", true);
        assert_eq!(frame.background, 0x102030);
        assert!(frame.lines[0].runs[0].flags & RUN_DEFAULT_BG != 0);
    }

    #[test]
    fn color_queries() {
        let palette = Palette::default();
        assert_eq!(from_rgb(palette.request_color(1)), palette.ansi[1]);
        assert_eq!(from_rgb(palette.request_color(256)), palette.foreground);
        assert_eq!(from_rgb(palette.request_color(257)), palette.background);
        assert_eq!(from_rgb(palette.request_color(258)), palette.cursor);
    }
}
