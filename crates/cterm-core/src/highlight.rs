//! 关键字高亮：按用户规则给可见行里程序没有上色的文字换颜色。
//! 只在拉帧时匹配屏幕上的行，工作量与输出速度无关；regex 是线性时间，不会因为回溯卡死。

use regex::{Regex, RegexBuilder};

use crate::config::HighlightRule;
use crate::frame::{Run, RUN_BOLD, RUN_DEFAULT_BG};
use crate::log;

#[derive(Debug, Clone, Copy, PartialEq)]
struct Style {
    /// 调色板序号 0-15
    foreground: Option<u8>,
    background: Option<u8>,
    bold: bool,
}

#[derive(Debug, Clone)]
enum Paint {
    /// 整段匹配一种样式（用户规则）
    Whole(Style),
    /// ls -l 的权限串：第 1 个捕获组按字符分色
    Permissions,
}

#[derive(Debug, Clone)]
pub struct Highlight {
    regex: Regex,
    paint: Paint,
}

/// 前后是空白或行首尾的 10 位权限串，后面可能跟 ACL / SELinux 标记
const PERMISSIONS_PATTERN: &str = r"(?:^|\s)([-bcdlps][r-][w-][xsS-][r-][w-][xsS-][r-][w-][xtT-][.+@]?)(?:\s|$)";

/// 权限串里一个字符的颜色：类型位紫，r 蓝，w 黄，x/s/t 红，- 黄绿；尾部标记不改
fn permission_style(index: usize, byte: u8) -> Option<Style> {
    let color = match (index, byte) {
        (_, b'-') => 10,
        (0, _) => 5,
        (_, b'r') => 4,
        (_, b'w') => 3,
        (_, b'x' | b's' | b'S' | b't' | b'T') => 1,
        _ => return None,
    };
    Some(Style { foreground: Some(color), background: None, bold: false })
}

fn build_regex(pattern: &str, ignore_case: bool) -> Result<Regex, regex::Error> {
    // 限制编译后大小，防止一条规则吃掉大量内存
    RegexBuilder::new(pattern).case_insensitive(ignore_case).size_limit(1 << 20).build()
}

/// 正则写法有误时返回错误说明，正确返回空串（设置页校验用）
pub fn pattern_error(pattern: &str) -> String {
    match build_regex(pattern, false) {
        Ok(_) => String::new(),
        // 语法错误的说明是多行（带脱字符定位图），设置页只要最后一行
        Err(err) => {
            let message = err.to_string();
            let last = message.lines().last().unwrap_or_default();
            last.strip_prefix("error: ").unwrap_or(last).to_string()
        }
    }
}

/// 编译启用的规则；写错的规则跳过并记日志，不影响其他规则。
/// `permissions` 打开时权限串上色排在最前，优先于用户规则（否则 -rw-r--r-- 会被选项规则整段染色）。
pub fn compile(rules: &[HighlightRule], permissions: bool) -> Vec<Highlight> {
    let mut highlights = Vec::new();
    if permissions {
        let regex = build_regex(PERMISSIONS_PATTERN, false).expect("内置权限串正则必须合法");
        highlights.push(Highlight { regex, paint: Paint::Permissions });
    }
    for rule in rules {
        if !rule.enabled || rule.pattern.is_empty() {
            continue;
        }
        match build_regex(&rule.pattern, rule.ignore_case) {
            Ok(regex) => highlights.push(Highlight {
                regex,
                paint: Paint::Whole(Style {
                    foreground: rule.foreground.filter(|color| *color < 16),
                    background: rule.background.filter(|color| *color < 16),
                    bold: rule.bold,
                }),
            }),
            Err(err) => log::warn(&format!("高亮规则 {} 无效：{err}", rule.pattern)),
        }
    }
    highlights
}

/// 给一行的文本段套高亮。`ansi` 是已应用 OSC 4 覆盖的 16 色，`default_fg` 是默认前景色。
/// 只改前景为默认色、背景为默认背景的文字，程序自己上过色的保持原样。
pub fn apply(runs: Vec<Run>, highlights: &[Highlight], ansi: &[u32; 16], default_fg: u32) -> Vec<Run> {
    if highlights.is_empty() {
        return runs;
    }
    let mut text = String::new();
    for run in &runs {
        text.push_str(&run.text);
    }

    let Some(owner) = paint(&text, highlights) else {
        return runs;
    };

    let mut result = Vec::with_capacity(runs.len());
    let mut offset = 0;
    for run in runs {
        let start = offset;
        offset += run.text.len();
        let plain = run.fg == default_fg && run.flags & RUN_DEFAULT_BG != 0;
        if !plain {
            result.push(run);
            continue;
        }
        // 合并过的 ASCII 段一个字节就是一格，可以按匹配边界切开；其余段只有一个字符，看首字节
        if run.width as usize != run.text.len() {
            result.push(restyle(run, owner[start], ansi));
            continue;
        }
        let bytes = &owner[start..offset];
        let mut piece_start = 0;
        for index in 1..=bytes.len() {
            if index < bytes.len() && bytes[index] == bytes[piece_start] {
                continue;
            }
            let piece = Run {
                col: run.col + piece_start as u16,
                width: (index - piece_start) as u16,
                text: run.text[piece_start..index].to_string(),
                ..run.clone()
            };
            result.push(restyle(piece, bytes[piece_start], ansi));
            piece_start = index;
        }
    }
    result
}

