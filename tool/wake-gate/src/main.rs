// wake-gate — Rust port of the sp_engagement bash oracle.
//
// Usage: wake-gate <pad.md> <who> [since]
//
// Prints the 4-field engagement line, byte-identical to the awk oracle:
//   <ordinal> <sender> <last_reply> <reply_target>
//
// std only. Reuses tool/tui-rs edition 2024 conventions.
//
// The deafness bug (comparing newest reply against oldest mention) is made
// unrepresentable: answered-ness is a property of a Mention, resolved
// against a per-sender ReplyLedger. You cannot write the comparison that
// caused four of six live seats to go permanently deaf.

use std::collections::HashMap;
use std::env;
use std::fs;
use std::process;

// ── types ─────────────────────────────────────────────────────────────

/// A candidate mention — someone else's authored block that @-mentions
/// the target seat.  Ordinal and sender are carried together so
/// "answered" is always resolved against the sender-specific ledger entry.
#[derive(Debug)]
struct Mention {
    ordinal: usize,   // 1-based block number
    sender: String,   // lowercase author name
}

/// Per-sender reply ledger.  Maps sender → most recent ordinal where the
/// target seat replied to that sender.  This is the type that makes the
/// deafness bug unrepresentable: to check if a Mention is answered you
/// MUST go through the sender key — a bare ordinal comparison has no
/// type to live in.
#[derive(Debug, Default)]
struct ReplyLedger {
    entries: HashMap<String, usize>,
}

impl ReplyLedger {
    fn record_reply(&mut self, sender: &str, ordinal: usize) {
        self.entries.insert(sender.to_string(), ordinal);
    }

    /// True when the target seat has replied to this mention's sender
    /// at or after the mention's ordinal — this mention is handled.
    fn mention_is_answered(&self, m: &Mention) -> bool {
        self.entries.get(&m.sender)
            .map_or(false, |&reply_ord| reply_ord >= m.ordinal)
    }
}

/// The final engagement answer: which mention (if any) is unanswered,
/// plus the seat's reply state.
struct Engagement {
    mention_ordinal: usize,
    mention_sender: String,    // empty when ordinal==0
    last_reply: usize,
    reply_target: String,
}

// ── silent-ack word list ──────────────────────────────────────────────

const SILENT_WORDS: &[&str] = &[
    "ack", "read", "noted", "got it", "standing down", "standing by",
    "stand by", "will do", "understood", "done here", "copy", "sounds good",
];

fn is_silent_word(s: &str) -> bool {
    // Strip trailing punctuation: ".", "!", " "
    let trimmed = s.trim_end_matches(|c: char| c == '.' || c == '!' || c == ' ');
    SILENT_WORDS.contains(&trimmed)
}

// ── mention matching ──────────────────────────────────────────────────

/// Does `buf` contain any `@name`-style mention at a word boundary?
/// Equivalent to awk `buf ~ /(^|[ \t])@[a-z0-9_-]/`.
fn has_any_mention(buf: &str) -> bool {
    let bytes = buf.as_bytes();
    let n = bytes.len();
    let mut i = 0;
    while i < n {
        let at = match bytes[i..].iter().position(|&b| b == b'@') {
            Some(pos) => i + pos,
            None => break,
        };
        if at > 0 && !bytes[at - 1].is_ascii_whitespace() {
            i = at + 1;
            continue;
        }
        let after = at + 1;
        if after < n && (bytes[after].is_ascii_alphanumeric() || bytes[after] == b'_' || bytes[after] == b'-') {
            return true;
        }
        i = at + 1;
    }
    false
}

