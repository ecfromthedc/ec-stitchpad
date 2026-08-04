//! The barn — kanban board over the pad's fenced ```task blocks.
//!
//! Design notes (clutter audit, v2): the old board nested a full outer border
//! AND a border per column — two borders between terminal edge and a card.
//! Both are gone. Columns are now a status-colored header + a hairline rule;
//! cards carry an assignee-colored bar (same language as the chat gutter) and
//! the selected card sits on a raised `surface` row. Navigation is spatial:
//! h/l walk columns, j/k walk cards within a column.

use crate::theme;
use ratatui::{
    buffer::Buffer,
    layout::{Constraint, Direction, Layout, Rect},
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Block, BorderType, Borders, Paragraph, Widget, Wrap},
};

/// A single ticket. Mirrors the locked per-ticket fenced block (randy, 03:57):
///   ```task TASK-1
///   title: ...
///   status: backlog|todo|in_progress|in_review|done|canceled
///   priority: none|low|medium|high|urgent
///   assignee: name
///   labels: a, b
///   created: 06-17 03:40
///   ---
///   description body (multi-line)
///   ```
/// ponytail: V1 fields only (id,title,status,priority,assignee,labels,created,description);
/// project/cycle/parent/estimate are phase-2 — parser ignores unknown keys, so adding
/// them later is zero-break.
#[derive(Debug, Clone, Default)]
pub struct Task {
    pub id: String,
    pub title: String,
    pub status: String,
    pub priority: String,
    pub assignee: String,
    pub labels: Vec<String>,
    pub created: String,
    pub description: String,
}

/// Kanban board: tickets bucketed into columns by status.
pub struct TaskBoard {
    pub tasks: Vec<Task>,
    pub selected: usize,
}

// Columns in Linear order. Anything with an unrecognised status lands in the last
// bucket so nothing is dropped silently.
const COLUMNS: [(&str, &str); 6] = [
    ("backlog", "BACKLOG"),
    ("todo", "TODO"),
    ("in_progress", "IN PROGRESS"),
    ("in_review", "IN REVIEW"),
    ("done", "DONE"),
    ("canceled", "CANCELED"),
];

const PRIORITY_ORDER: [&str; 5] = ["none", "low", "medium", "high", "urgent"];

/// Column identity color — status is chrome, so it uses semantic tokens.
fn column_color(ci: usize) -> ratatui::style::Color {
    let t = theme::t();
    match ci {
        0 => t.muted,   // backlog
        1 => t.info,    // todo
        2 => t.warn,    // in progress
        3 => t.special, // in review
        4 => t.ok,      // done
        _ => t.faint,   // canceled
    }
}

/// Priority renders as glyph + color (never color alone).
fn priority_glyph(p: &str) -> (&'static str, ratatui::style::Color, bool) {
    let t = theme::t();
    match p.trim().to_lowercase().as_str() {
        "urgent" => ("!!", t.err, true),
        "high" => ("!", t.err, false),
        "medium" => ("◆", t.warn, false),
        "low" => ("◇", t.info, false),
        _ => ("·", t.faint, false),
    }
}

impl TaskBoard {
    pub fn from_pad() -> Self {
        Self {
            tasks: parse_tasks(),
            selected: 0,
        }
    }

    pub fn refresh(&mut self) {
        self.tasks = parse_tasks();
        if self.selected >= self.tasks.len() {
            self.selected = self.tasks.len().saturating_sub(1);
        }
    }

    /// Flat next/prev — wheel scroll keeps its old feel.
    pub fn next(&mut self) {
        if !self.tasks.is_empty() {
            self.selected = (self.selected + 1) % self.tasks.len();
        }
    }
    pub fn previous(&mut self) {
        if !self.tasks.is_empty() {
            self.selected = (self.selected + self.tasks.len() - 1) % self.tasks.len();
        }
    }

    /// Task indices in the selected task's column, in render order.
    fn column_of_selected(&self) -> (usize, Vec<usize>) {
        let ci = self
            .selected_task()
            .map(|t| bucket(&t.status))
            .unwrap_or(0);
        let idxs = (0..self.tasks.len())
            .filter(|i| bucket(&self.tasks[*i].status) == ci)
            .collect();
        (ci, idxs)
    }

