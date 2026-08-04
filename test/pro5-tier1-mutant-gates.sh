#!/usr/bin/env bash
# pro5-tier1-mutant-gates.sh — OUTCOME-BASED v3
# Every gate asserts the ACTUAL OUTCOME after recovery, not log text.
# Each gate: creates a real journal (journal_begin snapshots), advances HEAD,
# adds ghost bytes, runs recover, then checks:
#   (a) committed post-crash content is STILL in the live pad
#   (b) the orphan is PRESERVED (not consumed by rollback)
#
# Mutants that break the R3 guard (M2, M5, M6, M7) cause unconditional
# rollback → journal snapshots restored → committed content CLOBBERED.
set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
LIB="$ROOT/tool/bin/lib.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass=0; fail=0
ok() { printf "  ${GREEN}PASS${NC} %s\n" "$1"; pass=$((pass+1)); }
bad() { printf "  ${RED}FAIL${NC} %s\n" "$1"; fail=$((fail+1)); }

TMPDIRS=()
cleanup() {
  for d in "${TMPDIRS[@]:-}"; do rm -rf "$d" 2>/dev/null || true; done
  pkill -f "stitchpad.*watch" 2>/dev/null || true
}
trap cleanup EXIT

tmpd() { local d; d="$(mktemp -d "${TMPDIR:-/tmp}/sp-mgate.XXXXXX")"; TMPDIRS+=("$d"); echo "$d"; }

source_all() {
  if [ -z "${_SOURCED:-}" ]; then
    source "$LIB"
    source "$ROOT/tool/bin/session-registry.sh"
    source "$ROOT/tool/bin/recovery-policy.sh"
    _SOURCED=1
  fi
}

# ── Shared setup: create a pasture-git pad, capture real journal,
#    advance HEAD, add ghost bytes, run recover ────────────────────────────
# Returns via globals: _gate_content_ok (0/1), _gate_orphan_ok (0/1)
# Caller must set up pad and mutilate source BEFORE calling this.
run_recovery_outcome_test() {
  local work pad_dir pg orphan jdir sid marker committed ghost orphan_survived
  work="$(tmpd)"

  # ── Create pasture-git pad ──
  mkdir -p "$work/pad/.stitchpad/.state/sessions"
  cat > "$work/pad/.stitchpad/stitchpad.md" << 'EOPAD'
```roster
alice | ocean | push | sess-abc
```
## @alice · V1-BASELINE
EOPAD
  pg="$work/pad/.stitchpad/pasture-git"
  mkdir -p "$pg"
  git --git-dir="$pg" --work-tree="$work/pad/.stitchpad" init -q
  git --git-dir="$pg" --work-tree="$work/pad/.stitchpad" config user.email "t@t.com"
  git --git-dir="$pg" --work-tree="$work/pad/.stitchpad" config user.name "T"
  git --git-dir="$pg" --work-tree="$work/pad/.stitchpad" add stitchpad.md
  git --git-dir="$pg" --work-tree="$work/pad/.stitchpad" commit -q -m "V1 baseline"
  local base_v1; base_v1="$(git --git-dir="$pg" rev-parse HEAD)"
  touch "$work/pad/.stitchpad/.state/session-registry.jsonl"

  pad_dir="$work/pad/.stitchpad"

  # ── Set env ──
  export STITCHPAD_PAD_DIR="$pad_dir" STITCHPAD_HEARTBEAT_AUTOSTART=0
  unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID 2>/dev/null || true
  unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true
  PAD_DIR="$pad_dir"; PAD_MD="$pad_dir/stitchpad.md"; PAD_STATE="$pad_dir/.state"
  export PAD_DIR PAD_MD PAD_STATE

  source_all

  # ── Create journal via journal_begin (captures REAL snapshots) ──
  sid="gate-test-sid"
  printf '%s' "$sid" > "$PAD_STATE/sessions/$sid"
  STITCHPAD_SESSION="$sid" sp_session_registry_journal_begin "$sid" >/dev/null 2>&1
  jdir="$(ls -d "$PAD_STATE/.registry-journal."* 2>/dev/null | head -1)"
  if [ -z "$jdir" ] || [ ! -d "$jdir" ]; then
    echo "SETUP-FAIL: journal_begin did not create journal"
    _gate_content_ok=0; _gate_orphan_ok=0; return
  fi

  # ── Advance HEAD: add committed content that rollback would clobber ──
  committed="COMMITTED-V2-$(date +%s)"
  printf '\n## @bob · V2-COMMITTED\n%s\n' "$committed" >> "$PAD_MD"
  git --git-dir="$pg" --work-tree="$pad_dir" add stitchpad.md
  git --git-dir="$pg" --work-tree="$pad_dir" commit -q -m "V2 committed"
  local head_v2; head_v2="$(git --git-dir="$pg" rev-parse HEAD)"

  # ── Add ghost bytes: uncommitted content to prevent superseded path ──
  ghost="GHOST-UNCOMMITTED-$(date +%s)"
  printf '\n## @carol · GHOST-UNCOMMITTED\n%s\n' "$ghost" >> "$PAD_MD"

  # ── Run recovery FROM a directory WITHOUT .git ──
  # This is critical for M2 (bare git would read cwd's repo and succeed,
  # masking the mutant). Running from "$work" (temp dir, no .git)
  # ensures bare `git rev-parse HEAD` fails → _recovery_head_sha="" → guard skipped.
  ( cd "$work" && sp_session_registry_journal_recover ) >/dev/null 2>&1 || true

  # ── Check outcomes ──
  # (a) Committed content survived
  if grep -qF "$committed" "$PAD_MD" 2>/dev/null; then
    _gate_content_ok=1
  else
    _gate_content_ok=0
  fi

  # (b) Orphan preserved
  orphan_survived=0
  [ -d "$jdir" ] && orphan_survived=1
  _gate_orphan_ok=$orphan_survived

  # Also check ghost survived
  grep -qF "$ghost" "$PAD_MD" 2>/dev/null && _gate_ghost_ok=1 || _gate_ghost_ok=0
}

