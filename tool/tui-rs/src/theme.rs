//! Semantic theme tokens, auto-matched to herdr's `[theme]` setting.
//!
//! herdr (the terminal workspace the pasture lives inside) already themes every
//! pane; the TUI reads `~/.config/herdr/config.toml` and maps the same theme
//! name onto its own semantic tokens, so the pasture never clashes with the
//! room it's standing in. Resolution order:
//!
//!   1. `/theme <name>` runtime override (session-local)
//!   2. `$PASTURE_THEME` / `$STITCHPAD_THEME` env
//!   3. herdr config `[theme] name` (with `auto_switch` → macOS appearance)
//!   4. `terminal` — pure ANSI, inherits whatever scheme the terminal runs
//!
//! `NO_COLOR` forces the `terminal` palette (layout + weight carry meaning).
//! The herdr config is mtime-watched by the background ticker, so changing the
//! herdr theme re-skins a running pasture within seconds.

use ratatui::style::Color;
use std::sync::Mutex;
use std::time::SystemTime;

/// Semantic tokens. Widgets never name raw colors — they ask for meaning.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Theme {
    /// Terminal-default or palette background. Painted once per frame.
    pub bg: Color,
    /// Primary text.
    pub fg: Color,
    /// Raised surfaces: input box fill, modal fill, selected card row.
    pub surface: Color,
    /// Secondary text: metadata, timestamps, seen-by.
    pub muted: Color,
    /// Chrome: borders, rules, disabled, gutters that must whisper.
    pub faint: Color,
    /// The theme's voice — focused borders, active tab, links, the sheep's face.
    pub accent: Color,
    /// success / online / done / grass.
    pub ok: Color,
    /// warning / in-progress / medium priority / inline code.
    pub warn: Color,
    /// error / urgent / stale.
    pub err: Color,
    /// informational / todo columns.
    pub info: Color,
    /// special / in-review / magenta-family.
    pub special: Color,
    /// Wool — the sheep's fleece; near-fg cloud white on dark, warm ivory on light.
    pub wool: Color,
    pub is_light: bool,
}

const fn rgb(hex: u32) -> Color {
    Color::Rgb((hex >> 16) as u8, (hex >> 8) as u8, hex as u8)
}

/// The `terminal` theme: pure ANSI, no RGB — inherits the terminal's own scheme.
/// Also the NO_COLOR / unknown-name fallback.
const TERMINAL: Theme = Theme {
    bg: Color::Reset,
    fg: Color::Reset,
    surface: Color::Reset,
    muted: Color::Gray,
    faint: Color::DarkGray,
    accent: Color::Cyan,
    ok: Color::Green,
    warn: Color::Yellow,
    err: Color::Red,
    info: Color::Blue,
    special: Color::Magenta,
    wool: Color::White,
    is_light: false,
};

