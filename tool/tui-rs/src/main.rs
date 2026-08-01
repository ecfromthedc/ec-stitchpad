mod color;
mod logo;
mod theme;
mod widgets;

use crossterm::{
    event::{
        self, DisableBracketedPaste, DisableMouseCapture, EnableBracketedPaste,
        EnableMouseCapture, Event, KeyCode, KeyEventKind, KeyModifiers, MouseButton,
        MouseEventKind,
    },
    execute,
    terminal::{EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode},
};
use notify::{RecursiveMode, Watcher};
use ratatui::layout::Rect;
use ratatui::{
    Terminal,
    backend::CrosstermBackend,
    layout::{Constraint, Direction, Layout},
};
use std::io;
use std::io::Write as _;
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::Duration;

use widgets::roster::{RosterMember, RosterRail};

// ── Pad discovery (mirrors lib.sh sp_find_pad): nearest .pasture (migrated,
// wins) or .stitchpad (legacy) up the tree; pasture.md else stitchpad.md. ──
pub fn pad_dir() -> PathBuf {
    let mut d = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    loop {
        let p = d.join(".pasture");
        if p.is_dir() {
            return p;
        }
        let s = d.join(".stitchpad");
        if s.is_dir() {
            return s;
        }
        if !d.pop() {
            return PathBuf::from(".stitchpad");
        }
    }
}
pub fn pad_file() -> PathBuf {
    let d = pad_dir();
    let p = d.join("pasture.md");
    if p.is_file() { p } else { d.join("stitchpad.md") }
}
pub fn pad_state() -> String {
    pad_dir().join(".state").to_string_lossy().into_owned()
}

/// Chat-first pasture TUI.
///
/// The prompt is ALWAYS live on the pasture tab — type and hit Enter, no
/// compose mode. That means plain letters belong to the input, so app actions
/// live on modifiers (^C quit, ^T tasks, ^R refresh, ^Y copy) — the
/// irssi/weechat convention — plus /slash commands (`/help` lists them).
/// The barn (tasks) has no input, so it keeps plain vim keys.
struct App {
    tab: u8, // 0=pasture 1=barn 2=shed
    input: String,
    /// Cursor position in the input, as a CHAR index (0..=input char len).
    cursor: usize,
    detail_open: bool,
    help_open: bool,
    /// A finished /summarize renders here as a scrollable modal until Esc.
    summary: Option<String>,
    summary_scroll: u16,
    /// Label of the in-flight background job (spinner in the footer). One at a time.
    busy: Option<String>,
    started: std::time::Instant,
    watcher_alive: bool,
    flash: Option<(String, std::time::Instant)>,
    /// Inner rect of the messages panel from the last draw — mouse events route
    /// by hit-testing against this (drag-select, wheel scroll).
    msg_inner: Rect,
    /// Header tab labels' clickable column ranges from the last draw.
    tab_hits: [(u16, u16); 3],
    /// Live mouse drag anchor (inner-relative row), while the left button is down.
    drag_anchor: Option<u16>,
}

const TAB_LABELS: [&str; 3] = ["pasture", "barn", "shed"];

/// Slash commands the prompt understands. (name, args, blurb) — Tab completes
/// them, /help prints them.
const SLASH: [(&str, &str, &str); 6] = [
    ("/summarize", "[n]", "chew the last n messages into a summary"),
    ("/compact", "[keep]", "shear the pad — archive old wool to sqlite"),
    ("/theme", "[name|auto]", "pin a theme, or follow herdr"),
    ("/help", "", "the field guide"),
    ("/ruminate", "[n]", "alias of /summarize"),
    ("/shear", "[keep]", "alias of /compact"),
];

/// Background job results (compact/summarize run off-thread — the draw loop
/// never waits on a fork, let alone a haiku call).
enum Job {
    Compact(Result<String, String>),
    Summary(Result<String, String>),
}

impl App {
    fn flash(&mut self, msg: impl Into<String>) {
        self.flash = Some((msg.into(), std::time::Instant::now()));
    }
    fn flash_line(&self) -> Option<&str> {
        match &self.flash {
            Some((m, t)) if t.elapsed() < Duration::from_secs(4) => Some(m.as_str()),
            _ => None,
        }
    }
    fn spinner(&self) -> char {
        const FRAMES: [char; 10] = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
        FRAMES[(self.started.elapsed().as_millis() / 120) as usize % FRAMES.len()]
    }

    // ── Cursor-aware input editing (char-indexed; input may hold any UTF-8) ──
    fn byte_at(&self, ci: usize) -> usize {
        self.input
            .char_indices()
            .nth(ci)
            .map(|(b, _)| b)
            .unwrap_or(self.input.len())
    }
    fn char_len(&self) -> usize {
        self.input.chars().count()
    }
    fn insert_str(&mut self, s: &str) {
        let b = self.byte_at(self.cursor);
        self.input.insert_str(b, s);
        self.cursor += s.chars().count();
    }
    fn backspace(&mut self) {
        if self.cursor == 0 {
            return;
        }
        let b = self.byte_at(self.cursor - 1);
        self.input.remove(b);
        self.cursor -= 1;
    }
    fn delete_at(&mut self) {
        if self.cursor >= self.char_len() {
            return;
        }
        let b = self.byte_at(self.cursor);
        self.input.remove(b);
    }
    fn delete_word_before(&mut self) {
        let b = self.byte_at(self.cursor);
        let head = self.input[..b].trim_end().to_string();
        let cut = head.rfind(' ').map(|i| i + 1).unwrap_or(0);
        let tail = self.input[b..].to_string();
        self.input = format!("{}{}", &head[..cut], tail);
        self.cursor = head[..cut].chars().count();
    }
    fn clear_input(&mut self) {
        self.input.clear();
        self.cursor = 0;
    }

