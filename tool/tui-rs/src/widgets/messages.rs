use crate::theme;
use ratatui::{
    buffer::Buffer,
    layout::Rect,
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Paragraph, Widget},
};
use std::process::Command;

/// One parsed pad message: a `## @author · time [· #m-id] [· re:#m-id]` header
/// block + its body lines (grammar v2 — ids anchor reactions and threads).
#[derive(Debug, Clone)]
pub struct Message {
    pub author: String,
    pub time: String,
    pub body: Vec<String>,
    /// `#m-…` message id when the header carries one (v2 messages).
    pub id: Option<String>,
    /// Parent `#m-…` id when this message is a threaded reply.
    pub reply_to: Option<String>,
    /// Aggregated reactions: (emoji, [who…]) — from `*@x reacted E to #id*` lines.
    pub reactions: Vec<(String, Vec<String>)>,
    /// Absolute `## @` block ordinal from the start of the pad (1-based). This is the
    /// same unit `.state/seen.<name>` stores, so read-receipts compare against it.
    pub ordinal: usize,
    /// Names whose seen-cursor has reached this message (read-receipt: "seen by").
    pub seen_by: Vec<String>,
}

/// Scrollable, Slack-style message list. Mirrors RosterRail: owns its own data,
/// parses by shelling out to the bash CLI (`stitchpad read`) — the CLI stays the
/// engine, this is just a client view.
pub struct MessageList {
    pub messages: Vec<Message>,
    /// Lines scrolled up from the bottom. 0 = pinned to newest (auto-follow).
    pub scroll: u16,
    /// When true, new messages keep us pinned to the bottom; any manual scroll-up
    /// turns it off so the view doesn't jump while you read history.
    pub follow: bool,
    /// Mouse drag-selection over VISIBLE rows (relative to the panel's inner top,
    /// inclusive, unordered — render/copy normalize). None = no selection.
    pub selection: Option<(u16, u16)>,
}

impl MessageList {
    pub fn from_pad() -> Self {
        let messages = Self::parse_pad();
        Self {
            messages,
            scroll: 0,
            follow: true,
            selection: None,
        }
    }

    /// Plain text of the visible rows `a..=b` (inner-relative, unordered) at the
    /// given panel inner size — the drag-copy payload. Gutter/indent prefixes are
    /// stripped so the clipboard gets message text, not box-drawing chrome.
    pub fn selected_text(&self, width: u16, height: u16, a: u16, b: u16) -> String {
        let all = self.rendered_lines(width);
        let h = height as usize;
        let total = all.len();
        let bottom = total.saturating_sub(self.scroll as usize);
        let start = bottom.saturating_sub(h);
        let (lo, hi) = if a <= b { (a, b) } else { (b, a) };
        let mut out = String::new();
        for row in lo..=hi {
            let idx = start + row as usize;
            if idx >= total {
                break;
            }
            let text: String = all[idx].spans.iter().map(|s| s.content.as_ref()).collect();
            // strip the "▎ " gutter and the 2-space body indent when present
            let stripped = text
                .strip_prefix("▎ ")
                .map(|t| t.strip_prefix("  ").unwrap_or(t))
                .unwrap_or(&text);
            out.push_str(stripped);
            out.push('\n');
        }
        out
    }

    /// Re-read the pad. Called on a file-change event (live-tail) or manual refresh.
    pub fn refresh(&mut self) {
        self.messages = Self::parse_pad();
        if self.follow {
            self.scroll = 0;
        }
    }