/// Map a herdr theme name onto tokens. Every herdr built-in is covered.
pub fn palette(name: &str) -> Theme {
    match name.trim().to_lowercase().as_str() {
        "catppuccin" | "catppuccin-mocha" => Theme {
            bg: rgb(0x1e1e2e), fg: rgb(0xcdd6f4), surface: rgb(0x313244),
            muted: rgb(0xa6adc8), faint: rgb(0x585b70), accent: rgb(0xcba6f7),
            ok: rgb(0xa6e3a1), warn: rgb(0xf9e2af), err: rgb(0xf38ba8),
            info: rgb(0x89b4fa), special: rgb(0xf5c2e7), wool: rgb(0xf5e0dc),
            is_light: false,
        },
        "catppuccin-latte" => Theme {
            bg: rgb(0xeff1f5), fg: rgb(0x4c4f69), surface: rgb(0xdce0e8),
            muted: rgb(0x6c6f85), faint: rgb(0x9ca0b0), accent: rgb(0x8839ef),
            ok: rgb(0x40a02b), warn: rgb(0xdf8e1d), err: rgb(0xd20f39),
            info: rgb(0x1e66f5), special: rgb(0xea76cb), wool: rgb(0xdc8a78),
            is_light: true,
        },
        "tokyo-night" => Theme {
            bg: rgb(0x1a1b26), fg: rgb(0xc0caf5), surface: rgb(0x24283b),
            muted: rgb(0xa9b1d6), faint: rgb(0x565f89), accent: rgb(0x7aa2f7),
            ok: rgb(0x9ece6a), warn: rgb(0xe0af68), err: rgb(0xf7768e),
            info: rgb(0x7dcfff), special: rgb(0xbb9af7), wool: rgb(0xcfc9c2),
            is_light: false,
        },
        "tokyo-night-day" => Theme {
            bg: rgb(0xe1e2e7), fg: rgb(0x3760bf), surface: rgb(0xc4c8da),
            muted: rgb(0x6172b0), faint: rgb(0x9699a3), accent: rgb(0x2e7de9),
            ok: rgb(0x587539), warn: rgb(0x8c6c3e), err: rgb(0xf52a65),
            info: rgb(0x007197), special: rgb(0x9854f1), wool: rgb(0x6172b0),
            is_light: true,
        },
        "dracula" => Theme {
            bg: rgb(0x282a36), fg: rgb(0xf8f8f2), surface: rgb(0x44475a),
            muted: rgb(0xbfc7d5), faint: rgb(0x6272a4), accent: rgb(0xbd93f9),
            ok: rgb(0x50fa7b), warn: rgb(0xf1fa8c), err: rgb(0xff5555),
            info: rgb(0x8be9fd), special: rgb(0xff79c6), wool: rgb(0xf8f8f2),
            is_light: false,
        },
        "nord" => Theme {
            bg: rgb(0x2e3440), fg: rgb(0xeceff4), surface: rgb(0x3b4252),
            muted: rgb(0xd8dee9), faint: rgb(0x4c566a), accent: rgb(0x88c0d0),
            ok: rgb(0xa3be8c), warn: rgb(0xebcb8b), err: rgb(0xbf616a),
            info: rgb(0x81a1c1), special: rgb(0xb48ead), wool: rgb(0xe5e9f0),
            is_light: false,
        },
        "gruvbox" | "gruvbox-dark" => Theme {
            bg: rgb(0x282828), fg: rgb(0xebdbb2), surface: rgb(0x3c3836),
            muted: rgb(0xbdae93), faint: rgb(0x665c54), accent: rgb(0xfe8019),
            ok: rgb(0xb8bb26), warn: rgb(0xfabd2f), err: rgb(0xfb4934),
            info: rgb(0x83a598), special: rgb(0xd3869b), wool: rgb(0xfbf1c7),
            is_light: false,
        },
        "gruvbox-light" => Theme {
            bg: rgb(0xfbf1c7), fg: rgb(0x3c3836), surface: rgb(0xebdbb2),
            muted: rgb(0x665c54), faint: rgb(0xa89984), accent: rgb(0xaf3a03),
            ok: rgb(0x79740e), warn: rgb(0xb57614), err: rgb(0x9d0006),
            info: rgb(0x076678), special: rgb(0x8f3f71), wool: rgb(0x504945),
            is_light: true,
        },
        "one-dark" => Theme {
            bg: rgb(0x282c34), fg: rgb(0xabb2bf), surface: rgb(0x353b45),
            muted: rgb(0x9da5b4), faint: rgb(0x5c6370), accent: rgb(0x61afef),
            ok: rgb(0x98c379), warn: rgb(0xe5c07b), err: rgb(0xe06c75),
            info: rgb(0x56b6c2), special: rgb(0xc678dd), wool: rgb(0xdcdfe4),
            is_light: false,
        },
        "one-light" => Theme {
            bg: rgb(0xfafafa), fg: rgb(0x383a42), surface: rgb(0xe5e5e6),
            muted: rgb(0x696c77), faint: rgb(0xa0a1a7), accent: rgb(0x4078f2),
            ok: rgb(0x50a14f), warn: rgb(0xc18401), err: rgb(0xe45649),
            info: rgb(0x0184bc), special: rgb(0xa626a4), wool: rgb(0x696c77),
            is_light: true,
        },
        "solarized" | "solarized-dark" => Theme {
            bg: rgb(0x002b36), fg: rgb(0x93a1a1), surface: rgb(0x073642),
            muted: rgb(0x839496), faint: rgb(0x586e75), accent: rgb(0x268bd2),
            ok: rgb(0x859900), warn: rgb(0xb58900), err: rgb(0xdc322f),
            info: rgb(0x2aa198), special: rgb(0xd33682), wool: rgb(0xeee8d5),
            is_light: false,
        },
        "solarized-light" => Theme {
            bg: rgb(0xfdf6e3), fg: rgb(0x586e75), surface: rgb(0xeee8d5),
            muted: rgb(0x657b83), faint: rgb(0x93a1a1), accent: rgb(0x268bd2),
            ok: rgb(0x859900), warn: rgb(0xb58900), err: rgb(0xdc322f),
            info: rgb(0x2aa198), special: rgb(0xd33682), wool: rgb(0x073642),
            is_light: true,
        },
        "kanagawa" | "kanagawa-wave" => Theme {
            bg: rgb(0x1f1f28), fg: rgb(0xdcd7ba), surface: rgb(0x2a2a37),
            muted: rgb(0xc8c093), faint: rgb(0x54546d), accent: rgb(0x7e9cd8),
            ok: rgb(0x98bb6c), warn: rgb(0xe6c384), err: rgb(0xc34043),
            info: rgb(0x7fb4ca), special: rgb(0x957fb8), wool: rgb(0xdcd7ba),
            is_light: false,
        },
        "kanagawa-lotus" => Theme {
            bg: rgb(0xf2ecbc), fg: rgb(0x545464), surface: rgb(0xe4d794),
            muted: rgb(0x716e61), faint: rgb(0x8a8980), accent: rgb(0x4d699b),
            ok: rgb(0x6f894e), warn: rgb(0x77713f), err: rgb(0xc84053),
            info: rgb(0x597b75), special: rgb(0xb35b79), wool: rgb(0x545464),
            is_light: true,
        },
        "rose-pine" => Theme {
            bg: rgb(0x191724), fg: rgb(0xe0def4), surface: rgb(0x26233a),
            muted: rgb(0x908caa), faint: rgb(0x6e6a86), accent: rgb(0xc4a7e7),
            ok: rgb(0x9ccfd8), warn: rgb(0xf6c177), err: rgb(0xeb6f92),
            info: rgb(0x31748f), special: rgb(0xebbcba), wool: rgb(0xe0def4),
            is_light: false,
        },
        "rose-pine-dawn" => Theme {
            bg: rgb(0xfaf4ed), fg: rgb(0x575279), surface: rgb(0xf2e9e1),
            muted: rgb(0x797593), faint: rgb(0x9893a5), accent: rgb(0x907aa9),
            ok: rgb(0x56949f), warn: rgb(0xea9d34), err: rgb(0xb4637a),
            info: rgb(0x286983), special: rgb(0xd7827e), wool: rgb(0x575279),
            is_light: true,
        },
        "vesper" => Theme {
            bg: rgb(0x101010), fg: rgb(0xffffff), surface: rgb(0x232323),
            muted: rgb(0xa0a0a0), faint: rgb(0x505050), accent: rgb(0xffc799),
            ok: rgb(0x99ffe4), warn: rgb(0xffc799), err: rgb(0xff8080),
            info: rgb(0x99ffe4), special: rgb(0xffc799), wool: rgb(0xffffff),
            is_light: false,
        },
        _ => TERMINAL, // "terminal" + unknown names + NO_COLOR
    }
}