    /// Run a /command typed into the prompt. Long work goes to a thread; the
    /// result lands back through `jobs`.
    fn handle_slash(&mut self, raw: &str, jobs: &mpsc::Sender<Job>) {
        let body = raw.trim().trim_start_matches('/');
        let mut parts = body.split_whitespace();
        let cmd = parts.next().unwrap_or("");
        let arg = parts.next().map(|s| s.to_string());
        match cmd {
            "help" => self.help_open = true,
            "theme" => match arg {
                Some(name) => match theme::set_override(&name) {
                    Ok(l) => self.flash(format!("theme → {}", l)),
                    Err(e) => self.flash(e),
                },
                None => self.flash(format!(
                    "theme: {} — /theme <name> pins, /theme auto follows herdr",
                    theme::load()
                )),
            },
            "compact" | "shear" => {
                if self.busy.is_some() {
                    self.flash("already working — one job at a time");
                    return;
                }
                let mut args = vec!["compact".to_string()];
                if let Some(n) = arg.as_deref().and_then(|a| a.parse::<u32>().ok()) {
                    args.push("--keep".into());
                    args.push(n.to_string());
                }
                self.busy = Some("shearing the pad".into());
                spawn_job(jobs.clone(), args, Job::Compact);
            }
            "summarize" | "ruminate" => {
                if self.busy.is_some() {
                    self.flash("already working — one job at a time");
                    return;
                }
                let n = arg
                    .as_deref()
                    .and_then(|a| a.parse::<u32>().ok())
                    .unwrap_or(200);
                let args = vec!["summarize".to_string(), "-n".into(), n.to_string()];
                self.busy = Some("ruminating".into());
                spawn_job(jobs.clone(), args, Job::Summary);
            }
            other => self.flash(format!("unknown command /{} — /help lists them", other)),
        }
    }
}

/// Run `stitchpad <args>` on a worker thread, wrap the outcome with `wrap`,
/// send it home. stdout on success; stderr (or stdout) trimmed on failure.
fn spawn_job(
    tx: mpsc::Sender<Job>,
    args: Vec<String>,
    wrap: fn(Result<String, String>) -> Job,
) {
    std::thread::spawn(move || {
        let out = std::process::Command::new("stitchpad").args(&args).output();
        let res = match out {
            Ok(o) if o.status.success() => {
                Ok(String::from_utf8_lossy(&o.stdout).trim().to_string())
            }
            Ok(o) => {
                let err = if o.stderr.is_empty() { &o.stdout } else { &o.stderr };
                Err(String::from_utf8_lossy(err).trim().to_string())
            }
            Err(e) => Err(e.to_string()),
        };
        let _ = tx.send(wrap(res));
    });
}