    /// Parse `stitchpad read -n N` output into messages. A block is a `## @name · time`
    /// header followed by body lines up to the next `## ` header. Roster/separator
    /// noise (lines before the first header) is ignored. Absolute block ordinals and
    /// read-receipts (`seen_by`) are attached after parsing.
    fn parse_pad() -> Vec<Message> {
        // -n large enough to fill any terminal; the CLI is the source of truth.
        let output = Command::new("stitchpad")
            .args(["read", "-n", "400"])
            .output()
            .ok()
            .and_then(|o| String::from_utf8(o.stdout).ok())
            .unwrap_or_default();

        let mut messages: Vec<Message> = Vec::new();
        let mut cur: Option<Message> = None;
        // id → [(emoji, who)] — reaction system lines aggregate into chips
        let mut rx: std::collections::HashMap<String, Vec<(String, String)>> =
            std::collections::HashMap::new();

        for line in output.lines() {
            if let Some(rest) = line.strip_prefix("## @") {
                // header segments split on " · ": author, time, then optional
                // "#m-…" id and "re:#m-…" parent (v2 grammar; extras ignored)
                if let Some(prev) = cur.take() {
                    messages.push(prev);
                }
                let mut segs = rest.split(" · ").map(str::trim);
                let author = segs.next().unwrap_or("").to_string();
                let time = segs.next().unwrap_or("").to_string();
                let (mut id, mut reply_to) = (None, None);
                for s in segs {
                    if let Some(i) = s.strip_prefix("#m-") {
                        id = Some(format!("m-{}", i));
                    } else if let Some(p) = s.strip_prefix("re:#") {
                        reply_to = Some(p.to_string());
                    }
                }
                cur = Some(Message {
                    author,
                    time,
                    body: Vec::new(),
                    id,
                    reply_to,
                    reactions: Vec::new(),
                    ordinal: 0,
                    seen_by: Vec::new(),
                });
            } else if let Some((who, emoji, target)) = parse_reaction_line(line) {
                // reactions collect into chips on their target — never body text
                rx.entry(target).or_default().push((emoji, who));
            } else if let Some(msg) = cur.as_mut() {
                // trim trailing blank lines lazily: skip leading blanks, keep inner
                if !(msg.body.is_empty() && line.trim().is_empty()) {
                    msg.body.push(line.to_string());
                }
            }
        }
        if let Some(prev) = cur.take() {
            messages.push(prev);
        }
        // attach aggregated reactions to their targets
        for m in messages.iter_mut() {
            if let Some(id) = &m.id {
                if let Some(pairs) = rx.remove(id) {
                    let mut per: Vec<(String, Vec<String>)> = Vec::new();
                    for (emoji, who) in pairs {
                        match per.iter_mut().find(|(e, _)| *e == emoji) {
                            Some((_, whos)) => {
                                if !whos.contains(&who) {
                                    whos.push(who);
                                }
                            }
                            None => per.push((emoji, vec![who])),
                        }
                    }
                    m.reactions = per;
                }
            }
        }

        // Absolute ordinals: `read -n` gives a tail, so number backwards from the pad's
        // total `## @` block count — that's the unit seen.<name> uses.
        let total = Self::total_blocks();
        let n = messages.len();
        for (i, m) in messages.iter_mut().enumerate() {
            // last parsed message is block `total`; earlier ones count down.
            m.ordinal = total.saturating_sub(n - 1 - i);
        }

        // Read-receipts: a member has "seen" block N if seen.<member> >= N. Exclude the
        // author (you don't receipt your own post) and any cursor of 0/missing.
        let cursors = Self::seen_cursors();
        for m in messages.iter_mut() {
            let mut seers: Vec<String> = cursors
                .iter()
                .filter(|(name, ord)| **ord >= m.ordinal && name.as_str() != m.author)
                .map(|(name, _)| name.clone())
                .collect();
            seers.sort();
            m.seen_by = seers;
        }

        messages
    }

    /// Total `## @` block count in the full pad — the absolute ordinal of the newest
    /// message. Cheap: count headers via the CLI's read of the whole file.
    fn total_blocks() -> usize {
        Command::new("stitchpad")
            .args(["read", "-n", "100000"])
            .output()
            .ok()
            .and_then(|o| String::from_utf8(o.stdout).ok())
            .map(|s| s.lines().filter(|l| l.starts_with("## @")).count())
            .unwrap_or(0)
    }

    /// Read `.state/seen.<name>` cursors → {name: highest-delivered-ordinal}. Missing
    /// dir or unreadable files just yield no receipts (graceful: no "seen by" shown).
    fn seen_cursors() -> std::collections::HashMap<String, usize> {
        let mut map = std::collections::HashMap::new();
        let dir = crate::pad_state();
        let dir = std::path::Path::new(&dir);
        if let Ok(entries) = std::fs::read_dir(dir) {
            for e in entries.flatten() {
                let fname = e.file_name();
                let fname = fname.to_string_lossy();
                if let Some(name) = fname.strip_prefix("seen.") {
                    if let Ok(s) = std::fs::read_to_string(e.path()) {
                        if let Ok(ord) = s.trim().parse::<usize>() {
                            map.insert(name.to_string(), ord);
                        }
                    }
                }
            }
        }
        map
    }