    /// j/k — move within the current column, clamped (no wraparound surprise).
    pub fn next_in_column(&mut self) {
        let (_, idxs) = self.column_of_selected();
        if let Some(pos) = idxs.iter().position(|i| *i == self.selected) {
            if pos + 1 < idxs.len() {
                self.selected = idxs[pos + 1];
            }
        }
    }
    pub fn prev_in_column(&mut self) {
        let (_, idxs) = self.column_of_selected();
        if let Some(pos) = idxs.iter().position(|i| *i == self.selected) {
            if pos > 0 {
                self.selected = idxs[pos - 1];
            }
        }
    }

    /// h/l — hop to the nearest non-empty column left/right of the current one.
    pub fn move_column(&mut self, forward: bool) {
        if self.tasks.is_empty() {
            return;
        }
        let (cur, _) = self.column_of_selected();
        let range: Vec<usize> = if forward {
            (cur + 1..COLUMNS.len()).collect()
        } else {
            (0..cur).rev().collect()
        };
        for ci in range {
            if let Some(first) = (0..self.tasks.len()).find(|i| bucket(&self.tasks[*i].status) == ci)
            {
                self.selected = first;
                return;
            }
        }
    }

    pub fn selected_task(&self) -> Option<&Task> {
        self.tasks.get(self.selected)
    }

    /// Move the selected task one status column forward/back (backlog↔…↔done) via
    /// the CLI, then re-read. Canceling is explicit (`set_selected_status`), not on
    /// the arrow path, so ]] can't accidentally kill a ticket.
    pub fn move_selected(&mut self, forward: bool) {
        let Some(task) = self.selected_task() else { return };
        let cur = bucket(&task.status);
        let last_movable = 4; // done — ]/[ never walks into canceled
        let next = if forward {
            (cur + 1).min(last_movable)
        } else {
            cur.saturating_sub(1)
        };
        if next == cur || cur > last_movable {
            return;
        }
        self.set_selected_status(COLUMNS[next].0);
    }

    /// Set the selected task to an explicit status via the CLI, then re-read.
    pub fn set_selected_status(&mut self, status: &str) {
        let Some(task) = self.selected_task() else { return };
        let id = task.id.clone();
        let _ = std::process::Command::new("stitchpad")
            .args(["task", "move", &id, status])
            .output();
        self.refresh();
        // keep the same ticket selected across the re-read (it changed columns)
        if let Some(pos) = self.tasks.iter().position(|t| t.id == id) {
            self.selected = pos;
        }
    }

    /// Cycle the selected task's priority (none→low→…→urgent→none) via the CLI.
    pub fn cycle_priority(&mut self) {
        let Some(task) = self.selected_task() else { return };
        let id = task.id.clone();
        let cur = PRIORITY_ORDER
            .iter()
            .position(|p| *p == task.priority.trim().to_lowercase())
            .unwrap_or(0);
        let next = PRIORITY_ORDER[(cur + 1) % PRIORITY_ORDER.len()];
        let _ = std::process::Command::new("stitchpad")
            .args(["task", "edit", &id, "--priority", next])
            .output();
        self.refresh();
        if let Some(pos) = self.tasks.iter().position(|t| t.id == id) {
            self.selected = pos;
        }
    }
}

/// Centered overlay rect: `pct` of the area, clamped to sane minimums.
pub fn overlay_rect(area: Rect, pct_x: u16, pct_y: u16) -> Rect {
    let w = (area.width as u32 * pct_x as u32 / 100).max(30) as u16;
    let h = (area.height as u32 * pct_y as u32 / 100).max(8) as u16;
    let w = w.min(area.width);
    let h = h.min(area.height);
    Rect {
        x: area.x + (area.width - w) / 2,
        y: area.y + (area.height - h) / 2,
        width: w,
        height: h,
    }
}

/// Truncate to `width` display chars with a … reserve. Char-count based — chat
/// prose and ticket titles, not CJK tables.
fn truncate(s: &str, width: usize) -> String {
    let n = s.chars().count();
    if n <= width {
        return s.to_string();
    }
    let take = width.saturating_sub(1);
    let mut out: String = s.chars().take(take).collect();
    out.push('…');
    out
}