/// Does `buf` contain `@name` or `@all` at a word boundary?
/// buf has a leading space from append, so (^|[ \t]) matches the leading
/// space, handling block-start and mid-sentence identically.
fn body_mentions(buf: &str, name: &str) -> bool {
    let pattern_start = format!("@{}", name);
    let pattern_all = "@all";
    let bytes = buf.as_bytes();
    let n = bytes.len();

    let mut i = 0;
    while i < n {
        // Find next '@'
        let at = match bytes[i..].iter().position(|&b| b == b'@') {
            Some(pos) => i + pos,
            None => break,
        };
        // '@' valid only at start of buf or after whitespace
        if at > 0 && !bytes[at - 1].is_ascii_whitespace() {
            i = at + 1;
            continue;
        }
        // Check if rest matches `name` or `all`
        let rest = &buf[at..];
        let (matched_name, word_len) = if rest.starts_with(&pattern_start) {
            (true, pattern_start.len())
        } else if rest.starts_with(pattern_all) {
            (true, pattern_all.len())
        } else {
            (false, 0)
        };
        if matched_name {
            let end = at + word_len;
            // Must be at word boundary: end of buf or non-alphanumeric char
            if end >= n || !buf.as_bytes()[end].is_ascii_alphanumeric() && buf.as_bytes()[end] != b'_' && buf.as_bytes()[end] != b'-' {
                return true;
            }
        }
        i = at + 1;
    }
    false
}

/// Extract the first @-target from buf. Returns the lowercase name
/// (without @), skipping @all and self-references.
fn first_reply_target(buf: &str, who: &str) -> Option<String> {
    let bytes = buf.as_bytes();
    let n = bytes.len();
    let mut i = 0;

    // Limit to first 20 tokens (matches awk's i<=20 guard)
    let mut tokens_checked = 0;
    while i < n && tokens_checked < 20 {
        // Skip whitespace
        while i < n && bytes[i].is_ascii_whitespace() { i += 1; }
        if i >= n { break; }

        // Find end of this token
        let start = i;
        while i < n && !bytes[i].is_ascii_whitespace() { i += 1; }
        tokens_checked += 1;

        let token = &buf[start..i];
        let token_lower = token.to_lowercase();

        if token_lower.starts_with('@') && token_lower.len() > 1 {
            // Strip trailing non-name chars after the @name part
            let name_part = &token_lower[1..]; // after '@'
            // Find first char that isn't [a-z0-9_-]
            let end = name_part.find(|c: char| !c.is_ascii_alphanumeric() && c != '_' && c != '-')
                .unwrap_or(name_part.len());
            let name = &name_part[..end];
            if !name.is_empty() && name != "all" && name != who {
                return Some(name.to_string());
            }
        }
    }
    None
}

// ── parsing ───────────────────────────────────────────────────────────

struct Block {
    author: String,           // lowercase, empty for anonymous blocks
    body: String,             // joined lines with inline code stripped, leading space
    first_line: String,       // the first non-empty content line (lowercase), for silent-ack check
    silent: bool,
}

/// Parse all `## @author` blocks from pad markdown. Anonymous (`## ...`
/// without @) blocks are represented with author="" and skipped in flush.
fn parse_blocks(pad: &str) -> Vec<Block> {
    let mut blocks: Vec<Block> = Vec::new();
    let mut current_author = String::new();
    let mut current_body = String::new();
    let mut current_first_line = String::new();
    let mut in_block = false;
    let mut seen_body = false;
    let mut silent = false;
    let mut infence = false;

    for line in pad.lines() {
        // ---- fenced code toggle ----
        if line.trim_start().starts_with("```") {
            infence = !infence;
            continue;
        }
        if infence { continue; }

        // ---- authored block header ----
        if line.starts_with("## @") {
            // flush previous block
            if in_block {
                blocks.push(Block {
                    author: std::mem::take(&mut current_author),
                    body: std::mem::take(&mut current_body),
                    first_line: std::mem::take(&mut current_first_line),
                    silent,
                });
            }
            // start new block
            let rest = &line[4..];
            let author = rest.split_whitespace().next().unwrap_or("").to_lowercase();
            current_author = author;
            current_body = String::new();
            current_first_line = String::new();
            in_block = true;
            seen_body = false;
            silent = false;
            continue;
        }

        if !in_block { continue; }

        // ---- first non-empty content line: silent-ack detection ----
        if !seen_body && line.chars().any(|c| !c.is_whitespace()) {
            seen_body = true;
            let b = line.trim_start().to_lowercase();
            let b_trimmed = b.trim_end();
            current_first_line = b_trimmed.to_string();

            let n_at = count_at_mentions(b_trimmed);
            let after_strip = strip_leading_at_tokens(b_trimmed);
            let after_strip = after_strip.trim();

            if n_at < 2 {
                if after_strip.starts_with('.') || after_strip.starts_with("[ack]") {
                    silent = true;
                }
            }
        }

        // ---- strip inline code, append to body buffer ----
        let stripped = strip_inline_code(&line.to_lowercase());
        current_body.push(' ');
        current_body.push_str(&stripped);
    }

    // Flush last block
    if in_block {
        blocks.push(Block {
            author: current_author,
            body: current_body,
            first_line: current_first_line,
            silent,
        });
    }

    blocks
}