    /// Get author color from the shared color module — `Color::Rgb` straight from
    /// `stitchpad color <name>`, so the board matches the terminal/window exactly.
    fn author_color(name: &str) -> Color {
        crate::color::color_for(name)
    }
}

/// Parse a reaction system line: `*@who reacted EMOJI to #m-id · TIME*`.
/// Returns (who, emoji, id) or None.
fn parse_reaction_line(line: &str) -> Option<(String, String, String)> {
    let t = line.trim();
    let inner = t.strip_prefix("*@")?.strip_suffix('*')?;
    let (who, rest) = inner.split_once(" reacted ")?;
    let (emoji, rest) = rest.split_once(" to #")?;
    let id = rest.split(" · ").next()?.trim();
    if !id.starts_with("m-") {
        return None;
    }
    Some((who.to_string(), emoji.to_string(), id.to_string()))
}

impl MessageList {

    pub fn scroll_up(&mut self) {
        self.follow = false;
        self.scroll = self.scroll.saturating_add(1);
    }

    pub fn scroll_down(&mut self) {
        self.scroll = self.scroll.saturating_sub(1);
        if self.scroll == 0 {
            self.follow = true;
        }
    }

    /// Render messages bottom-up into `width`-wrapped lines, then show the window
    /// ending `scroll` lines above the newest. Returns the flat line list so the
    /// Widget impl just slices it — keeps wrap + scroll logic in one place.
    fn rendered_lines(&self, width: u16) -> Vec<Line<'static>> {
        const GUTTER: &str = "▎";
        const GAP: &str = " ";
        const INDENT: &str = "  "; // body sits 2 cols under its author — Slack-style grouping
        const BODY_PREFIX_WIDTH: usize = 4; // gutter + gap + 2-space body indent
        let mut lines: Vec<Line> = Vec::new();
        for m in &self.messages {
            let color = Self::author_color(&m.author);
            // header: colored gutter + "@author · time". Keep the name as the strong
            // speaker cue; the gutter carries the color through the whole block.
            let mut header = vec![
                Span::styled(GUTTER, Style::default().fg(color)),
                Span::raw(GAP),
            ];
            if m.reply_to.is_some() {
                // threaded reply — quiet marker, body stays in the flow
                header.push(Span::styled("↳ ", Style::default().fg(theme::t().faint)));
            }
            header.push(Span::styled(
                format!("@{}", m.author),
                Style::default().fg(color).add_modifier(Modifier::BOLD),
            ));
            if !m.time.is_empty() {
                header.push(Span::styled(
                    format!("  ·  {}", m.time),
                    Style::default().fg(theme::t().faint),
                ));
            }
            if let Some(id) = &m.id {
                // the citable anchor — dim, but present so a human can thread
                header.push(Span::styled(
                    format!("  #{}", id),
                    Style::default().fg(theme::t().faint),
                ));
            }
            lines.push(Line::from(header));

            // body: inline-markdown → styled spans, word-wrapped, hanging-indented.
            // an `!img: <path>` line renders as a muted placeholder (inline image is a
            // later enhancement; the placeholder keeps it legible everywhere now).
            let avail = (width as usize).saturating_sub(BODY_PREFIX_WIDTH).max(8);
            let mut in_ui = false;
            for raw in &m.body {
                // ```ui <type> fences collapse to a one-line marker — the alt
                // line above them is the human-readable content here; the JSON
                // payload is for rich surfaces.
                if in_ui {
                    if raw.trim() == "```" {
                        in_ui = false;
                    }
                    continue;
                }
                if let Some(t) = raw.trim().strip_prefix("```ui ") {
                    in_ui = true;
                    lines.push(Line::from(vec![
                        Span::styled(GUTTER, Style::default().fg(color)),
                        Span::raw(GAP),
                        Span::raw(INDENT),
                        Span::styled(
                            format!("⟦ui {}⟧", t.trim()),
                            Style::default()
                                .fg(theme::t().special)
                                .add_modifier(Modifier::ITALIC),
                        ),
                    ]));
                    continue;
                }
                if raw.trim().is_empty() {
                    lines.push(Line::from(vec![
                        Span::styled(GUTTER, Style::default().fg(color)),
                        Span::raw(GAP),
                        Span::raw(INDENT),
                    ]));
                    continue;
                }
                if let Some(path) = super::markdown::image_path(raw) {
                    lines.push(Line::from(vec![
                        Span::styled(GUTTER, Style::default().fg(color)),
                        Span::raw(GAP),
                        Span::raw(INDENT),
                        Span::styled(
                            format!("[image: {}]", path),
                            Style::default()
                                .fg(theme::t().faint)
                                .add_modifier(Modifier::ITALIC),
                        ),
                    ]));
                    continue;
                }
                let spans = super::markdown::parse_line(raw);
                for mut row in wrap_spans(spans, avail) {
                    row.insert(0, Span::raw(INDENT));
                    row.insert(0, Span::raw(GAP));
                    row.insert(0, Span::styled(GUTTER, Style::default().fg(color)));
                    lines.push(Line::from(row));
                }
            }
            // reaction chips: one quiet line, emoji + who
            if !m.reactions.is_empty() {
                let mut spans = vec![
                    Span::styled(GUTTER, Style::default().fg(color)),
                    Span::raw(GAP),
                    Span::raw(INDENT),
                ];
                for (emoji, who) in &m.reactions {
                    spans.push(Span::styled(
                        format!("{} ", emoji),
                        Style::default().fg(theme::t().fg),
                    ));
                    spans.push(Span::styled(
                        who.iter().map(|w| format!("@{} ", w)).collect::<String>(),
                        Style::default().fg(theme::t().muted),
                    ));
                    spans.push(Span::raw(" "));
                }
                lines.push(Line::from(spans));
            }
            // read-receipt: quiet "seen by @x @y" under the message, only if anyone has.
            if !m.seen_by.is_empty() {
                let who = m
                    .seen_by
                    .iter()
                    .map(|n| format!("@{}", n))
                    .collect::<Vec<_>>()
                    .join(" ");
                lines.push(Line::from(vec![
                    Span::styled(GUTTER, Style::default().fg(color)),
                    Span::raw(GAP),
                    Span::raw(INDENT),
                    Span::styled(
                        format!("seen by {}", who),
                        Style::default()
                            .fg(theme::t().faint)
                            .add_modifier(Modifier::ITALIC),
                    ),
                ]));
            }
            lines.push(Line::from("")); // one-line breath between messages
        }
        lines
    }
}