fn main() -> io::Result<()> {
    let _ = theme::load(); // resolve herdr theme before the first frame
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(
        stdout,
        EnterAlternateScreen,
        EnableMouseCapture,
        EnableBracketedPaste
    )?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;
    // Restore the terminal even on panic — a raw-mode corpse is the worst UX.
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let _ = disable_raw_mode();
        let _ = execute!(
            io::stdout(),
            DisableBracketedPaste,
            DisableMouseCapture,
            LeaveAlternateScreen
        );
        default_hook(info);
    }));

    let mut roster = RosterRail::from_doctor();
    let mut messages = widgets::messages::MessageList::from_pad();
    let mut board = widgets::tasks::TaskBoard::from_pad();
    let mut shed = widgets::shed::Shed::from_dropbox();
    let mut app = App {
        tab: 0,
        input: String::new(),
        cursor: 0,
        detail_open: false,
        help_open: false,
        summary: None,
        summary_scroll: 0,
        busy: None,
        started: std::time::Instant::now(),
        watcher_alive: RosterRail::watcher_alive(),
        flash: None,
        msg_inner: Rect::default(),
        tab_hits: [(0, 0); 3],
        drag_anchor: None,
    };

    // Live-tail: watch the pad dir and re-read pad-derived views on change.
    let (watch_tx, watch_rx) = mpsc::channel::<()>();
    let _watcher = {
        let tx = watch_tx.clone();
        notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
            if res.is_ok() {
                let _ = tx.send(());
            }
        })
        .and_then(|mut w| {
            // watch the dir (editors/append may replace the inode); filter is cheap.
            w.watch(&pad_dir(), RecursiveMode::NonRecursive)?;
            Ok(w)
        })
        .ok()
    };

    // Background roster ticker: doctor + liveness probes are forks — far too slow
    // for the draw loop, and alive.* lives in .state/ where the non-recursive
    // watcher can't see it. A thread re-fetches every 5s and ships results over a
    // channel; the UI just drains. This is what makes the duplicate-member /
    // stale-triangle staleness impossible: the rail ALWAYS converges on doctor.
    // It also mtime-watches the herdr config so a herdr theme change re-skins
    // the pasture within one tick.
    let (roster_tx, roster_rx) = mpsc::channel::<(Vec<RosterMember>, bool)>();
    std::thread::spawn(move || {
        loop {
            let members = RosterRail::fetch();
            let alive = RosterRail::watcher_alive();
            theme::reload_if_stale();
            if roster_tx.send((members, alive)).is_err() {
                break; // UI gone
            }
            std::thread::sleep(Duration::from_secs(5));
        }
    });

    // Background job results (compact / summarize).
    let (jobs_tx, jobs_rx) = mpsc::channel::<Job>();

    let pad_name = std::env::current_dir()
        .ok()
        .and_then(|d| d.file_name().map(|f| f.to_string_lossy().into_owned()))
        .unwrap_or_else(|| "pasture".into());

    loop {
        // Drain pad-change events (collapse bursts into one refresh) — every
        // pad-derived view re-reads, not just messages (the old staleness bug).
        let mut changed = false;
        while watch_rx.try_recv().is_ok() {
            changed = true;
        }
        if changed {
            messages.refresh();
            board.refresh();
            shed.refresh();
        }
        // Drain background roster updates.
        while let Ok((members, alive)) = roster_rx.try_recv() {
            roster.set_members(members);
            app.watcher_alive = alive;
        }
        // Drain finished jobs.
        while let Ok(job) = jobs_rx.try_recv() {
            app.busy = None;
            match job {
                Job::Compact(Ok(msg)) => {
                    let line = msg.lines().last().unwrap_or("sheared").to_string();
                    app.flash(line);
                    messages.refresh();
                    board.refresh();
                }
                Job::Compact(Err(e)) => app.flash(format!("shear failed: {}", e)),
                Job::Summary(Ok(s)) if !s.is_empty() => {
                    app.summary = Some(s);
                    app.summary_scroll = 0;
                }
                Job::Summary(Ok(_)) => app.flash("summary came back empty"),
                Job::Summary(Err(e)) => app.flash(format!("summarize failed: {}", e)),
            }
        }

        terminal.draw(|f| {
            use ratatui::style::{Modifier, Style};
            use ratatui::text::{Line, Span};
            use ratatui::widgets::{Block, Borders, Clear, Paragraph, Wrap};
            let t = theme::t();

            // Paint the theme background under everything.
            f.render_widget(
                Block::default().style(Style::default().bg(t.bg).fg(t.fg)),
                f.area(),
            );

            // Pressure floor: below this the layout lies — say so instead.
            if f.area().width < 42 || f.area().height < 10 {
                let msg = Paragraph::new("pen too small — 42×10 minimum")
                    .style(Style::default().fg(t.muted));
                f.render_widget(msg, f.area());
                return;
            }

            let show_input = app.tab == 0;
            // Input box grows with content (wrapped), 1..=4 text rows + border.
            let input_h = if show_input {
                let inner_w = (f.area().width.saturating_sub(2)).max(8) as usize;
                let rows = (app.char_len() + 1).div_ceil(inner_w).clamp(1, 4) as u16;
                rows + 2
            } else {
                0
            };
            let mut constraints = vec![Constraint::Length(1), Constraint::Min(3)];
            if show_input {
                constraints.push(Constraint::Length(input_h));
            }
            constraints.push(Constraint::Length(1));
            let rows = Layout::default()
                .direction(Direction::Vertical)
                .constraints(constraints)
                .split(f.area());
            let (header_row, main_row) = (rows[0], rows[1]);
            let input_row = if show_input { Some(rows[2]) } else { None };
            let footer_row = rows[rows.len() - 1];

            // ── Header: lamb mark · pad name · tabs · shepherd + grazing count ──
            let dim = Style::default().fg(t.muted);
            let mut header = vec![Span::raw(" ")];
            header.extend(logo::mark());
            header.push(Span::raw(" "));
            header.push(Span::styled(
                pad_name.clone(),
                Style::default().fg(t.fg).add_modifier(Modifier::BOLD),
            ));
            header.push(Span::raw("   "));
            // running display column for click hit-testing (all width-1 glyphs)
            let mut col: u16 = header
                .iter()
                .map(|s| s.content.chars().count() as u16)
                .sum();
            for (i, label) in TAB_LABELS.iter().enumerate() {
                let w = label.chars().count() as u16 + 2; // " label "
                app.tab_hits[i] = (col, col + w - 1);
                col += w + 1; // + separator space
                if i as u8 == app.tab {
                    header.push(Span::styled(
                        format!(" {} ", label),
                        Style::default()
                            .fg(t.bg)
                            .bg(t.accent)
                            .add_modifier(Modifier::BOLD),
                    ));
                } else {
                    header.push(Span::styled(format!(" {} ", label), dim));
                }
                header.push(Span::raw(" "));
            }
            let online = roster
                .members
                .iter()
                .filter(|m| matches!(m.live_status, widgets::roster::LiveStatus::Online))
                .count();
            let dot = if app.watcher_alive { "●" } else { "○" };
            let right_full = if app.watcher_alive {
                format!(
                    "{} shepherd · {}/{} grazing ",
                    dot,
                    online,
                    roster.members.len()
                )
            } else {
                format!(
                    "{} shepherd asleep (^S) · {}/{} ",
                    dot,
                    online,
                    roster.members.len()
                )
            };
            let right_compact = format!("{} {}/{} ", dot, online, roster.members.len());
            let left_w = header
                .iter()
                .map(|s| s.content.chars().count())
                .sum::<usize>();
            let avail = (header_row.width as usize).saturating_sub(left_w);
            // Fit the full status if we can, the compact one if we must.
            let right = if right_full.chars().count() <= avail {
                right_full
            } else if right_compact.chars().count() <= avail {
                right_compact
            } else {
                String::new()
            };
            let pad_w = avail.saturating_sub(right.chars().count());
            header.push(Span::raw(" ".repeat(pad_w)));
            header.push(Span::styled(
                right,
                Style::default().fg(if app.watcher_alive { t.ok } else { t.err }),
            ));
            f.render_widget(Paragraph::new(Line::from(header)), header_row);

            // ── Main area ────────────────────────────────────────────────
            if app.tab == 2 {
                f.render_widget(&shed, main_row);
            } else if app.tab == 1 {
                f.render_widget(&board, main_row);
                if app.detail_open {
                    if let Some(task) = board.selected_task() {
                        widgets::tasks::render_detail(task, f.area(), f.buffer_mut());
                    }
                }
            } else {
                // Floor plan: below 90 cols the flock rail folds away and the
                // conversation takes the full width (still fine at 80×24).
                let msg_rect = if main_row.width >= 90 {
                    let cols = Layout::default()
                        .direction(Direction::Horizontal)
                        .constraints([Constraint::Min(40), Constraint::Length(26)])
                        .split(main_row);
                    f.render_widget(&messages, cols[0]);
                    f.render_widget(&roster, cols[1]);
                    cols[0]
                } else {
                    f.render_widget(&messages, main_row);
                    main_row
                };
                // inner rect (inside the border) for mouse hit-testing
                app.msg_inner = Rect {
                    x: msg_rect.x + 1,
                    y: msg_rect.y + 1,
                    width: msg_rect.width.saturating_sub(2),
                    height: msg_rect.height.saturating_sub(2),
                };

                // ── Prompt: ALWAYS live. Type → Enter sends. ────────────
                if let Some(area) = input_row {
                    let me = std::env::var("STITCHPAD_NAME").unwrap_or_else(|_| "smaths".into());
                    let is_cmd = app.input.starts_with('/');
                    let border = if app.input.is_empty() {
                        Style::default().fg(t.faint)
                    } else if is_cmd {
                        Style::default().fg(t.special)
                    } else {
                        Style::default().fg(t.accent)
                    };
                    let title = if is_cmd {
                        Line::from(Span::styled(
                            " command ",
                            Style::default().fg(t.special),
                        ))
                    } else {
                        Line::from(Span::styled(
                            format!(" @{} ", me),
                            Style::default().fg(t.muted),
                        ))
                    };
                    let content: Line = if app.input.is_empty() {
                        Line::from(Span::styled(
                            "bleat something · @name wakes them · /help",
                            Style::default().fg(t.faint),
                        ))
                    } else {
                        // cursor-split render: text before · cursor cell · text after
                        let b = app.byte_at(app.cursor);
                        let before = app.input[..b].to_string();
                        let mut rest = app.input[b..].chars();
                        let under = rest.next();
                        let after: String = rest.collect();
                        let mut spans = vec![Span::raw(before)];
                        match under {
                            Some(c) => spans.push(Span::styled(
                                c.to_string(),
                                Style::default().add_modifier(Modifier::REVERSED),
                            )),
                            None => spans.push(Span::styled(
                                "█",
                                Style::default().fg(t.accent),
                            )),
                        }
                        spans.push(Span::raw(after));
                        Line::from(spans)
                    };
                    f.render_widget(
                        Paragraph::new(content)
                            .wrap(Wrap { trim: false })
                            .block(
                                Block::default()
                                    .borders(Borders::ALL)
                                    .border_type(ratatui::widgets::BorderType::Rounded)
                                    .border_style(border)
                                    .title(title),
                            ),
                        area,
                    );
                }
            }

            // ── Summary modal: the rumination, scrollable, ^Y copies ─────
            if let Some(sum) = &app.summary {
                let rect = widgets::tasks::overlay_rect(f.area(), 72, 70);
                f.render_widget(Clear, rect);
                let block = Block::default()
                    .title(Line::from(vec![
                        Span::styled(
                            " rumination ",
                            Style::default().fg(t.accent).add_modifier(Modifier::BOLD),
                        ),
                        Span::styled("· thread summary ", Style::default().fg(t.muted)),
                    ]))
                    .title_bottom(Line::from(Span::styled(
                        " j/k scroll · ^Y copy · Esc close ",
                        Style::default().fg(t.faint),
                    )))
                    .borders(Borders::ALL)
                    .border_type(ratatui::widgets::BorderType::Rounded)
                    .border_style(Style::default().fg(t.accent))
                    .style(Style::default().bg(t.surface));
                let inner = block.inner(rect);
                f.render_widget(block, rect);
                let para = Paragraph::new(sum.clone())
                    .style(Style::default().fg(t.fg))
                    .wrap(Wrap { trim: false })
                    .scroll((app.summary_scroll, 0));
                f.render_widget(para, inner);
            }

            // ── Help modal: the field guide ──────────────────────────────
            if app.help_open {
                let rect = widgets::tasks::overlay_rect(f.area(), 76, 84);
                f.render_widget(Clear, rect);
                let block = Block::default()
                    .title(Line::from(Span::styled(
                        " field guide ",
                        Style::default().fg(t.accent).add_modifier(Modifier::BOLD),
                    )))
                    .title_bottom(Line::from(Span::styled(
                        " Esc close ",
                        Style::default().fg(t.faint),
                    )))
                    .borders(Borders::ALL)
                    .border_type(ratatui::widgets::BorderType::Rounded)
                    .border_style(Style::default().fg(t.accent))
                    .style(Style::default().bg(t.surface));
                let inner = block.inner(rect);
                f.render_widget(block, rect);
                let head = Style::default().fg(t.accent).add_modifier(Modifier::BOLD);
                let key = Style::default().fg(t.fg);
                let blurb = Style::default().fg(t.muted);
                let mut lines: Vec<Line> = Vec::new();
                let pad = (inner.width.saturating_sub(22) / 2) as usize;
                lines.extend(logo::sheep(pad));
                lines.push(Line::from(""));
                lines.push(Line::from(Span::styled("herding", head)));
                lines.push(Line::from(vec![
                    Span::styled("Enter", key),
                    Span::styled(" send · ", blurb),
                    Span::styled("@name", key),
                    Span::styled(" wakes them · ", blurb),
                    Span::styled("Tab", key),
                    Span::styled(" completes names & /commands", blurb),
                ]));
                lines.push(Line::from(vec![
                    Span::styled("^T", key),
                    Span::styled(" barn · ", blurb),
                    Span::styled("^R", key),
                    Span::styled(" refresh · ", blurb),
                    Span::styled("^Y", key),
                    Span::styled(" copy convo · ", blurb),
                    Span::styled("^S", key),
                    Span::styled(" wake shepherd · ", blurb),
                    Span::styled("^C", key),
                    Span::styled(" leave", blurb),
                ]));
                lines.push(Line::from(""));
                lines.push(Line::from(Span::styled("the barn", head)));
                lines.push(Line::from(vec![
                    Span::styled("h/l", key),
                    Span::styled(" columns · ", blurb),
                    Span::styled("j/k", key),
                    Span::styled(" cards · ", blurb),
                    Span::styled("Enter", key),
                    Span::styled(" detail · ", blurb),
                    Span::styled("]/[", key),
                    Span::styled(" move · ", blurb),
                    Span::styled("p", key),
                    Span::styled(" priority · ", blurb),
                    Span::styled("d", key),
                    Span::styled(" done · ", blurb),
                    Span::styled("x", key),
                    Span::styled(" cancel", blurb),
                ]));
                lines.push(Line::from(""));
                lines.push(Line::from(Span::styled("commands", head)));
                for (name, args, desc) in SLASH.iter().take(4) {
                    lines.push(Line::from(vec![
                        Span::styled(format!("{:<11}", name), key),
                        Span::styled(format!("{:<12}", args), Style::default().fg(t.faint)),
                        Span::styled((*desc).to_string(), blurb),
                    ]));
                }
                lines.push(Line::from(""));
                lines.push(Line::from(vec![Span::styled(
                    "flock = agents · grazing = online · shepherd = watcher · shearing = compaction",
                    Style::default().fg(t.faint).add_modifier(Modifier::ITALIC),
                )]));
                f.render_widget(Paragraph::new(lines).wrap(Wrap { trim: false }), inner);
            }

            // ── Footer: busy spinner > flash > per-tab hints ─────────────
            let footer: Line = if let Some(job) = &app.busy {
                Line::from(vec![
                    Span::styled(
                        format!(" {} {}… ", app.spinner(), job),
                        Style::default().fg(t.warn),
                    ),
                    Span::styled("(the flock waits)", Style::default().fg(t.faint)),
                ])
            } else if let Some(fmsg) = app.flash_line() {
                Line::from(Span::styled(fmsg.to_string(), Style::default().fg(t.fg)))
            } else if app.tab == 2 {
                Line::from(Span::styled(
                    "j/k:nav  Enter:open  r:refresh  ?:help  ^T:next tab  q:quit",
                    dim,
                ))
            } else if app.tab == 1 {
                Line::from(Span::styled(
                    "h/l/j/k:nav  Enter:detail  ]/[:move  p:priority  d:done  x:cancel  ?:help  ^T:shed  q:quit",
                    dim,
                ))
            } else {
                Line::from(Span::styled(
                    "Enter:send  Tab:complete  /help  /summarize  /compact  ^Y:copy  ^T:tasks  ^C:quit",
                    dim,
                ))
            };
            f.render_widget(Paragraph::new(footer), footer_row);
        })?;

        // ── Input ────────────────────────────────────────────────────────
        if event::poll(Duration::from_millis(100))? {
            match event::read()? {
                Event::Mouse(me) => {
                    let inside_msgs = app.tab == 0
                        && me.column >= app.msg_inner.x
                        && me.column < app.msg_inner.x + app.msg_inner.width
                        && me.row >= app.msg_inner.y
                        && me.row < app.msg_inner.y + app.msg_inner.height;
                    match me.kind {
                        MouseEventKind::ScrollUp => {
                            if app.summary.is_some() {
                                app.summary_scroll = app.summary_scroll.saturating_sub(1);
                            } else if app.tab == 0 {
                                messages.scroll_up();
                            } else if app.tab == 2 {
                                shed.previous();
                            } else {
                                board.previous();
                            }
                        }
                        MouseEventKind::ScrollDown => {
                            if app.summary.is_some() {
                                app.summary_scroll = app.summary_scroll.saturating_add(1);
                            } else if app.tab == 0 {
                                messages.scroll_down();
                            } else if app.tab == 2 {
                                shed.next();
                            } else {
                                board.next();
                            }
                        }
                        MouseEventKind::Down(MouseButton::Left) => {
                            if me.row == 0 {
                                // header tab click
                                for (i, (x0, x1)) in app.tab_hits.iter().enumerate() {
                                    if me.column >= *x0 && me.column <= *x1 {
                                        app.tab = i as u8;
                                        app.detail_open = false;
                                    }
                                }
                            } else if inside_msgs {
                                // start a drag-selection at this visible row
                                let row = me.row - app.msg_inner.y;
                                app.drag_anchor = Some(row);
                                messages.selection = Some((row, row));
                            } else {
                                app.drag_anchor = None;
                                messages.selection = None;
                            }
                        }
                        MouseEventKind::Drag(MouseButton::Left) => {
                            if let Some(anchor) = app.drag_anchor {
                                if app.tab == 0 && app.msg_inner.height > 0 {
                                    let row = me
                                        .row
                                        .clamp(
                                            app.msg_inner.y,
                                            app.msg_inner.y + app.msg_inner.height - 1,
                                        )
                                        - app.msg_inner.y;
                                    messages.selection = Some((anchor, row));
                                }
                            }
                        }
                        MouseEventKind::Up(MouseButton::Left) => {
                            if let (Some(_), Some((a, b))) =
                                (app.drag_anchor.take(), messages.selection)
                            {
                                // a plain click (no movement) just clears; a real drag copies
                                if a != b {
                                    let text = messages.selected_text(
                                        app.msg_inner.width,
                                        app.msg_inner.height,
                                        a,
                                        b,
                                    );
                                    match copy_text(&text) {
                                        Ok(()) => app.flash(format!(
                                            "copied {} lines to clipboard",
                                            a.abs_diff(b) + 1
                                        )),
                                        Err(e) => app.flash(format!("copy failed: {}", e)),
                                    }
                                }
                                messages.selection = None;
                            }
                        }
                        _ => {}
                    }
                }
                Event::Key(key) => {
                    if key.kind != KeyEventKind::Press {
                        continue;
                    }
                    let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);

                    // ── Modals swallow keys first ────────────────────────
                    if app.summary.is_some() {
                        match key.code {
                            KeyCode::Esc | KeyCode::Char('q') if !ctrl => {
                                app.summary = None;
                            }
                            KeyCode::Char('j') | KeyCode::Down => {
                                app.summary_scroll = app.summary_scroll.saturating_add(1)
                            }
                            KeyCode::Char('k') | KeyCode::Up => {
                                app.summary_scroll = app.summary_scroll.saturating_sub(1)
                            }
                            KeyCode::PageDown => {
                                app.summary_scroll = app.summary_scroll.saturating_add(10)
                            }
                            KeyCode::PageUp => {
                                app.summary_scroll = app.summary_scroll.saturating_sub(10)
                            }
                            KeyCode::Char('y') if ctrl => {
                                let text = app.summary.clone().unwrap_or_default();
                                match copy_text(&text) {
                                    Ok(()) => app.flash("summary copied"),
                                    Err(e) => app.flash(format!("copy failed: {}", e)),
                                }
                            }
                            KeyCode::Char('c') if ctrl => break,
                            _ => {}
                        }
                        continue;
                    }
                    if app.help_open {
                        match key.code {
                            KeyCode::Esc | KeyCode::Char('q') | KeyCode::Char('?') if !ctrl => {
                                app.help_open = false
                            }
                            KeyCode::Char('c') if ctrl => break,
                            _ => {}
                        }
                        continue;
                    }

                    // Global (both tabs): modifier chords.
                    if ctrl {
                        match key.code {
                            KeyCode::Char('c') => break,
                            KeyCode::Char('t') => {
                                app.tab = (app.tab + 1) % 3;
                                app.detail_open = false;
                                if app.tab == 2 {
                                    shed.refresh();
                                }
                                continue;
                            }
                            KeyCode::Char('r') => {
                                color::invalidate();
                                let label = theme::load();
                                roster.refresh();
                                messages.refresh();
                                board.refresh();
                                shed.refresh();
                                app.watcher_alive = RosterRail::watcher_alive();
                                app.flash(format!("refreshed · theme {}", label));
                                continue;
                            }
                            KeyCode::Char('y') => {
                                match copy_conversation(&messages) {
                                    Ok(n) => {
                                        app.flash(format!("copied {} messages to clipboard", n))
                                    }
                                    Err(e) => app.flash(format!("copy failed: {}", e)),
                                }
                                continue;
                            }
                            KeyCode::Char('s') => {
                                let _ = std::process::Command::new("stitchpad")
                                    .arg("restart")
                                    .output();
                                app.watcher_alive = RosterRail::watcher_alive();
                                app.flash("the shepherd is awake");
                                continue;
                            }
                            KeyCode::Char('u') => {
                                app.clear_input();
                                continue;
                            }
                            KeyCode::Char('w') => {
                                app.delete_word_before(); // readline convention
                                continue;
                            }
                            KeyCode::Char('a') => {
                                app.cursor = 0;
                                continue;
                            }
                            KeyCode::Char('e') => {
                                app.cursor = app.char_len();
                                continue;
                            }
                            _ => {}
                        }
                    }

                    if app.tab == 2 {
                        // Shed: file shelf → plain vim keys.
                        match key.code {
                            KeyCode::Char('q') => break,
                            KeyCode::Esc | KeyCode::Char('1') => app.tab = 0,
                            KeyCode::Char('2') => app.tab = 1,
                            KeyCode::Char('?') => app.help_open = true,
                            KeyCode::Char('j') | KeyCode::Down => shed.next(),
                            KeyCode::Char('k') | KeyCode::Up => shed.previous(),
                            KeyCode::Enter => {
                                let msg = shed.open_selected();
                                app.flash(msg);
                            }
                            KeyCode::Char('r') => shed.refresh(),
                            _ => {}
                        }
                        continue;
                    }

                    if app.tab == 1 {
                        // Barn: no text input → plain vim keys.
                        match key.code {
                            KeyCode::Char('q') => break,
                            KeyCode::Esc => {
                                if app.detail_open {
                                    app.detail_open = false;
                                } else {
                                    app.tab = 0;
                                }
                            }
                            KeyCode::Char('t') | KeyCode::Char('1') => {
                                app.tab = 0;
                                app.detail_open = false;
                            }
                            KeyCode::Char('3') => {
                                app.tab = 2;
                                app.detail_open = false;
                                shed.refresh();
                            }
                            KeyCode::Char('?') => app.help_open = true,
                            KeyCode::Char('j') | KeyCode::Down => board.next_in_column(),
                            KeyCode::Char('k') | KeyCode::Up => board.prev_in_column(),
                            KeyCode::Char('h') | KeyCode::Left => board.move_column(false),
                            KeyCode::Char('l') | KeyCode::Right => board.move_column(true),
                            KeyCode::Enter => app.detail_open = !app.detail_open,
                            KeyCode::Char(']') => board.move_selected(true),
                            KeyCode::Char('[') => board.move_selected(false),
                            KeyCode::Char('p') => board.cycle_priority(),
                            KeyCode::Char('d') => board.set_selected_status("done"),
                            KeyCode::Char('x') => board.set_selected_status("canceled"),
                            KeyCode::Char('r') => board.refresh(),
                            _ => {}
                        }
                        continue;
                    }

                    // Pasture tab: everything printable belongs to the prompt.
                    match key.code {
                        KeyCode::Enter => {
                            let text = app.input.trim().to_string();
                            if text.starts_with('/') {
                                app.clear_input();
                                app.handle_slash(&text, &jobs_tx);
                            } else if !text.is_empty() {
                                let ok = std::process::Command::new("stitchpad")
                                    .arg("say")
                                    .arg(&text)
                                    .output()
                                    .map(|o| o.status.success())
                                    .unwrap_or(false);
                                if ok {
                                    app.clear_input();
                                    messages.refresh();
                                } else {
                                    app.flash("send failed — is this a pad dir?");
                                }
                            }
                        }
                        KeyCode::Esc => app.clear_input(),
                        KeyCode::Backspace => app.backspace(),
                        KeyCode::Delete => app.delete_at(),
                        KeyCode::Left => app.cursor = app.cursor.saturating_sub(1),
                        KeyCode::Right => app.cursor = (app.cursor + 1).min(app.char_len()),
                        KeyCode::Home => app.cursor = 0,
                        KeyCode::End => app.cursor = app.char_len(),
                        KeyCode::Tab => {
                            // completion (only when the cursor sits at the end,
                            // where the token being typed lives).
                            if app.cursor == app.char_len() {
                                if let Some(done) = complete_slash(&app.input) {
                                    app.input = done;
                                    app.cursor = app.char_len();
                                } else if let Some(done) =
                                    complete_mention(&app.input, &roster.members)
                                {
                                    app.input = done;
                                    app.cursor = app.char_len();
                                }
                            }
                        }
                        KeyCode::Up | KeyCode::PageUp => {
                            let n = if key.code == KeyCode::PageUp { 10 } else { 1 };
                            for _ in 0..n {
                                messages.scroll_up();
                            }
                        }
                        KeyCode::Down | KeyCode::PageDown => {
                            let n = if key.code == KeyCode::PageDown { 10 } else { 1 };
                            for _ in 0..n {
                                messages.scroll_down();
                            }
                        }
                        KeyCode::Char(c) => app.insert_str(&c.to_string()),
                        _ => {}
                    }
                }
                Event::Paste(s) => {
                    // Bracketed paste: land the WHOLE paste in the input as one
                    // unit — without this, a newline in pasted text acts as Enter
                    // and fires partial messages mid-paste.
                    if app.tab == 0 {
                        let clean = s.replace('\r', "\n");
                        app.insert_str(&clean);
                    }
                }
                _ => {}
            }
        }
    }

    disable_raw_mode()?;
    execute!(
        terminal.backend_mut(),
        DisableBracketedPaste,
        DisableMouseCapture,
        LeaveAlternateScreen
    )?;
    terminal.show_cursor()?;
    Ok(())
}