/// 每个字节用哪种样式；一处都没命中返回 None。列表里靠前的规则优先，所以倒着填，前面的覆盖后面的
fn paint(text: &str, highlights: &[Highlight]) -> Option<Vec<Option<Style>>> {
    let mut owner: Vec<Option<Style>> = vec![None; text.len()];
    let mut found = false;
    for highlight in highlights.iter().rev() {
        match highlight.paint {
            Paint::Whole(style) => {
                for matched in highlight.regex.find_iter(text) {
                    if matched.is_empty() {
                        continue;
                    }
                    found = true;
                    for slot in &mut owner[matched.range()] {
                        *slot = Some(style);
                    }
                }
            }
            Paint::Permissions => {
                for captures in highlight.regex.captures_iter(text) {
                    let Some(matched) = captures.get(1) else { continue };
                    found = true;
                    for (index, byte) in matched.as_str().bytes().enumerate() {
                        if let Some(style) = permission_style(index, byte) {
                            owner[matched.start() + index] = Some(style);
                        }
                    }
                }
            }
        }
    }
    found.then_some(owner)
}

fn restyle(mut run: Run, style: Option<Style>, ansi: &[u32; 16]) -> Run {
    let Some(style) = style else {
        return run;
    };
    if let Some(color) = style.foreground {
        run.fg = ansi[color as usize];
    }
    if let Some(color) = style.background {
        run.bg = ansi[color as usize];
        run.flags &= !RUN_DEFAULT_BG;
    }
    if style.bold {
        run.flags |= RUN_BOLD;
    }
    run
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rule(pattern: &str, foreground: u8) -> HighlightRule {
        HighlightRule { pattern: pattern.into(), foreground: Some(foreground), ..HighlightRule::default() }
    }

    #[test]
    fn invalid_and_disabled_rules_are_skipped() {
        let mut disabled = rule("ok", 2);
        disabled.enabled = false;
        let highlights = compile(&[rule("(", 1), disabled, rule("ok", 3)], false);
        assert_eq!(highlights.len(), 1);
        assert_eq!(pattern_error("("), "unclosed group");
        assert_eq!(pattern_error("ok"), "");
    }

    /// 按最终生效的样式切段，返回命中的 (文字, 前景色序号)
    fn segments(text: &str, highlights: &[Highlight]) -> Vec<(String, u8)> {
        let Some(owner) = paint(text, highlights) else {
            return Vec::new();
        };
        let mut segments: Vec<(String, u8)> = Vec::new();
        let mut previous = None;
        for (index, character) in text.char_indices() {
            let style = owner[index];
            if let Some(Style { foreground: Some(color), .. }) = style {
                match segments.last_mut() {
                    Some(last) if previous == style => last.0.push(character),
                    _ => segments.push((character.to_string(), color)),
                }
            }
            previous = style;
        }
        segments
    }

    #[test]
    fn default_rules_match_expected_text() {
        let config = crate::config::Config::default();
        let highlights = compile(&config.highlight_rules, false);
        assert_eq!(highlights.len(), config.highlight_rules.len(), "默认规则都要能编译");
        let hits = |text: &str| -> Vec<String> { segments(text, &highlights).into_iter().map(|(text, _)| text).collect() };

        for expected in ["fe80::1", "::1", "2001:db8::8a2e:370:7334", "fe80::1c2:3aff:fe4b:5d6e/64", "192.0.2.10/24", "00:1a:2b:3c:4d:5e"] {
            assert_eq!(hits(expected), [expected]);
        }
        assert_eq!(hits("12:34:56"), ["12:34:56"], "时间不能被当成 IPv6 或三个数字");
        assert_eq!(hits("2026-09-28T21:41:47.123"), ["2026-09-28T21:41:47.123"]);
        assert_eq!(hits("login failed: 连接超时"), ["failed", "超时"]);
        assert!(hits("std::io::Result Vec::new password information May I").is_empty());
        assert!(hits("ls -la --color=auto a-b").is_empty(), "默认规则不单独高亮命令行选项");
        assert_eq!(hits(r#"say "quoted 42" 50% 10.5GB 30s 1st v2 3f2b"#), [r#""quoted 42""#, "50%", "10.5GB", "30s"]);
    }

    #[test]
    fn permissions_are_colored_per_character() {
        let rules = crate::config::Config::default().highlight_rules;
        let highlights = compile(&rules, true);
        let expected = [
            ("d", 5), ("r", 4), ("w", 3), ("x", 1), ("r", 4), ("-", 10), ("s", 1), ("r", 4), ("-", 10), ("x", 1),
            ("4", 4), ("4096", 4), ("Mar  4", 10), ("2026", 4),
        ];
        let expected: Vec<(String, u8)> = expected.iter().map(|(text, color)| (text.to_string(), *color)).collect();
        assert_eq!(segments("drwxr-sr-x  4 root root 4096 Mar  4  2026 yangminguhi/", &highlights), expected);

        // 普通文件的类型位 '-' 是黄绿；ACL 标记 '.' 不改色；紧挨别的字符的 rwx 不算权限串
        let file = segments("-rw-r--r--. 1 x-rwxrwxrwx", &highlights);
        assert_eq!(file[..4], [("-".to_string(), 10), ("r".to_string(), 4), ("w".to_string(), 3), ("-".to_string(), 10)]);
        assert_eq!(file.last(), Some(&("1".to_string(), 4)));

        // 关闭权限串着色后，只剩普通数字规则命中数字，不再套命令行选项颜色
        let off = compile(&rules, false);
        assert_eq!(segments("-rw-r--r-- 1", &off), [("1".to_string(), 4)]);
    }
}