impl Widget for &MessageList {
    fn render(self, area: Rect, buf: &mut Buffer) {
        let t = theme::t();
        let block = Block::default()
            .title(Line::from(Span::styled(
                " pasture ",
                Style::default().fg(t.muted),
            )))
            .borders(Borders::ALL)
            .border_style(Style::default().fg(t.faint));
        let inner = block.inner(area);
        block.render(area, buf);

        if self.messages.is_empty() {
            let pad = (inner.width.saturating_sub(24) / 2) as usize;
            let lines = crate::logo::empty_state(
                "the pasture is quiet",
                "type below to call the flock — @name wakes them",
                pad,
            );
            Paragraph::new(lines).render(inner, buf);
            return;
        }

        let all = self.rendered_lines(inner.width);
        let h = inner.height as usize;
        let total = all.len();

        // Bottom-anchored window: newest at the bottom, `scroll` lines above newest.
        let bottom = total.saturating_sub(self.scroll as usize);
        let start = bottom.saturating_sub(h);
        let end = bottom.min(total);

        for (row, line) in all[start..end].iter().enumerate() {
            buf.set_line(inner.x, inner.y + row as u16, line, inner.width);
        }

        // Drag-selection highlight: reverse the selected visible rows so the user
        // sees exactly what mouse-up will copy.
        if let Some((a, b)) = self.selection {
            let (lo, hi) = if a <= b { (a, b) } else { (b, a) };
            for row in lo..=hi.min(inner.height.saturating_sub(1)) {
                let rect = Rect {
                    x: inner.x,
                    y: inner.y + row,
                    width: inner.width,
                    height: 1,
                };
                buf.set_style(rect, Style::default().add_modifier(Modifier::REVERSED));
            }
        }
    }
}