struct State {
    theme: Theme,
    /// `/theme <name>` session override; None = auto-follow herdr.
    r#override: Option<String>,
    /// herdr config mtime at last load — cheap change detection.
    config_mtime: Option<SystemTime>,
}

static STATE: Mutex<State> = Mutex::new(State {
    theme: TERMINAL,
    r#override: None,
    config_mtime: None,
});

/// The current theme (copy — tokens are tiny).
pub fn t() -> Theme {
    STATE.lock().map(|s| s.theme).unwrap_or(TERMINAL)
}

/// Resolve + install the theme. Returns the resolved source label for flashes,
/// e.g. `solarized-light (herdr)` or `nord (override)`.
pub fn load() -> String {
    let (name, source) = resolve_name();
    let theme = palette(&name);
    if let Ok(mut s) = STATE.lock() {
        s.theme = theme;
        s.config_mtime = herdr_config_path().and_then(|p| std::fs::metadata(p).ok()?.modified().ok());
    }
    format!("{} ({})", name, source)
}

/// Set (or clear, with "auto") the session override, then reload.
pub fn set_override(name: &str) -> Result<String, String> {
    let n = name.trim().to_lowercase();
    if n == "auto" || n.is_empty() {
        if let Ok(mut s) = STATE.lock() {
            s.r#override = None;
        }
        return Ok(load());
    }
    if palette(&n) == TERMINAL && n != "terminal" {
        return Err(format!("unknown theme '{}' — try a herdr theme name or 'auto'", n));
    }
    if let Ok(mut s) = STATE.lock() {
        s.r#override = Some(n);
    }
    Ok(load())
}