/// Complete a leading `/command` prefix against the slash table. Only fires when
/// the whole input is one /token (commands live at line start).
fn complete_slash(input: &str) -> Option<String> {
    if !input.starts_with('/') || input.contains(' ') {
        return None;
    }
    let hit = SLASH
        .iter()
        .find(|(name, _, _)| name.starts_with(input) && *name != input)?;
    Some(format!("{} ", hit.0))
}

/// Complete the trailing `@prefix` token against roster names. Returns the new
/// input line, or None if the cursor isn't on an @-token / nothing matches.
fn complete_mention(input: &str, members: &[RosterMember]) -> Option<String> {
    let start = input.rfind('@')?;
    // the @ must start a token (line start or after whitespace)
    if start > 0 && !input[..start].ends_with(' ') {
        return None;
    }
    let prefix = &input[start + 1..];
    if prefix.contains(' ') {
        return None; // cursor is past the token
    }
    let m = members
        .iter()
        .find(|m| m.name.starts_with(prefix) && m.name != prefix)?;
    Some(format!("{}@{} ", &input[..start], m.name))
}

/// Copy the visible conversation to the system clipboard as clean markdown —
/// no gutters, borders, or roster bleed (the reason terminal drag-select is
/// useless in a multi-panel TUI). macOS pbcopy; xclip/wl-copy fallbacks.
fn copy_conversation(list: &widgets::messages::MessageList) -> Result<usize, String> {
    let mut out = String::new();
    for m in &list.messages {
        out.push_str(&format!("@{} · {}\n", m.author, m.time));
        for line in &m.body {
            out.push_str(line);
            out.push('\n');
        }
        out.push('\n');
    }
    if out.is_empty() {
        return Err("no messages".into());
    }
    copy_text(&out)?;
    Ok(list.messages.len())
}