/// Full-field detail card for one task, rendered as a modal overlay.
pub fn render_detail(task: &Task, area: Rect, buf: &mut Buffer) {
    let t = theme::t();
    let rect = overlay_rect(area, 70, 60);
    ratatui::widgets::Clear.render(rect, buf);
    let ci = bucket(&task.status);
    let block = Block::default()
        .title(Line::from(vec![
            Span::styled(
                format!(" {} ", task.id),
                Style::default().fg(t.accent).add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                format!("· {} ", COLUMNS[ci].1.to_lowercase()),
                Style::default().fg(column_color(ci)),
            ),
        ]))
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(t.accent))
        .style(Style::default().bg(t.surface));
    let inner = block.inner(rect);
    block.render(rect, buf);

    let label = Style::default().fg(t.muted);
    let (pg, pc, pb) = priority_glyph(&task.priority);
    let mut pstyle = Style::default().fg(pc);
    if pb {
        pstyle = pstyle.add_modifier(Modifier::BOLD);
    }
    let mut lines: Vec<Line> = vec![
        Line::from(Span::styled(
            task.title.clone(),
            Style::default().fg(t.fg).add_modifier(Modifier::BOLD),
        )),
        Line::from(""),
        Line::from(vec![
            Span::styled("priority ", label),
            Span::styled(format!("{} {}", pg, task.priority), pstyle),
            Span::styled("   assignee ", label),
            Span::styled(
                format!("@{}", task.assignee),
                Style::default().fg(crate::color::color_for(&task.assignee)),
            ),
            Span::styled("   created ", label),
            Span::styled(task.created.clone(), Style::default().fg(t.fg)),
        ]),
    ];
    if !task.labels.is_empty() {
        let mut chips = vec![Span::styled("labels   ", label)];
        for l in &task.labels {
            chips.push(Span::styled(
                format!("[{}] ", l),
                Style::default().fg(t.info),
            ));
        }
        lines.push(Line::from(chips));
    }
    lines.push(Line::from(""));
    for l in task.description.lines() {
        lines.push(Line::from(Span::styled(
            l.to_string(),
            Style::default().fg(t.fg),
        )));
    }
    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled(
        "Esc:close   ]/[:move status   p:priority   d:done   x:cancel",
        Style::default().fg(t.faint),
    )));
    Paragraph::new(lines)
        .wrap(Wrap { trim: false })
        .render(inner, buf);
}

/// Collect every ```task <ID> block from the pad AND tasks.md, parse key:value
/// frontmatter + description body.  tasks.md is read LAST so a migrated card
/// wins over a stale inline copy of the same id.  Display order is first-seen
/// (pad first, then tasks.md).  Unreadable files or no blocks → empty.
fn parse_tasks() -> Vec<Task> {
    let pad = std::fs::read_to_string(crate::pad_file()).unwrap_or_default();
    let tasks = std::fs::read_to_string(crate::tasks_file()).unwrap_or_default();
    parse_tasks_merged(&pad, &tasks)
}

/// Merge tasks from two sources: pad_str (stitchpad.md/pasture.md) read first,
/// tasks_str (tasks.md) read second.  Duplicate ids: last writer wins.
/// Display order: first-seen (pad first, then tasks.md-only entries).
fn parse_tasks_merged(pad_str: &str, tasks_str: &str) -> Vec<Task> {
    let mut order: Vec<String> = Vec::new();
    let mut data: std::collections::HashMap<String, Task> = std::collections::HashMap::new();

    for s in [pad_str, tasks_str] {
        for t in parse_tasks_str(s) {
            if t.id.is_empty() {
                continue;
            }
            if !data.contains_key(&t.id) {
                order.push(t.id.clone());
            }
            data.insert(t.id.clone(), t);
        }
    }

    order.iter().filter_map(|id| data.remove(id)).collect()
}