/// Wrap a styled span run to `width`, preserving each span's style. Words keep their
/// style; wrapping happens on whitespace boundaries between styled words. An overlong
/// single word is hard-broken (style preserved). Returns one Vec<Span> per visual row.
fn wrap_spans(spans: Vec<Span<'static>>, width: usize) -> Vec<Vec<Span<'static>>> {
    let width = width.max(1);
    // explode spans into (word, style) units, splitting on whitespace within each span.
    let mut words: Vec<(String, Style)> = Vec::new();
    for s in spans {
        let style = s.style;
        let text = s.content.into_owned();
        let mut first = true;
        for w in text.split(' ') {
            // split(' ') keeps empties for runs of spaces; collapse to single spacing.
            if w.is_empty() {
                continue;
            }
            // re-introduce a leading space marker by not joining — handled at pack time.
            let _ = first;
            first = false;
            words.push((w.to_string(), style));
        }
    }

    let mut rows: Vec<Vec<Span<'static>>> = Vec::new();
    let mut row: Vec<Span<'static>> = Vec::new();
    let mut len = 0usize;
    for (word, style) in words {
        let wlen = word.chars().count();
        if wlen > width {
            if !row.is_empty() {
                rows.push(std::mem::take(&mut row));
                len = 0;
            }
            // hard-break the long word, preserving style
            let chars: Vec<char> = word.chars().collect();
            let mut i = 0;
            while i < chars.len() {
                let end = (i + width).min(chars.len());
                let chunk: String = chars[i..end].iter().collect();
                rows.push(vec![Span::styled(chunk, style)]);
                i = end;
            }
            continue;
        }
        let need = if row.is_empty() { wlen } else { len + 1 + wlen };
        if need > width {
            rows.push(std::mem::take(&mut row));
            row.push(Span::styled(word, style));
            len = wlen;
        } else {
            if !row.is_empty() {
                row.push(Span::raw(" "));
                len += 1;
            }
            row.push(Span::styled(word, style));
            len += wlen;
        }
    }
    if !row.is_empty() {
        rows.push(row);
    }
    if rows.is_empty() {
        rows.push(vec![Span::raw(String::new())]);
    }
    rows
}

/// Word-aware wrap to `width` columns. Keeps words intact; a single word longer
/// than the line (e.g. a URL) is hard-broken so it never overflows. (char count,
/// not grapheme — fine for chat prose.)
#[allow(dead_code)]
fn wrap_words(text: &str, width: usize) -> Vec<String> {
    let width = width.max(1);
    let mut out: Vec<String> = Vec::new();
    let mut line = String::new();
    let mut len = 0usize;
    for word in text.split_whitespace() {
        let wlen = word.chars().count();
        if wlen > width {
            // flush current, then hard-break the long word
            if !line.is_empty() {
                out.push(std::mem::take(&mut line));
                len = 0;
            }
            let chars: Vec<char> = word.chars().collect();
            let mut i = 0;
            while i < chars.len() {
                let end = (i + width).min(chars.len());
                out.push(chars[i..end].iter().collect());
                i = end;
            }
            continue;
        }
        let need = if line.is_empty() {
            wlen
        } else {
            len + 1 + wlen
        };
        if need > width {
            out.push(std::mem::take(&mut line));
            line.push_str(word);
            len = wlen;
        } else {
            if !line.is_empty() {
                line.push(' ');
                len += 1;
            }
            line.push_str(word);
            len += wlen;
        }
    }
    if !line.is_empty() {
        out.push(line);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::style::Style;

    fn line_text(line: &Line<'_>) -> String {
        line.spans.iter().map(|s| s.content.as_ref()).collect()
    }

    #[test]
    fn wrap_keeps_words_and_breaks_long_tokens() {
        // normal prose wraps on word boundaries
        let w = wrap_words("the quick brown fox jumps", 10);
        assert!(
            w.iter().all(|l| l.chars().count() <= 10),
            "no line exceeds width"
        );
        assert_eq!(
            w.join(" "),
            "the quick brown fox jumps",
            "words preserved in order"
        );
        // an over-long token is hard-broken, never overflows
        let long = wrap_words("https://example.com/really/long/path", 10);
        assert!(
            long.iter().all(|l| l.chars().count() <= 10),
            "long token hard-broken to width"
        );
    }

    // (author colors now come from the shared `stitchpad color` CLI as Color::Rgb —
    // see color.rs tests for hex parsing + the live terminal-match assertion. No
    // indexed-palette test here anymore; the CLI is the single source.)

    #[test]
    fn parse_splits_header_and_body() {
        // ensure the header/body split contract holds (drives the whole render)
        let m = Message {
            author: "dale".into(),
            time: "09:30 PM".into(),
            body: vec!["hi".into()],
            id: None,
            reply_to: None,
            reactions: Vec::new(),
            ordinal: 5,
            seen_by: vec!["mark".into()],
        };
        assert_eq!(m.author, "dale");
        assert_eq!(m.time, "09:30 PM");
        assert_eq!(m.ordinal, 5);
        assert_eq!(m.seen_by, vec!["mark".to_string()]);
    }

    #[test]
    fn reaction_line_parses_and_v2_header_segments_split() {
        // reaction system line → (who, emoji, target)
        assert_eq!(
            parse_reaction_line("*@dale reacted 👍 to #m-abc123 · 06:40 PM*"),
            Some(("dale".into(), "👍".into(), "m-abc123".into()))
        );
        // ordinary system lines are not reactions
        assert_eq!(parse_reaction_line("*@dale joined the stitchpad · 02:50 AM*"), None);

        // v2 header segments: "@who · time · #m-id · re:#m-parent"
        let rest = "dale · 06:38 PM · #m-8f3k2 · re:#m-aaa111";
        let mut segs = rest.split(" · ").map(str::trim);
        assert_eq!(segs.next(), Some("dale"));
        assert_eq!(segs.next(), Some("06:38 PM"));
        let extras: Vec<&str> = segs.collect();
        assert!(extras.contains(&"#m-8f3k2"));
        assert!(extras.contains(&"re:#m-aaa111"));
    }

    #[test]
    fn ui_fence_collapses_to_marker_and_reactions_render_chips() {
        let list = MessageList {
            messages: vec![Message {
                author: "dale".into(),
                time: "09:30 PM".into(),
                body: vec![
                    "shipping plan below".into(),
                    "```ui table".into(),
                    "{\"columns\":[\"a\"],\"rows\":[[\"1\"]]}".into(),
                    "```".into(),
                ],
                id: Some("m-abc".into()),
                reply_to: Some("m-parent".into()),
                reactions: vec![("👍".into(), vec!["ernie".into(), "smaths".into()])],
                ordinal: 1,
                seen_by: Vec::new(),
            }],
            scroll: 0,
            follow: true,
            selection: None,
        };
        let lines = list.rendered_lines(60);
        let text: Vec<String> = lines
            .iter()
            .map(|l| l.spans.iter().map(|s| s.content.as_ref()).collect())
            .collect();
        // header: reply marker + citable id
        assert!(text[0].contains("↳ @dale"));
        assert!(text[0].contains("#m-abc"));
        // json payload collapsed to one ⟦ui table⟧ marker, no raw JSON
        assert!(text.iter().any(|l| l.contains("⟦ui table⟧")));
        assert!(!text.iter().any(|l| l.contains("columns")));
        // reaction chips line present
        assert!(text.iter().any(|l| l.contains("👍 @ernie @smaths")));
    }

    #[test]
    fn rendered_lines_use_colored_gutter_but_keep_plain_body_text() {
        let list = MessageList {
            messages: vec![Message {
                author: "dale".into(),
                time: "09:30 PM".into(),
                body: vec!["hello".into()],
                id: None,
                reply_to: None,
                reactions: Vec::new(),
                ordinal: 5,
                seen_by: vec!["mark".into()],
            }],
            scroll: 0,
            follow: true,
            selection: None,
        };

        let lines = list.rendered_lines(40);
        assert_eq!(line_text(&lines[0]), "▎ @dale  ·  09:30 PM");
        assert_eq!(line_text(&lines[1]), "▎   hello");
        assert_eq!(line_text(&lines[2]), "▎   seen by @mark");
        assert_eq!(line_text(&lines[3]), "");

        assert_eq!(lines[1].spans[3].style, Style::default());
    }
}