/// Count @mentions (greedy, non-overlapping) in s.
fn count_at_mentions(s: &str) -> usize {
    let bytes = s.as_bytes();
    let n = bytes.len();
    let mut i = 0;
    let mut count = 0;
    while i < n {
        match bytes[i..].iter().position(|&b| b == b'@') {
            Some(pos) => {
                let at = i + pos;
                // Check what follows: must be [a-z0-9_-]+
                let after = at + 1;
                if after < n && bytes[after].is_ascii_alphanumeric() {
                    // Count it, then skip past this @-name
                    count += 1;
                    i = after;
                    while i < n && (bytes[i].is_ascii_alphanumeric() || bytes[i] == b'_' || bytes[i] == b'-') {
                        i += 1;
                    }
                } else if after < n && bytes[after] == b'_' {
                    // @_ is not a valid mention, skip
                    count += 1;
                    i = after + 1;
                } else {
                    i = at + 1;
                }
            }
            None => break,
        }
    }
    count
}

/// Strip leading @tokens and their trailing whitespace, like awk's
/// `sub(/^(@[a-z0-9_-]+[ \t]*)+/, "", b)`
fn strip_leading_at_tokens(s: &str) -> String {
    let bytes = s.as_bytes();
    let n = bytes.len();
    let mut i = 0;
    while i < n {
        if bytes[i] == b'@' {
            let start = i;
            i += 1;
            while i < n && (bytes[i].is_ascii_alphanumeric() || bytes[i] == b'_' || bytes[i] == b'-') {
                i += 1;
            }
            if i > start + 1 {
                // Valid @-token consumed; also consume trailing whitespace
                while i < n && bytes[i].is_ascii_whitespace() { i += 1; }
                continue;
            }
            // Bare '@' or '@_' — not a valid token, stop stripping
            break;
        }
        break;
    }
    s[i..].to_string()
}

/// Replace backtick-delimited spans with a single space (matches awk's
/// `gsub(/\x60[^\x60]*\x60/, " ", line)`)
fn strip_inline_code(line: &str) -> String {
    let bytes = line.as_bytes();
    let n = bytes.len();
    let mut out = String::with_capacity(n);
    let mut i = 0;
    while i < n {
        if bytes[i] == b'`' {
            // Find closing backtick
            let close = bytes[i+1..].iter().position(|&b| b == b'`');
            match close {
                Some(pos) => {
                    out.push(' ');
                    i = i + 1 + pos + 1; // skip past closing backtick
                }
                None => {
                    // Unclosed backtick — treat as literal
                    out.push('`');
                    i += 1;
                }
            }
        } else {
            out.push(bytes[i] as char);
            i += 1;
        }
    }
    out
}

// ── oracle ────────────────────────────────────────────────────────────