fn parse_tasks_str(pad: &str) -> Vec<Task> {
    let mut tasks = Vec::new();
    let mut cur: Option<Task> = None;
    let mut in_body = false; // past the --- separator → collecting description

    for line in pad.lines() {
        let t = line.trim_end();
        let tt = t.trim();

        if let Some(rest) = tt.strip_prefix("```task") {
            // start of a ticket block; ID is the token after ```task
            let mut task = Task::default();
            task.id = rest.trim().to_string();
            cur = Some(task);
            in_body = false;
            continue;
        }

        if cur.is_some() && tt == "```" {
            // end of the current ticket block
            if let Some(task) = cur.take() {
                if !task.id.is_empty() || !task.title.is_empty() {
                    tasks.push(task);
                }
            }
            in_body = false;
            continue;
        }

        let Some(task) = cur.as_mut() else { continue };

        if !in_body && tt == "---" {
            in_body = true;
            continue;
        }

        if in_body {
            // description body, multi-line — preserve line breaks, trim leading blank
            if task.description.is_empty() && tt.is_empty() {
                continue;
            }
            if !task.description.is_empty() {
                task.description.push('\n');
            }
            task.description.push_str(t);
            continue;
        }

        // frontmatter: skip # comment lines (contract pt.4 w/ lib.sh sp_tasks), then key: value
        if tt.starts_with('#') {
            continue;
        }
        if let Some((k, v)) = tt.split_once(':') {
            let (k, v) = (k.trim().to_lowercase(), v.trim());
            match k.as_str() {
                "title" => task.title = v.to_string(),
                "status" => task.status = v.to_lowercase(),
                "priority" => task.priority = v.to_lowercase(),
                "assignee" => task.assignee = v.trim_start_matches('@').to_string(),
                "labels" => {
                    task.labels = v
                        .split(',')
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty())
                        .collect()
                }
                "created" => task.created = v.to_string(),
                _ => {} // phase-2 fields (project/cycle/parent/estimate) ignored, no break
            }
        }
    }
    tasks
}