/// Pipe text to the system clipboard (pbcopy on macOS; wl-copy/xclip fallbacks).
fn copy_text(text: &str) -> Result<(), String> {
    let candidates: &[(&str, &[&str])] = &[
        ("pbcopy", &[]),
        ("wl-copy", &[]),
        ("xclip", &["-selection", "clipboard"]),
    ];
    for (cmd, args) in candidates {
        let child = std::process::Command::new(cmd)
            .args(*args)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
        if let Ok(mut child) = child {
            if let Some(stdin) = child.stdin.as_mut() {
                if stdin.write_all(text.as_bytes()).is_ok() {
                    let _ = child.wait();
                    return Ok(());
                }
            }
            let _ = child.wait();
        }
    }
    Err("no clipboard tool (pbcopy/wl-copy/xclip)".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use widgets::roster::{Health, LiveStatus};

    fn member(name: &str) -> RosterMember {
        RosterMember {
            name: name.into(),
            adapter: "pi".into(),
            wake: "push".into(),
            harness: "pi".into(),
            model: "—".into(),
            health: Health::Healthy,
            live_status: LiveStatus::Online,
            issue: None,
        }
    }

    #[test]
    fn completes_mention_prefix() {
        let members = vec![member("codex"), member("fable")];
        assert_eq!(
            complete_mention("@co", &members).as_deref(),
            Some("@codex ")
        );
        assert_eq!(
            complete_mention("hey @fa", &members).as_deref(),
            Some("hey @fable ")
        );
        // mid-word @ (email-ish) must not complete
        assert_eq!(complete_mention("me@co", &members), None);
        // past the token → no completion
        assert_eq!(complete_mention("@codex hi", &members), None);
        // no match
        assert_eq!(complete_mention("@zz", &members), None);
    }

    #[test]
    fn completes_slash_commands() {
        assert_eq!(complete_slash("/sum").as_deref(), Some("/summarize "));
        assert_eq!(complete_slash("/com").as_deref(), Some("/compact "));
        assert_eq!(complete_slash("/she").as_deref(), Some("/shear "));
        // full command with args → leave it alone
        assert_eq!(complete_slash("/summarize 50"), None);
        // not a slash line
        assert_eq!(complete_slash("hey /sum"), None);
        assert_eq!(complete_slash("plain"), None);
    }
}