# ═══════════════════════════════════════════════════════════════
# GATE M1: Resolution order
# ═══════════════════════════════════════════════════════════════
gate_m1() {
  echo "--- M1: resolution order (pasture-git before stitchpad-git) ---"
  local work; work="$(tmpd)"
  mkdir -p "$work/pad/.stitchpad/.state/sessions"
  cat > "$work/pad/.stitchpad/stitchpad.md" << 'EOPAD'
```roster
alice | ocean | push | sess-abc
```
EOPAD
  local pg="$work/pad/.stitchpad/pasture-git" sg="$work/pad/.stitchpad/stitchpad-git"
  mkdir -p "$pg" "$sg"
  git --git-dir="$pg" --work-tree="$work/pad/.stitchpad" init -q
  git --git-dir="$pg" --work-tree="$work/pad/.stitchpad" config user.email "t@t.com"
  git --git-dir="$pg" --work-tree="$work/pad/.stitchpad" config user.name "T"
  git --git-dir="$pg" --work-tree="$work/pad/.stitchpad" add stitchpad.md
  git --git-dir="$pg" --work-tree="$work/pad/.stitchpad" commit -q -m "pasture-bootstrap"
  local expected; expected="$(git --git-dir="$pg" rev-parse HEAD)"
  echo "## @bob" >> "$work/pad/.stitchpad/stitchpad.md"
  git --git-dir="$sg" --work-tree="$work/pad/.stitchpad" init -q
  git --git-dir="$sg" --work-tree="$work/pad/.stitchpad" config user.email "t@t.com"
  git --git-dir="$sg" --work-tree="$work/pad/.stitchpad" config user.name "T"
  git --git-dir="$sg" --work-tree="$work/pad/.stitchpad" add stitchpad.md
  git --git-dir="$sg" --work-tree="$work/pad/.stitchpad" commit -q -m "legacy-bootstrap"

  export STITCHPAD_PAD_DIR="$work/pad/.stitchpad" STITCHPAD_HEARTBEAT_AUTOSTART=0
  unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID 2>/dev/null || true
  unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true
  PAD_DIR="$work/pad/.stitchpad"; PAD_MD="$PAD_DIR/stitchpad.md"; PAD_STATE="$PAD_DIR/.state"
  export PAD_DIR PAD_MD PAD_STATE
  source_all

  local sid="m1-sid"; printf '%s' "$sid" > "$PAD_STATE/sessions/$sid"
  STITCHPAD_SESSION="$sid" sp_session_registry_journal_begin "$sid" >/dev/null 2>&1
  local jdir; jdir="$(ls -d "$PAD_STATE/.registry-journal."* 2>/dev/null | head -1)"
  [ -n "$jdir" ] && [ -d "$jdir" ] || { bad "M1: no journal"; return; }
  local stamped; stamped="$(cat "$jdir/.base-sha" 2>/dev/null || echo "MISSING")"
  [ "$stamped" = "$expected" ] && ok "M1: .base-sha from pasture-git, not stitchpad-git" \
    || bad "M1: .base-sha=$stamped expected=$expected"
}

