//! The shed — the pad's shared file store (`<pad>/dropbox/`), as a TUI tab.
//! Agents `stitchpad drop` docs in; every surface reads the same directory.
//! Enter opens the selected file with the OS handler (`open` on macOS) —
//! viewing stays the platform's job, the shed is the shelf.

use crate::theme;
use ratatui::{
    buffer::Buffer,
    layout::Rect,
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Paragraph, Widget},
};
use std::time::SystemTime;

pub struct ShedFile {
    pub name: String,
    pub size: u64,
    pub modified: Option<SystemTime>,
}

pub struct Shed {
    pub files: Vec<ShedFile>,
    pub selected: usize,
}

impl Shed {
    pub fn from_dropbox() -> Self {
        let mut s = Self {
            files: Vec::new(),
            selected: 0,
        };
        s.refresh();
        s
    }

    pub fn dropbox_dir() -> std::path::PathBuf {
        crate::pad_dir().join("dropbox")
    }

    pub fn refresh(&mut self) {
        self.files.clear();
        if let Ok(entries) = std::fs::read_dir(Self::dropbox_dir()) {
            for e in entries.flatten() {
                let Ok(meta) = e.metadata() else { continue };
                if !meta.is_file() {
                    continue;
                }
                let name = e.file_name().to_string_lossy().into_owned();
                if name.starts_with('.') {
                    continue;
                }
                self.files.push(ShedFile {
                    name,
                    size: meta.len(),
                    modified: meta.modified().ok(),
                });
            }
        }
        // newest first — the shelf reads like the conversation does
        self.files.sort_by(|a, b| b.modified.cmp(&a.modified));
        if self.selected >= self.files.len() {
            self.selected = self.files.len().saturating_sub(1);
        }
    }

    pub fn next(&mut self) {
        if !self.files.is_empty() {
            self.selected = (self.selected + 1).min(self.files.len() - 1);
        }
    }
    pub fn previous(&mut self) {
        self.selected = self.selected.saturating_sub(1);
    }

    /// Open the selected file with the OS handler. Returns a flash message.
    pub fn open_selected(&self) -> String {
        let Some(f) = self.files.get(self.selected) else {
            return "nothing in the shed".into();
        };
        let path = Self::dropbox_dir().join(&f.name);
        #[cfg(target_os = "macos")]
        let cmd = "open";
        #[cfg(not(target_os = "macos"))]
        let cmd = "xdg-open";
        match std::process::Command::new(cmd).arg(&path).spawn() {
            Ok(_) => format!("opened {}", f.name),
            Err(e) => format!("open failed: {}", e),
        }
    }
}

fn human(size: u64) -> String {
    if size >= 1_048_576 {
        format!("{:.1}MB", size as f64 / 1_048_576.0)
    } else if size >= 1024 {
        format!("{}KB", size / 1024)
    } else {
        format!("{}B", size)
    }
}

fn age(t: Option<SystemTime>) -> String {
    let Some(secs) = t.and_then(|m| m.elapsed().ok()).map(|d| d.as_secs()) else {
        return "—".into();
    };
    if secs < 90 {
        format!("{}s", secs)
    } else if secs < 5400 {
        format!("{}m", secs / 60)
    } else if secs < 129_600 {
        format!("{}h", secs / 3600)
    } else {
        format!("{}d", secs / 86_400)
    }
}

impl Widget for &Shed {
    fn render(self, area: Rect, buf: &mut Buffer) {
        let t = theme::t();
        if self.files.is_empty() {
            let pad = (area.width.saturating_sub(24) / 2) as usize;
            let lines = crate::logo::empty_state(
                "the shed is empty",
                "`stitchpad drop <file> [note]` puts a doc on the shelf",
                pad,
            );
            Paragraph::new(lines).render(area, buf);
            return;
        }

        // breathing room + single-column shelf: name · size · age
        let inner = Rect {
            x: area.x + 1,
            y: area.y + 1,
            width: area.width.saturating_sub(2),
            height: area.height.saturating_sub(1),
        };
        // header rule
        let head = Line::from(vec![
            Span::styled(
                "SHED",
                Style::default().fg(t.accent).add_modifier(Modifier::BOLD),
            ),
            Span::styled(format!(" {}", self.files.len()), Style::default().fg(t.muted)),
            Span::raw(" "),
            Span::styled(
                "─".repeat((inner.width as usize).saturating_sub(8)),
                Style::default().fg(t.faint),
            ),
        ]);
        buf.set_line(inner.x, inner.y, &head, inner.width);

        let visible = inner.height.saturating_sub(2) as usize;
        let offset = self.selected.saturating_sub(visible.saturating_sub(1));
        let mut y = inner.y + 2;
        for (i, f) in self.files.iter().enumerate().skip(offset) {
            if y >= inner.y + inner.height {
                break;
            }
            let selected = i == self.selected;
            if selected {
                let row = Rect {
                    x: inner.x,
                    y,
                    width: inner.width,
                    height: 1,
                };
                buf.set_style(row, Style::default().bg(t.surface));
            }
            let meta = format!("{:>7}  {:>4}", human(f.size), age(f.modified));
            let name_w = (inner.width as usize).saturating_sub(meta.len() + 4);
            let mut name = f.name.clone();
            if name.chars().count() > name_w {
                name = name.chars().take(name_w.saturating_sub(1)).collect::<String>() + "…";
            }
            let pad_w = (inner.width as usize)
                .saturating_sub(2 + name.chars().count() + meta.len());
            let line = Line::from(vec![
                Span::styled(
                    if selected { "▌ " } else { "▏ " },
                    Style::default().fg(t.accent),
                ),
                Span::styled(
                    name,
                    if selected {
                        Style::default().fg(t.fg).add_modifier(Modifier::BOLD)
                    } else {
                        Style::default().fg(t.fg)
                    },
                ),
                Span::raw(" ".repeat(pad_w)),
                Span::styled(meta, Style::default().fg(t.muted)),
            ]);
            buf.set_line(inner.x, y, &line, inner.width);
            y += 1;
        }
    }
}
