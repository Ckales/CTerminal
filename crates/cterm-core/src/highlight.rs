//! 关键字高亮：按用户规则给可见行里程序没有上色的文字换颜色。
//! 只在拉帧时匹配屏幕上的行，工作量与输出速度无关；regex 是线性时间，不会因为回溯卡死。

use regex::{Regex, RegexBuilder};

use crate::config::HighlightRule;
use crate::frame::{Run, RUN_BOLD, RUN_DEFAULT_BG};
use crate::log;

#[derive(Debug, Clone)]
pub struct Highlight {
    regex: Regex,
    /// 调色板序号 0-15
    foreground: Option<u8>,
    background: Option<u8>,
    bold: bool,
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

/// 编译启用的规则；写错的规则跳过并记日志，不影响其他规则
pub fn compile(rules: &[HighlightRule]) -> Vec<Highlight> {
    let mut highlights = Vec::new();
    for rule in rules {
        if !rule.enabled || rule.pattern.is_empty() {
            continue;
        }
        match build_regex(&rule.pattern, rule.ignore_case) {
            Ok(regex) => highlights.push(Highlight {
                regex,
                foreground: rule.foreground.filter(|color| *color < 16),
                background: rule.background.filter(|color| *color < 16),
                bold: rule.bold,
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

    // 每个字节归哪条规则。列表里靠前的规则优先，所以倒着填，前面的覆盖后面的
    let mut owner: Vec<Option<usize>> = vec![None; text.len()];
    let mut found = false;
    for (index, highlight) in highlights.iter().enumerate().rev() {
        for matched in highlight.regex.find_iter(&text) {
            if matched.is_empty() {
                continue;
            }
            found = true;
            for slot in &mut owner[matched.range()] {
                *slot = Some(index);
            }
        }
    }
    if !found {
        return runs;
    }

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
            result.push(restyle(run, owner[start], highlights, ansi));
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
            result.push(restyle(piece, bytes[piece_start], highlights, ansi));
            piece_start = index;
        }
    }
    result
}

fn restyle(mut run: Run, owner: Option<usize>, highlights: &[Highlight], ansi: &[u32; 16]) -> Run {
    let Some(index) = owner else {
        return run;
    };
    let highlight = &highlights[index];
    if let Some(color) = highlight.foreground {
        run.fg = ansi[color as usize];
    }
    if let Some(color) = highlight.background {
        run.bg = ansi[color as usize];
        run.flags &= !RUN_DEFAULT_BG;
    }
    if highlight.bold {
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
        let highlights = compile(&[rule("(", 1), disabled, rule("ok", 3)]);
        assert_eq!(highlights.len(), 1);
        assert_eq!(pattern_error("("), "unclosed group");
        assert_eq!(pattern_error("ok"), "");
    }
}