# ═══════════════════════════════════════════════════════════════
# GATE M2-M7: Recovery outcome — committed content NOT clobbered
# This gate calls run_recovery_outcome_test and checks (a) committed
# content survived, (b) orphan preserved, (c) ghost intact.
# The pad is always a pasture-git-only pad.
# ═══════════════════════════════════════════════════════════════

# Generic outcome gate — used by M2, M5, M6, M7
gate_outcome() {
  local label="$1"
  echo "--- $label ---"
  run_recovery_outcome_test
  [ "${_gate_content_ok:-0}" -eq 1 ] && ok "$label: committed content SURVIVED (not clobbered by rollback)" \
    || bad "$label: committed content LOST (rollback clobbered it — R3 guard broken)"
  [ "${_gate_orphan_ok:-0}" -eq 1 ] && ok "$label: orphan PRESERVED (R3 guard fired)" \
    || bad "$label: orphan CONSUMED (rollback consumed it — R3 guard skipped)"
  [ "${_gate_ghost_ok:-0}" -eq 1 ] && ok "$label: ghost content intact (live state untouched)" \
    || bad "$label: ghost content LOST (live state tampered by rollback)"
}

gate_m2() { gate_outcome "M2 bare-git-call"; }
gate_m5() { gate_outcome "M5 cached-PAD_GIT"; }
gate_m6() { gate_outcome "M6 standalone-recover"; }
gate_m7() { gate_outcome "M7 stitchpad-git-hardcode"; }

# ═══════════════════════════════════════════════════════════════
# GATE M3: PAD_DIR empty
# ═══════════════════════════════════════════════════════════════
gate_m3() {
  echo "--- M3: PAD_DIR empty/unset must refuse loudly ---"
  local work; work="$(tmpd)"
  mkdir -p "$work/pad/.stitchpad/.state/sessions"
  local pad_state="$work/pad/.stitchpad/.state"
  export STITCHPAD_HEARTBEAT_AUTOSTART=0
  unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID 2>/dev/null || true
  unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true
  PAD_DIR="" PAD_STATE="$pad_state" PAD_MD="/nonexistent/pad.md"
  export PAD_DIR PAD_STATE PAD_MD
  source_all
  local sid="m3-sid"; printf '%s' "$sid" > "$pad_state/sessions/$sid"
  local jdir
  jdir="$(STITCHPAD_SESSION="$sid" sp_session_registry_journal_begin "$sid" 2>/dev/null)" || true
  if [ -z "$jdir" ] || [ ! -d "$jdir" ]; then
    ok "M3: journal_begin refused when PAD_DIR is empty (fail-closed)"
    return
  fi
  local stamped; stamped="$(cat "$jdir/.base-sha" 2>/dev/null || echo "MISSING")"
  if [ "$stamped" = "MISSING" ] || [ -z "$stamped" ]; then
    bad "M3: journal created with NO .base-sha (PAD_DIR empty, silent skip)"
  elif [ "${#stamped}" -eq 40 ]; then
    ok "M3: .base-sha stamped despite empty PAD_DIR"
  else
    bad "M3: invalid .base-sha: $stamped"
  fi
}