fn engage(pad: &str, who: &str, since: usize, agents: &str) -> Engagement {
    let who_lower = who.to_lowercase();
    let mut blocks = parse_blocks(pad);

    // Post-process silent-ack for agent-only implicit word list.
    // The awk checks: index("," agents ",", "," author ",") > 0
    let agents_delimited = format!(",{},", agents);
    for block in &mut blocks {
        if block.silent || block.author.is_empty() { continue; }
        let author_delimited = format!(",{},", block.author);
        if agents_delimited.contains(&author_delimited) {
            // Check the first content line (lowercase, trimmed, before
            // inline-code stripping), which matches awk's `tolower($0)` on
            // the first non-empty line.
            let stripped = strip_leading_at_tokens(&block.first_line);
            let check = stripped.trim();
            if is_silent_word(check) {
                block.silent = true;
            }
        }
    }

    let mut candidates: Vec<Mention> = Vec::new();
    let mut reply_ledger = ReplyLedger::default();
    let mut last_reply: usize = 0;
    let mut reply_target = String::new();

    for (idx, block) in blocks.iter().enumerate() {
        let ordinal = idx + 1; // 1-based
        if block.author.is_empty() {
            continue; // anonymous block
        }

        if block.author == who_lower {
            // My own block
            let has_at_mention = has_any_mention(&block.body);
            if block.silent || has_at_mention {
                last_reply = ordinal;
                // Extract first @-target
                if let Some(target) = first_reply_target(&block.body, &who_lower) {
                    reply_target = target.clone();
                    reply_ledger.record_reply(&target, ordinal);
                }
            }
        } else if !block.silent && body_mentions(&block.body, &who_lower) {
            // Someone else's block mentioning me
            if ordinal > since {
                candidates.push(Mention {
                    ordinal,
                    sender: block.author.clone(),
                });
            }
        }
    }

    // Find first unanswered candidate (FIFO order)
    let mut mention_ordinal: usize = 0;
    let mut mention_sender = String::new();
    for c in &candidates {
        if !reply_ledger.mention_is_answered(c) {
            mention_ordinal = c.ordinal;
            mention_sender = c.sender.clone();
            break;
        }
    }

    Engagement {
        mention_ordinal,
        mention_sender,
        last_reply,
        reply_target,
    }
}

// ── main ──────────────────────────────────────────────────────────────

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: wake-gate <pad.md> <who> [since]");
        process::exit(2);
    }

    let pad_path = &args[1];
    let who = &args[2];
    let since: usize = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(0);

    let pad = fs::read_to_string(pad_path).unwrap_or_else(|e| {
        eprintln!("wake-gate: cannot read {}: {}", pad_path, e);
        process::exit(1);
    });

    // Build agent list from roster block in the pad.
    let agents = roster_agents(&pad);

    let e = engage(&pad, who, since, &agents);

    // Print byte-identical to awk: print (last_mention+0) " " (mention_sender) " " (last_reply+0) " " (reply_target)
    println!("{} {} {} {}",
        e.mention_ordinal,
        e.mention_sender,      // empty string prints as nothing between two spaces
        e.last_reply,
        e.reply_target,
    );
}

/// Extract agent names from a ```roster block in the pad.
/// Returns a comma-separated lowercase list, matching sp_roster | cut -d'|' -f1 | tr A-Z a-z | paste -sd,
fn roster_agents(pad: &str) -> String {
    let in_roster = pad.lines()
        .skip_while(|l| !l.trim().starts_with("```roster"))
        .skip(1) // skip the ```roster line
        .take_while(|l| !l.trim().starts_with("```"))
        .filter_map(|l| {
            let trimmed = l.trim();
            if trimmed.is_empty() || trimmed.starts_with('#') { return None; }
            // name | adapter | ...
            let name = trimmed.split('|').next().unwrap_or("").trim();
            if name.is_empty() { return None; }
            Some(name.to_lowercase())
        })
        .collect::<Vec<_>>()
        .join(",");
    in_roster
}