impl Widget for &TaskBoard {
    fn render(self, area: Rect, buf: &mut Buffer) {
        let t = theme::t();

        if self.tasks.is_empty() {
            let pad = (area.width.saturating_sub(24) / 2) as usize;
            let lines = crate::logo::empty_state(
                "the barn is empty",
                "`stitchpad task new \"title\"` puts a chore on the board",
                pad,
            );
            Paragraph::new(lines).render(area, buf);
            return;
        }

        // Only render columns that have tickets, so 6 columns don't crush card width
        // on a narrow terminal. (Empty Linear columns are noise here.)
        let cols_with_tasks: Vec<(usize, &str)> = COLUMNS
            .iter()
            .enumerate()
            .filter_map(|(ci, (_key, label))| {
                let has = self.tasks.iter().any(|t| bucket(&t.status) == ci);
                if has { Some((ci, *label)) } else { None }
            })
            .collect();
        if cols_with_tasks.is_empty() {
            return;
        }

        // Breathing room: one blank row above, one col each side.
        let inner = Rect {
            x: area.x + 1,
            y: area.y + 1,
            width: area.width.saturating_sub(2),
            height: area.height.saturating_sub(1),
        };
        let n = cols_with_tasks.len() as u32;
        let constraints: Vec<Constraint> = (0..n).map(|_| Constraint::Ratio(1, n)).collect();
        let layout = Layout::default()
            .direction(Direction::Horizontal)
            .constraints(constraints)
            .spacing(2)
            .split(inner);

        const CARD_H: u16 = 3; // title + meta + gap
        for (slot, (ci, label)) in cols_with_tasks.iter().enumerate() {
            let col = layout[slot];
            if col.width < 8 {
                continue;
            }
            let cc = column_color(*ci);
            let col_tasks: Vec<(usize, &Task)> = self
                .tasks
                .iter()
                .enumerate()
                .filter(|(_, t)| bucket(&t.status) == *ci)
                .collect();

            // ── column header: "TODO 3 ─────────" (1 row of chrome, no box) ──
            let count = format!(" {}", col_tasks.len());
            let used = label.chars().count() + count.chars().count() + 1;
            let rule_w = (col.width as usize).saturating_sub(used + 1);
            let header = Line::from(vec![
                Span::styled(
                    (*label).to_string(),
                    Style::default().fg(cc).add_modifier(Modifier::BOLD),
                ),
                Span::styled(count, Style::default().fg(t.muted)),
                Span::raw(" "),
                Span::styled("─".repeat(rule_w), Style::default().fg(t.faint)),
            ]);
            buf.set_line(col.x, col.y, &header, col.width);

            // ── cards, windowed so the selected card is always visible ──
            let cards_area_h = col.height.saturating_sub(2);
            let visible = (cards_area_h / CARD_H).max(1) as usize;
            let sel_pos = col_tasks
                .iter()
                .position(|(i, _)| *i == self.selected)
                .unwrap_or(0);
            let offset = sel_pos.saturating_sub(visible.saturating_sub(1));
            let mut y = col.y + 2;
            for (pos, (ti, task)) in col_tasks.iter().enumerate() {
                if pos < offset {
                    continue;
                }
                if y + 1 >= col.y + col.height {
                    // more below the fold — say so instead of silently clipping
                    let more = col_tasks.len() - pos;
                    let hint = Line::from(Span::styled(
                        format!("… {} more", more),
                        Style::default().fg(t.faint),
                    ));
                    buf.set_line(col.x + 2, (col.y + col.height).saturating_sub(1), &hint, col.width);
                    break;
                }
                let selected = *ti == self.selected;
                let acc = crate::color::color_for(&task.assignee);
                let (pg, pc, pb) = priority_glyph(&task.priority);
                let mut pstyle = Style::default().fg(pc);
                if pb {
                    pstyle = pstyle.add_modifier(Modifier::BOLD);
                }

                // selected card sits on a raised surface row (bar + both lines)
                if selected {
                    for dy in 0..2u16 {
                        let row = Rect {
                            x: col.x,
                            y: y + dy,
                            width: col.width,
                            height: 1,
                        };
                        buf.set_style(row, Style::default().bg(t.surface));
                    }
                }
                let bar = if selected { "▌" } else { "▏" };
                let title_style = if selected {
                    Style::default().fg(t.fg).add_modifier(Modifier::BOLD)
                } else {
                    Style::default().fg(t.fg)
                };
                // line 1: assignee-colored bar · priority · dim id · title
                let head = format!("{} {} ", task.id, task.title);
                let avail = (col.width as usize).saturating_sub(5);
                let id_len = task.id.chars().count();
                let shown = truncate(&head, avail);
                let (id_part, title_part) = if shown.chars().count() > id_len {
                    let split = shown.char_indices().nth(id_len).map(|(b, _)| b).unwrap_or(0);
                    (shown[..split].to_string(), shown[split..].to_string())
                } else {
                    (shown, String::new())
                };
                let card = Line::from(vec![
                    Span::styled(bar, Style::default().fg(acc)),
                    Span::raw(" "),
                    Span::styled(format!("{} ", pg), pstyle),
                    Span::styled(id_part, Style::default().fg(t.faint)),
                    Span::styled(title_part, title_style),
                ]);
                buf.set_line(col.x, y, &card, col.width);
                // line 2: @assignee (agent-colored) + label chips
                let mut meta = vec![
                    Span::styled(bar, Style::default().fg(acc)),
                    Span::raw("   "),
                    Span::styled(
                        truncate(&format!("@{}", task.assignee), (col.width as usize).saturating_sub(4)),
                        Style::default().fg(acc),
                    ),
                ];
                for l in &task.labels {
                    meta.push(Span::styled(
                        format!(" [{}]", l),
                        Style::default().fg(t.faint),
                    ));
                }
                buf.set_line(col.x, y + 1, &Line::from(meta), col.width);
                y += CARD_H;
            }
        }
    }
}

/// Which column index a status falls into. Unknown status → last column (canceled
/// bucket) so it's visible, never dropped.
fn bucket(status: &str) -> usize {
    let s = status.trim().to_lowercase();
    COLUMNS
        .iter()
        .position(|(k, _)| *k == s)
        .unwrap_or(COLUMNS.len() - 1)
}

#[cfg(test)]
mod tests {
    use super::*;
    const PAD: &str = "\
# pad
```roster
dale | claude | push | -
```
```task TASK-1
title: wire MCP | with a pipe in title
status: in_progress
priority: high
assignee: ernie
labels: infra, installer
created: 06-17 03:40
---
description body here
multi-line ok
```
```task TASK-2
title: tasks TUI tab
status: todo
priority: medium
assignee: dale
labels: ui
---
the body
```
";

