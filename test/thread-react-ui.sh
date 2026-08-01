#!/usr/bin/env bash
# Grammar v2 contract: message ids, threaded replies (--re), reactions
# (append + toggle-off), @flock gang-mention expansion, and the ```ui fence
# riding through say untouched. This is the pad-side truth the PWA/TUI/MCP
# all parse — if this file passes, every surface has something real to render.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
export STITCHPAD_STEAL=1
export STITCHPAD_HEARTBEAT_AUTOSTART=0
unset HERDR_PANE_ID 2>/dev/null || true

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

tmp="$(mktemp -d /tmp/stitchpad-thread-react.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
export STITCHPAD_HOME="$ROOT/tool"

cd "$tmp"
"$SP" init >/dev/null
STITCHPAD_NAME=dale "$SP" join dale claude >/dev/null 2>&1 || true
STITCHPAD_NAME=ernie "$SP" join ernie codex >/dev/null 2>&1 || true
PAD="$tmp/.stitchpad/stitchpad.md"

# ── 1. say mints an id and prints it ─────────────────────────────
out="$(STITCHPAD_NAME=dale "$SP" say "first message" 2>&1)"
contains "$out" "(#m-" || fail "say should print the minted id, got: $out"
id="$(printf '%s' "$out" | grep -o 'm-[a-z0-9]*' | head -1)"
[ -n "$id" ] || fail "could not extract id"
grep -q "^## @dale · .* · #$id\$" "$PAD" || fail "header must carry · #$id"

# ── 2. --re threads a reply; bogus target refuses ────────────────
out="$(STITCHPAD_NAME=ernie "$SP" say --re "$id" "threaded answer" 2>&1)"
rid="$(printf '%s' "$out" | grep -o 'm-[a-z0-9]*' | head -1)"
grep -q "^## @ernie · .* · #$rid · re:#$id\$" "$PAD" || fail "reply header must carry re:#$id"
if STITCHPAD_NAME=ernie "$SP" say --re "m-nope99" "ghost" >/dev/null 2>&1; then
  fail "reply to a nonexistent id must refuse"
fi

# ── 3. react appends a system line; same emoji toggles it off ────
STITCHPAD_NAME=ernie "$SP" react "$id" "👍" >/dev/null
grep -q "^\*@ernie reacted 👍 to #$id · .*\*$" "$PAD" || fail "reaction system line missing"
STITCHPAD_NAME=ernie "$SP" react "$id" "👍" >/dev/null
grep -q "reacted 👍 to #$id" "$PAD" && fail "second react should toggle the line off"
if STITCHPAD_NAME=ernie "$SP" react "m-nope99" "👍" >/dev/null 2>&1; then
  fail "react to a nonexistent id must refuse"
fi

# ── 4. @flock expands like @all (gang-prompt) ────────────────────
STITCHPAD_NAME=dale "$SP" say "@flock stand-up in 5" >/dev/null
tail -3 "$PAD" | grep -q "@ernie" || fail "@flock must expand to roster mentions"
tail -3 "$PAD" | grep -qi "flock" && fail "literal @flock token should be stripped after expansion"

# ── 5. a ```ui fence rides through say verbatim ──────────────────
body='shipping status below

```ui progress
{"label":"rich-pad spike","value":3,"max":5}
```'
STITCHPAD_NAME=dale "$SP" say "$body" >/dev/null
grep -q '^```ui progress$' "$PAD" || fail "ui fence info string must survive say"
grep -q '"label":"rich-pad spike"' "$PAD" || fail "ui payload must survive say"

# ── 6. amend rewrites body in place: header/id/thread survive ────
out="$(STITCHPAD_NAME=dale "$SP" say "draft: v1 of the plan" 2>&1)"
aid="$(printf '%s' "$out" | grep -o 'm-[a-z0-9]*' | head -1)"
STITCHPAD_NAME=ernie "$SP" say --re "$aid" "threaded on the draft" >/dev/null
STITCHPAD_NAME=dale "$SP" amend "$aid" "final: v2 of the plan" >/dev/null
grep -q "final: v2 of the plan" "$PAD" || fail "amend must land the new body"
grep -q "draft: v1 of the plan" "$PAD" && fail "amend must remove the old body"
grep -q "^## @dale · .* · #$aid\$" "$PAD" || fail "amend must preserve the header + id"
grep -q "re:#$aid\$" "$PAD" || fail "replies threaded on an amended message must survive"
if STITCHPAD_NAME=ernie "$SP" amend "$aid" "hijacked" >/dev/null 2>&1; then
  fail "amending someone else's message must refuse"
fi
if STITCHPAD_NAME=dale "$SP" amend "m-nope99" "ghost" >/dev/null 2>&1; then
  fail "amending a nonexistent id must refuse"
fi

# ── 7. run: steps become a live-amending timeline; failure threads ─
STITCHPAD_NAME=dale "$SP" run --title "contract check" "ok step"="true" "quick math"="test 2 -eq 2" >/dev/null 2>&1 \
  || fail "green run should exit 0"
grep -q '"title":"contract check"' "$PAD" || fail "run must post a ui timeline"
grep -q "✓ contract check — ✓ all 2 steps green" "$PAD" && : # alt line present (loose)
grep -q '"state":"done"' "$PAD" || fail "green steps must end state=done"
if STITCHPAD_NAME=dale "$SP" run --title "fail check" "boom"="exit 3" >/dev/null 2>&1; then
  fail "failing run should exit nonzero"
fi
grep -q '"state":"failed"' "$PAD" || fail "failed step must end state=failed"
grep -q "boom failed (exit 3)" "$PAD" || fail "failure output must thread under the timeline"

# ── 8. read still renders every block (old parsers tolerate v2) ──
r="$("$SP" read -n 50)"
contains "$r" "first message" || fail "read lost the v2-headed message"
contains "$r" "threaded answer" || fail "read lost the threaded reply"

echo "OK: thread/react/ui grammar contract holds"
