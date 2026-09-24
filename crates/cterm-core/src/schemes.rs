//! 内置配色方案（公开的通用配色定义）

use crate::config::{ColorScheme, Config};
use crate::frame::Palette;

fn scheme(name: &str, foreground: &str, background: &str, cursor: &str, colors: [&str; 16]) -> ColorScheme {
    ColorScheme {
        name: name.into(),
        foreground: foreground.into(),
        background: background.into(),
        cursor: cursor.into(),
        colors: colors.iter().map(|color| color.to_string()).collect(),
    }
}

pub fn builtin() -> Vec<ColorScheme> {
    vec![
        scheme("CTerminal Default", "#cacaca", "#171717", "#bbbbbb", [
            "#000000", "#ff615a", "#b1e969", "#ebd99c", "#5da9f6", "#e86aff", "#82fff7", "#dedacf",
            "#313131", "#f58c80", "#ddf88f", "#eee5b2", "#a5c7ff", "#ddaaff", "#b7fff9", "#ffffff",
        ]),
        scheme("Solarized Dark", "#839496", "#002b36", "#93a1a1", [
            "#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
            "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3",
        ]),
        scheme("Solarized Light", "#657b83", "#fdf6e3", "#586e75", [
            "#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
            "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3",
        ]),
        scheme("Dracula", "#f8f8f2", "#282a36", "#f8f8f2", [
            "#21222c", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
            "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a4ffff", "#ffffff",
        ]),
        scheme("One Dark", "#abb2bf", "#282c34", "#528bff", [
            "#282c34", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
            "#5c6370", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#ffffff",
        ]),
        scheme("Monokai", "#f8f8f2", "#272822", "#f8f8f0", [
            "#272822", "#f92672", "#a6e22e", "#f4bf75", "#66d9ef", "#ae81ff", "#a1efe4", "#f8f8f2",
            "#75715e", "#f92672", "#a6e22e", "#f4bf75", "#66d9ef", "#ae81ff", "#a1efe4", "#f9f8f5",
        ]),
        scheme("Nord", "#d8dee9", "#2e3440", "#d8dee9", [
            "#3b4252", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
            "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4",
        ]),
        scheme("Gruvbox Dark", "#ebdbb2", "#282828", "#ebdbb2", [
            "#282828", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#a89984",
            "#928374", "#fb4934", "#b8bb26", "#fabd2f", "#83a598", "#d3869b", "#8ec07c", "#ebdbb2",
        ]),
        scheme("Tomorrow Night", "#c5c8c6", "#1d1f21", "#c5c8c6", [
            "#1d1f21", "#cc6666", "#b5bd68", "#f0c674", "#81a2be", "#b294bb", "#8abeb7", "#c5c8c6",
            "#969896", "#cc6666", "#b5bd68", "#f0c674", "#81a2be", "#b294bb", "#8abeb7", "#ffffff",
        ]),
        scheme("GitHub Light", "#24292f", "#ffffff", "#044289", [
            "#24292f", "#cf222e", "#116329", "#4d2d00", "#0969da", "#8250df", "#1b7c83", "#6e7781",
            "#57606a", "#a40e26", "#1a7f37", "#633c01", "#218bff", "#a475f9", "#3192aa", "#8c959f",
        ]),
    ]
}

/// 所有可选配色：内置在前，自定义在后（同名时自定义覆盖内置）
pub fn all(config: &Config) -> Vec<ColorScheme> {
    let mut schemes = builtin();
    for custom in &config.custom_color_schemes {
        schemes.retain(|existing| existing.name != custom.name);
        schemes.push(custom.clone());
    }
    schemes
}

/// 当前配色；名称找不到或定义有误时用默认配色，并不静默改写配置
pub fn palette_for(config: &Config) -> Palette {
    let name = &config.terminal.color_scheme;
    for scheme in all(config) {
        if &scheme.name == name {
            if let Some(palette) = scheme.to_palette() {
                return palette;
            }
        }
    }
    Palette::default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builtin_schemes_are_valid() {
        for scheme in builtin() {
            assert!(scheme.to_palette().is_some(), "{} is invalid", scheme.name);
        }
        assert_eq!(builtin()[0].to_palette().unwrap(), Palette::default());
    }
}