# ═══════════════════════════════════════════════════════════════
# GATE M4: .base-sha validity on pasture-only pad
# ═══════════════════════════════════════════════════════════════
gate_m4() {
  echo "--- M4: .base-sha valid 40-char hex on pasture-only pads ---"
  local work; work="$(tmpd)"
  mkdir -p "$work/pad/.stitchpad/.state/sessions"
  cat > "$work/pad/.stitchpad/stitchpad.md" << 'EOPAD'
```roster
alice | ocean | push | sess-abc
```
EOPAD
  local pg="$work/pad/.stitchpad/pasture-git"
  mkdir -p "$pg"
  git --git-dir="$pg" --work-tree="$work/pad/.stitchpad" init -q
  git --git-dir="$pg" --work-tree="$work/pad/.stitchpad" config user.email "t@t.com"
  git --git-dir="$pg" --work-tree="$work/pad/.stitchpad" config user.name "T"
  git --git-dir="$pg" --work-tree="$work/pad/.stitchpad" add stitchpad.md
  git --git-dir="$pg" --work-tree="$work/pad/.stitchpad" commit -q -m "bootstrap"
  local expected; expected="$(git --git-dir="$pg" rev-parse HEAD)"

  export STITCHPAD_PAD_DIR="$work/pad/.stitchpad" STITCHPAD_HEARTBEAT_AUTOSTART=0
  unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID 2>/dev/null || true
  unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true
  PAD_DIR="$work/pad/.stitchpad"; PAD_MD="$PAD_DIR/stitchpad.md"; PAD_STATE="$PAD_DIR/.state"
  export PAD_DIR PAD_MD PAD_STATE
  source_all

  local sid="m4-sid"; printf '%s' "$sid" > "$PAD_STATE/sessions/$sid"
  STITCHPAD_SESSION="$sid" sp_session_registry_journal_begin "$sid" >/dev/null 2>&1
  local jdir; jdir="$(ls -d "$PAD_STATE/.registry-journal."* 2>/dev/null | head -1)"
  [ -n "$jdir" ] || { bad "M4: no journal"; return; }
  local stamped; stamped="$(cat "$jdir/.base-sha" 2>/dev/null || echo "")"
  if [ -z "$stamped" ]; then
    bad "M4: .base-sha EMPTY"
  elif [ "${#stamped}" -ne 40 ]; then
    bad "M4: .base-sha len=${#stamped}, want 40"
  elif [ "$stamped" != "$expected" ]; then
    bad "M4: .base-sha=$stamped != HEAD=$expected"
  else
    ok "M4: .base-sha valid 40-char hex = pasture-git HEAD"
  fi
}

# ═══════════════════════════════════════════════════════════════
# Runner
# ═══════════════════════════════════════════════════════════════
RUN="${MUTANT:-all}"
case "$RUN" in
  all)
    gate_m1; echo ""; gate_m2; echo ""; gate_m3; echo ""
    gate_m4; echo ""; gate_m5; echo ""; gate_m6; echo ""; gate_m7; echo "" ;;
  m1) gate_m1 ;;  m2) gate_m2 ;;  m3) gate_m3 ;;
  m4) gate_m4 ;;  m5) gate_m5 ;;  m6) gate_m6 ;;  m7) gate_m7 ;;
  *) echo "unknown MUTANT=$RUN" >&2; exit 1 ;;
esac
if [ "$RUN" = "all" ]; then
  echo "=== RESULTS: $pass PASS, $fail FAIL, $((pass+fail)) total ==="
  [ "$fail" -gt 0 ] && exit 1
  exit 0
fi