// ── tests ─────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_body_mentions_simple() {
        let buf = " @bob hey there";
        assert!(body_mentions(buf, "bob"));
    }

    #[test]
    fn test_body_mentions_all() {
        let buf = " @all listen up";
        assert!(body_mentions(buf, "alice"));
    }

    #[test]
    fn test_body_mentions_boundary() {
        // "@bob." should match, "@bob-helper" should not
        let buf = " @bob. yes";
        assert!(body_mentions(buf, "bob"));
        let buf2 = " @bob-helper no";
        assert!(!body_mentions(buf2, "bob"));
    }

    #[test]
    fn test_parse_blocks_fenced_code() {
        let pad = "```roster\nalice | codex | pull | -\nbob | codex | pull | -\n```\n\n## @bob · 12:00\n\n```\n@alice in fence\n```\n\n## @alice · 12:01\n\n@bob real mention\n";
        let blocks = parse_blocks(pad);
        assert_eq!(blocks.len(), 2);
        assert_eq!(blocks[0].author, "bob");
        // bob's body should NOT contain @alice (fenced)
        assert!(!blocks[0].body.contains("@alice"));
        assert!(blocks[1].body.contains("@bob"));
    }

    #[test]
    fn test_parse_blocks_inline_code() {
        let pad = "```roster\nalice | codex | pull | -\n```\n\n## @alice · 12:00\n\n`@bob` in code, @charlie real\n";
        let blocks = parse_blocks(pad);
        // inline `@bob` should be stripped, @charlie should remain
        assert!(!blocks[0].body.contains("@bob"));
        assert!(blocks[0].body.contains("@charlie"));
    }

    #[test]
    fn test_count_at_mentions() {
        assert_eq!(count_at_mentions("@bob hello"), 1);
        assert_eq!(count_at_mentions("@bob @alice test"), 2);
        assert_eq!(count_at_mentions("no mentions here"), 0);
    }

    #[test]
    fn test_strip_leading_at_tokens() {
        assert_eq!(strip_leading_at_tokens("@bob ack"), "ack");
        assert_eq!(strip_leading_at_tokens("@bob @alice something"), "something");
        assert_eq!(strip_leading_at_tokens("plain text"), "plain text");
    }

    #[test]
    fn test_is_silent_word() {
        assert!(is_silent_word("ack"));
        assert!(is_silent_word("ack."));
        assert!(is_silent_word("got it"));
        assert!(is_silent_word("standing by"));
        assert!(!is_silent_word("hello"));
    }

    #[test]
    fn test_first_reply_target() {
        let buf = " @bob @charlie something";
        assert_eq!(first_reply_target(buf, "alice"), Some("bob".to_string()));
    }

    #[test]
    fn test_first_reply_target_skip_all() {
        let buf = " @all @bob test";
        assert_eq!(first_reply_target(buf, "alice"), Some("bob".to_string()));
    }

    #[test]
    fn test_first_reply_target_skip_self() {
        let buf = " @alice @bob test";
        assert_eq!(first_reply_target(buf, "alice"), Some("bob".to_string()));
    }

    // ── golden-style integration tests ────────────────────────────────

    fn fixture_deafness() -> String {
        "```roster\nbob | codex | push | -\nalice | codex | push | -\n```\n\n## @alice · 12:00\n\n@bob hey bob — first ping\n\n## @bob · 12:01\n\n@alice thanks alice — reply to first\n\n## @alice · 12:02\n\n@bob second ping after bob replied\n".to_string()
    }

    #[test]
    fn test_deafness_bob_since0() {
        let pad = fixture_deafness();
        let agents = roster_agents(&pad);
        let e = engage(&pad, "bob", 0, &agents);
        assert_eq!(e.mention_ordinal, 3);
        assert_eq!(e.mention_sender, "alice");
        assert_eq!(e.last_reply, 2);
        assert_eq!(e.reply_target, "alice");
    }

    #[test]
    fn test_deafness_bob_since3() {
        let pad = fixture_deafness();
        let agents = roster_agents(&pad);
        let e = engage(&pad, "bob", 3, &agents);
        assert_eq!(e.mention_ordinal, 0);
        assert_eq!(e.mention_sender, "");
        assert_eq!(e.last_reply, 2);
        assert_eq!(e.reply_target, "alice");
    }

    #[test]
    fn test_deafness_alice_since0() {
        let pad = fixture_deafness();
        let agents = roster_agents(&pad);
        let e = engage(&pad, "alice", 0, &agents);
        assert_eq!(e.mention_ordinal, 0);
        assert_eq!(e.mention_sender, "");
        assert_eq!(e.last_reply, 3);
        assert_eq!(e.reply_target, "bob");
    }

    #[test]
    fn test_cross_sender_bob() {
        let pad = "```roster\nalice | codex | pull | -\nbob | codex | pull | -\ncharlie | codex | pull | -\n```\n\n## @alice · 12:00\n\n@bob ping bob\n\n## @charlie · 12:01\n\n@bob ping from charlie too\n\n## @bob · 12:02\n\n@alice reply to alice only — charlie still unanswered\n\n## @bob · 12:03\n\n@charlie now reply to charlie too\n\n## @alice · 12:04\n\n@bob new mention from alice\n";
        let agents = roster_agents(&pad);
        // bob at since=0: charlie's mention at ordinal 2 is unanswered
        let e = engage(&pad, "bob", 0, &agents);
        assert_eq!(e.mention_ordinal, 5); // alice's new mention at ordinal 5
        assert_eq!(e.mention_sender, "alice");
        assert_eq!(e.last_reply, 4);
        assert_eq!(e.reply_target, "charlie");
    }

    #[test]
    fn test_cross_sender_charlie() {
        let pad = "```roster\nalice | codex | pull | -\nbob | codex | pull | -\ncharlie | codex | pull | -\n```\n\n## @alice · 12:00\n\n@bob ping bob\n\n## @charlie · 12:01\n\n@bob ping from charlie too\n\n## @bob · 12:02\n\n@alice reply to alice only — charlie still unanswered\n\n## @bob · 12:03\n\n@charlie now reply to charlie too\n\n## @alice · 12:04\n\n@bob new mention from alice\n";
        let agents = roster_agents(&pad);
        // charlie at since=0: charlie's block at ord 2 (@bob) sets reply_to["bob"]=2.
        // bob's block at ord 4 mentions @charlie → candidate (sender=bob, ord=4).
        // reply_to["bob"]=2 < 4 → unanswered.  So first unanswered is ord=4.
        let e = engage(&pad, "charlie", 0, &agents);
        assert_eq!(e.mention_ordinal, 4);
        assert_eq!(e.mention_sender, "bob");
        assert_eq!(e.last_reply, 2);
        assert_eq!(e.reply_target, "bob");
    }

    #[test]
    fn test_self_authored_skip() {
        let pad = "```roster\nalice | codex | pull | -\nbob | codex | pull | -\n```\n\n## @alice · 12:00\n\n@bob self? No — from alice to bob\n\n## @bob · 12:01\n\n@alice replying to alice\n\n## @bob · 12:02\n\n@bob this mentions myself, skipped for me\n";
        let agents = roster_agents(&pad);
        // bob at since=0: alice's mention at ordinal 1 is ANSWERED by bob's
        // reply at ordinal 2 (reply_to["alice"]=2 >= 1). Bob's self-@mention
        // at ordinal 3 bumps last_reply to 3 but does not update reply_target.
        let e = engage(&pad, "bob", 0, &agents);
        assert_eq!(e.mention_ordinal, 0);
        assert_eq!(e.mention_sender, "");
        assert_eq!(e.last_reply, 3);
        assert_eq!(e.reply_target, "alice");
    }
}