/// Called from the background ticker: reload only if the herdr config changed
/// on disk (mtime) and no session override is pinned. Returns Some(label) when
/// the theme actually changed.
pub fn reload_if_stale() -> Option<String> {
    {
        let s = STATE.lock().ok()?;
        if s.r#override.is_some() {
            return None;
        }
        let now = herdr_config_path().and_then(|p| std::fs::metadata(p).ok()?.modified().ok());
        if now == s.config_mtime {
            return None;
        }
    }
    let before = t();
    let label = load();
    (t() != before).then_some(label)
}

fn herdr_config_path() -> Option<std::path::PathBuf> {
    std::env::var_os("HOME").map(|h| std::path::PathBuf::from(h).join(".config/herdr/config.toml"))
}

/// Where the name comes from, in priority order. NO_COLOR wins everything.
fn resolve_name() -> (String, String) {
    if std::env::var_os("NO_COLOR").is_some_and(|v| !v.is_empty()) {
        return ("terminal".into(), "NO_COLOR".into());
    }
    if let Ok(s) = STATE.lock() {
        if let Some(n) = &s.r#override {
            return (n.clone(), "override".into());
        }
    }
    for var in ["PASTURE_THEME", "STITCHPAD_THEME"] {
        if let Ok(v) = std::env::var(var) {
            if !v.trim().is_empty() {
                return (v.trim().to_lowercase(), "env".into());
            }
        }
    }
    if let Some(name) = herdr_theme_name() {
        return (name, "herdr".into());
    }
    ("terminal".into(), "default".into())
}

/// Minimal TOML scrape of herdr's `[theme]` table: name / auto_switch /
/// dark_name / light_name. A full TOML crate for four keys is over-tooling.
fn herdr_theme_name() -> Option<String> {
    let text = std::fs::read_to_string(herdr_config_path()?).ok()?;
    let (mut name, mut auto, mut dark, mut light) = (None, false, None, None);
    let mut in_theme = false;
    for line in text.lines() {
        let l = line.trim();
        if l.starts_with('[') {
            in_theme = l == "[theme]";
            continue;
        }
        if !in_theme || l.starts_with('#') {
            continue;
        }
        if let Some((k, v)) = l.split_once('=') {
            let (k, v) = (k.trim(), v.trim().trim_matches('"'));
            match k {
                "name" => name = Some(v.to_string()),
                "auto_switch" => auto = v == "true",
                "dark_name" => dark = Some(v.to_string()),
                "light_name" => light = Some(v.to_string()),
                _ => {}
            }
        }
    }
    if auto {
        // herdr auto-switch: follow macOS appearance, matching its pane theme.
        let dark_mode = std::process::Command::new("defaults")
            .args(["read", "-g", "AppleInterfaceStyle"])
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);
        let fallback = name.clone();
        return if dark_mode {
            dark.or(fallback).or(Some("catppuccin".into()))
        } else {
            light.or(fallback).or(Some("catppuccin-latte".into()))
        };
    }
    name
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_herdr_builtin_has_a_palette() {
        for n in [
            "catppuccin", "catppuccin-latte", "tokyo-night", "tokyo-night-day",
            "dracula", "nord", "gruvbox", "gruvbox-light", "one-dark", "one-light",
            "solarized", "solarized-light", "kanagawa", "kanagawa-lotus",
            "rose-pine", "rose-pine-dawn", "vesper",
        ] {
            assert_ne!(palette(n), TERMINAL, "{} must not fall through to terminal", n);
        }
        assert_eq!(palette("terminal"), TERMINAL);
        assert_eq!(palette("not-a-theme"), TERMINAL);
    }

    #[test]
    fn light_themes_marked_light() {
        for n in [
            "catppuccin-latte", "tokyo-night-day", "gruvbox-light", "one-light",
            "solarized-light", "kanagawa-lotus", "rose-pine-dawn",
        ] {
            assert!(palette(n).is_light, "{} should be light", n);
        }
        assert!(!palette("catppuccin").is_light);
    }

    #[test]
    fn override_roundtrip() {
        assert!(set_override("nord").is_ok());
        let no_color = std::env::var_os("NO_COLOR").is_some_and(|v| !v.is_empty());
        assert_eq!(t(), if no_color { TERMINAL } else { palette("nord") });
        assert!(set_override("definitely-fake").is_err());
        let _ = set_override("auto");
    }
}