    #[test]
    fn parses_two_tickets_with_edge_cases() {
        let t = parse_tasks_str(PAD);
        assert_eq!(t.len(), 2, "should find both task blocks, not the roster block");
        // pipe in title survives (key:value, not pipe-delimited)
        assert_eq!(t[0].id, "TASK-1");
        assert_eq!(t[0].title, "wire MCP | with a pipe in title");
        assert_eq!(t[0].status, "in_progress");
        assert_eq!(t[0].assignee, "ernie");
        assert_eq!(t[0].labels, vec!["infra", "installer"]);
        // multi-line description body preserved
        assert_eq!(t[0].description, "description body here\nmulti-line ok");
        // unknown status would bucket to last column; known ones map correctly
        assert_eq!(bucket("in_progress"), 2);
        assert_eq!(bucket("done"), 4);
        assert_eq!(bucket("bogus"), COLUMNS.len() - 1);
    }

    #[test]
    fn empty_pad_no_tasks() {
        assert!(parse_tasks_str("# just a pad\nno blocks").is_empty());
    }

    #[test]
    fn column_navigation_is_spatial() {
        let mut board = TaskBoard {
            tasks: parse_tasks_str(PAD),
            selected: 0,
        };
        // TASK-1 is in_progress (col 2), TASK-2 is todo (col 1)
        assert_eq!(board.selected_task().unwrap().id, "TASK-1");
        board.move_column(false); // left → todo column
        assert_eq!(board.selected_task().unwrap().id, "TASK-2");
        board.move_column(true); // right → back to in_progress
        assert_eq!(board.selected_task().unwrap().id, "TASK-1");
        // j/k clamp within a 1-card column
        board.next_in_column();
        assert_eq!(board.selected_task().unwrap().id, "TASK-1");
    }

    #[test]
    fn truncate_reserves_ellipsis() {
        assert_eq!(truncate("hello world", 8), "hello w…");
        assert_eq!(truncate("short", 8), "short");
    }

    // ── TASK-26: dual-file merge (pad + tasks.md) with last-wins dedup ──

    const TASKSM: &str = "\
# 📋 tasks

```task TASK-3
title: from tasks.md only
status: in_progress
priority: high
assignee: alice
---
tasks.md body
```
```task TASK-1
title: overwritten title from tasks.md
status: done
priority: low
assignee: bob
---
tasks.md overwrites pad body
```
";

    #[test]
    fn tasks_from_tasksmd_only() {
        let tasks = parse_tasks_merged("# just a pad\nno tasks here\n", TASKSM);
        let t3: Vec<_> = tasks.iter().filter(|t| t.id == "TASK-3").collect();
        assert_eq!(t3.len(), 1, "TASK-3 from tasks.md should be visible");
        assert_eq!(t3[0].title, "from tasks.md only");
        assert_eq!(t3[0].status, "in_progress");
    }

    #[test]
    fn tasks_from_pad_only() {
        let tasks = parse_tasks_merged(PAD, "# just tasks\nno blocks\n");
        let t2: Vec<_> = tasks.iter().filter(|t| t.id == "TASK-2").collect();
        assert_eq!(t2.len(), 1, "TASK-2 from pad should be visible");
        assert_eq!(t2[0].title, "tasks TUI tab");
    }

    #[test]
    fn dedup_task_1_last_wins_from_tasksmd() {
        let tasks = parse_tasks_merged(PAD, TASKSM);
        let t1: Vec<_> = tasks.iter().filter(|t| t.id == "TASK-1").collect();
        assert_eq!(t1.len(), 1, "TASK-1 should appear exactly once (dedup)");
        assert_eq!(t1[0].title, "overwritten title from tasks.md",
            "tasks.md version must win");
        assert_eq!(t1[0].status, "done");
        assert_eq!(t1[0].assignee, "bob");
        assert_eq!(t1[0].description, "tasks.md overwrites pad body");
    }

    #[test]
    fn merge_preserves_first_seen_order() {
        let tasks = parse_tasks_merged(PAD, TASKSM);
        assert_eq!(tasks.len(), 3);
        assert_eq!(tasks[0].id, "TASK-1");
        assert_eq!(tasks[1].id, "TASK-2");
        assert_eq!(tasks[2].id, "TASK-3");
    }
}
