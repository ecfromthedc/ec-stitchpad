#!/usr/bin/env bash
# stitchpad core library — sourced by every command/daemon/adapter.
# The whole system is: one markdown file (stitchpad.md) whose own header declares
# its roster, plus a generic watcher that fires each user's adapter on @mention.
#
# A pad is a directory with:
#   stitchpad.md   the markdown bus (roster block + messages)
#   stitchpad-git/ isolated git history (one commit per post)
#   .state/        runtime flags/counters/inboxes (gitignored)
#
# Roster lives INSIDE stitchpad.md as a fenced ```roster block:
#   name | adapter | wake | target
# wake = push (daemon spawns them) | pull (daemon flags+notifies; they read later)

set -uo pipefail

# ── PASTURE COMPAT (migration stage 1) ──────────────────────────────
# PASTURE_* env wins; STITCHPAD_* stays accepted until stage 4 retires it.
# Normalized ONCE here so every shell consumer keeps reading STITCHPAD_*.
for _pv_name in NAME SESSION PAD_DIR STEAL HOME CWD RELAY TOKEN PAD HANDLE INVITE \
                FORCE_BIND HEARTBEAT_INTERVAL HEARTBEAT_PARENT_PID HEARTBEAT_AUTOSTART \
                ALLOW_WHOAMI_FALLBACK MODEL PADS SUMMARIZER; do
  eval "_pv_val=\${PASTURE_${_pv_name}:-}"
  [ -n "$_pv_val" ] && eval "export STITCHPAD_${_pv_name}=\"\$_pv_val\""
done
unset _pv_name _pv_val

# STITCHPAD_HOME is the checkout's tool/ dir (holds bin/ + adapters/). If the
# caller already resolved BIN_DIR (via the symlink-safe header), derive HOME from
# it so install-by-symlink works without anyone exporting STITCHPAD_HOME.
if [ -z "${STITCHPAD_HOME:-}" ] && [ -n "${BIN_DIR:-}" ]; then
  STITCHPAD_HOME="$(cd -P "$BIN_DIR/.." && pwd)"
fi
STITCHPAD_HOME="${STITCHPAD_HOME:-$HOME/.stitchpad}"
ADAPTER_DIR="$STITCHPAD_HOME/adapters"

# ── Pad resolution ──────────────────────────────────────────────────
# Find the pad dir: explicit $PAD_DIR, else nearest .stitchpad up the tree.
sp_find_pad() {
  if [ -n "${PAD_DIR:-}" ]; then echo "$PAD_DIR"; return; fi
  local d="${1:-$PWD}"
  while [ "$d" != "/" ]; do
    [ -d "$d/.pasture" ] && { echo "$d/.pasture"; return; }     # migrated pad wins
    [ -d "$d/.stitchpad" ] && { echo "$d/.stitchpad"; return; } # legacy accepted
    d="$(dirname "$d")"
  done
  return 1
}

# Keep the entire pad out of the surrounding project's Git worktree. The pad
# has its own isolated Git history; if the outer repo sees stitchpad.md as an
# untracked file, `git stash -u` temporarily removes it while live writers keep
# running and can recreate a headerless pad. Use info/exclude so existing repos
# become safe without requiring a tracked .gitignore edit.
sp_ensure_outer_git_ignore() {
  local proj prefix exclude pattern
  proj="$(dirname "$PAD_DIR")"
  git -C "$proj" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  prefix="$(git -C "$proj" rev-parse --show-prefix 2>/dev/null || true)"
  exclude="$(git -C "$proj" rev-parse --git-path info/exclude 2>/dev/null || true)"
  [ -n "$exclude" ] || return 0
  case "$exclude" in /*) ;; *) exclude="$proj/$exclude" ;; esac
  pattern="/${prefix}.stitchpad/"
  mkdir -p "$(dirname "$exclude")" 2>/dev/null || return 0
  grep -Fqx "$pattern" "$exclude" 2>/dev/null || printf '\n# stitchpad runtime (isolated history)\n%s\n' "$pattern" >> "$exclude"
}

sp_init_paths() {
  # Resolution order for which pad we operate on:
  #   1. explicit arg ($1)            — caller passed a dir
  #   2. STITCHPAD_PAD_DIR env        — pin a pad regardless of cwd (daemons/hooks)
  #   3. $PWD                         — the pad under the current directory
  # Without #2, a watcher/daemon launched from the wrong cwd silently watched the
  # wrong pad (ocean-os's watcher latched onto stitchpad-live). Honor the pin.
  PAD_DIR="$(sp_find_pad "${1:-${STITCHPAD_PAD_DIR:-$PWD}}")" || { echo "no pasture found (run: pasture init)" >&2; return 1; }
  # migrated pads carry pasture.md/pasture-git; legacy names accepted until stage 4
  if [ -f "$PAD_DIR/pasture.md" ]; then PAD_MD="$PAD_DIR/pasture.md"; else PAD_MD="$PAD_DIR/stitchpad.md"; fi
  if [ -d "$PAD_DIR/pasture-git" ]; then PAD_GIT="$PAD_DIR/pasture-git"; else PAD_GIT="$PAD_DIR/stitchpad-git"; fi
  PAD_STATE="$PAD_DIR/.state"
  # Task cards live in a SIBLING file so a `task move` never rewrites (or
  # commits) the whole conversation. Legacy inline ```task blocks in the pad are
  # still read — see sp_tasks() — so existing pads keep working untouched.
  PAD_TASKS="$PAD_DIR/tasks.md"
  PAD_ARCHIVE_DIR="$PAD_DIR/archive"
  mkdir -p "$PAD_STATE/sessions"
  # Replay an in-place rewrite that was interrupted between truncate and write.
  sp_recover_inplace "$PAD_MD"
  sp_recover_inplace "$PAD_TASKS"
  sp_ensure_outer_git_ignore
  # Pad git is load-bearing (read --new deltas, say auto-commits, compaction
  # audit trail) but NOTHING ever initialized it — sp_commit just no-ops when
  # it's absent, so a pad without it degrades silently. Self-heal on first use.
  if [ ! -d "$PAD_GIT" ] && [ -f "$PAD_MD" ] && command -v git >/dev/null 2>&1; then
    git --git-dir="$PAD_GIT" --work-tree="$PAD_DIR" init -q 2>/dev/null || true
    git --git-dir="$PAD_GIT" --work-tree="$PAD_DIR" add stitchpad.md 2>/dev/null || true
    git --git-dir="$PAD_GIT" --work-tree="$PAD_DIR" -c user.name=stitchpad -c user.email=pad@local \
      commit -q -m "bootstrap: pad git (re)initialized" 2>/dev/null || true
  fi
}

# ── Identity ─────────────────────────────────────────────────────────
# Identity is bound to the agent's SESSION, declared once via the MCP `join` tool
# (which calls `stitchpad bind-session <id> <name>`, writing .state/sessions/<id>).
# Resolution order — SESSION BINDING WINS:
#   1. .state/sessions/$STITCHPAD_SESSION   (the durable identity bound at join)
#   2. explicit STITCHPAD_NAME              (fallback when no session binding)
# The session binding is checked FIRST so a STALE STITCHPAD_NAME left in the shell
# (e.g. a session that re-joined under a new handle but whose shell still exports the
# OLD name) cannot override the real identity. This is the @Jill→@deepseek bug: the
# session rebound to deepseek but the shell still had STITCHPAD_NAME=Jill, so every
# post was mis-stamped @Jill. Session id is the source of truth; env name is a hint.
sp_me() {
  # Session binding wins. Prefer the explicit STITCHPAD_SESSION, but fall back to
  # the runtime's own session id ($CLAUDE_CODE_SESSION_ID) when the shell never
  # exported STITCHPAD_SESSION — that gap is exactly what let a stale STITCHPAD_NAME
  # leak through and mis-stamp posts (@Jill bug). Try both before trusting the name.
  local sid="${STITCHPAD_SESSION:-${CLAUDE_CODE_SESSION_ID:-}}"
  if [ -n "$sid" ] && [ -f "$PAD_STATE/sessions/$sid" ]; then
    local _bound; _bound="$(cat "$PAD_STATE/sessions/$sid" 2>/dev/null)"
    # Binding wins (kills the stale-STITCHPAD_NAME @Jill bug). But if the live
    # invocation ALSO declared a different STITCHPAD_NAME, the binding may be a
    # cross-bind (the @codex bleed): surface it loudly so it's not silent.
    if [ -n "${STITCHPAD_NAME:-}" ] && [ -n "$_bound" ] && [ "$_bound" != "$STITCHPAD_NAME" ]; then
      echo "stitchpad: WARNING — session $sid is bound to @$_bound but STITCHPAD_NAME=@$STITCHPAD_NAME." >&2
      echo "  Posting as @$_bound (binding wins). If wrong, rebind: STITCHPAD_FORCE_BIND=1 stitchpad bind-session $sid $STITCHPAD_NAME" >&2
    fi
    echo "$_bound"; return
  fi
  if [ -n "${STITCHPAD_NAME:-}" ]; then echo "$STITCHPAD_NAME"; return; fi
  # Herdr terminal resolution: a process in a managed pane can resolve its stable
  # terminal id and find the matching roster target without shared whoami state.
  local _surface_id="$(sp_this_surface)"
  if [ -n "$_surface_id" ]; then
    local _wname
    _wname="$(sp_roster | awk -F'|' -v w="$_surface_id" '
      { gsub(/^[ \t]+|[ \t]+$/, "", $1); gsub(/^[ \t]+|[ \t]+$/, "", $4)
        n=$4; sub(/.*@@/, "", n)
        if (n == w) { print $1; exit } }' 2>/dev/null)"
    if [ -n "$_wname" ]; then echo "$_wname"; return; fi
  fi
  # Last-resort pad default is intentionally opt-in. A shared whoami file can
  # collapse multiple agents into whoever joined last (for example, everyone
  # posting as @nancy). Prefer explicit STITCHPAD_NAME, STITCHPAD_SESSION, or
  # Herdr terminal resolution; fail closed instead of misattributing work.
  if [ "${STITCHPAD_ALLOW_WHOAMI_FALLBACK:-0}" = "1" ]; then
    cat "$PAD_STATE/whoami" 2>/dev/null || true
  fi
}

# Resolve identity from the bound session only. Used by the Stop hook so a stale
# STITCHPAD_NAME in the runtime env cannot override the session mapping.
sp_session_name() {
  [ -n "${PAD_STATE:-}" ] || return 0
  local sid="${STITCHPAD_SESSION:-${CLAUDE_CODE_SESSION_ID:-}}"
  if [ -n "$sid" ] && [ -f "$PAD_STATE/sessions/$sid" ]; then
    cat "$PAD_STATE/sessions/$sid" 2>/dev/null || true
  fi
}

# ── Do Not Disturb ──────────────────────────────────────────────────
# DND is a local wake-suppression flag. It never mutates the pad or seen cursor:
# mentions accumulate behind .state/seen.<name> and can be drained on return.
sp_dnd_file() { printf '%s/dnd.%s\n' "$PAD_STATE" "$1"; }
sp_dnd_is_on() { [ -f "$(sp_dnd_file "$1")" ]; }

# ── Atomic pad mutation lock ─────────────────────────────────────────
# Multiple agents may say/join the same pad concurrently. stitchpad.md is mutated
# by bare appends (say) and read-rewrite (join); without serialization those race
# (interleaved lines / lost updates). mkdir is atomic on every POSIX fs, so we use
# a lock DIR as the mutex — no flock dependency (macOS lacks it). Auto-breaks a
# stale lock so a crashed writer can't wedge the pad forever.
SP_LOCK_TIMEOUT="${SP_LOCK_TIMEOUT:-5}"   # seconds to wait for the lock
SP_LOCK_STALE="${SP_LOCK_STALE:-30}"      # seconds before a held lock is "stale"
_SP_LOCK_DIR=""

sp_lock() {
  local lock="$PAD_STATE/.lock" waited=0
  while ! mkdir "$lock" 2>/dev/null; do
    # Break a stale lock (holder died without releasing).
    if [ -d "$lock" ]; then
      local age now mtime
      now=$(date +%s)
      mtime=$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo "$now")
      age=$(( now - mtime ))
      if [ "$age" -ge "$SP_LOCK_STALE" ]; then rmdir "$lock" 2>/dev/null || true; continue; fi
    fi
    waited=$(( waited + 1 ))
    [ "$waited" -ge $(( SP_LOCK_TIMEOUT * 10 )) ] && { echo "stitchpad: pad busy (lock timeout)" >&2; return 1; }
    sleep 0.1
  done
  _SP_LOCK_DIR="$lock"
  # Release on any exit so a killed writer doesn't wedge the pad.
  trap 'sp_unlock' EXIT INT TERM
  return 0
}

sp_unlock() {
  [ -n "$_SP_LOCK_DIR" ] && rmdir "$_SP_LOCK_DIR" 2>/dev/null || true
  _SP_LOCK_DIR=""
}

# ── Inode-stable rewrites ────────────────────────────────────────────
# EVERY full-file rewrite used to end in `mv tmp pad`, which REPLACES the pad's
# inode. A `tail -f` / `tail -F` watcher then re-opens the new file and replays
# the ENTIRE pad as if it were new — 200 KB and 200+ messages arriving at once,
# every single time anyone ran `task move`. That silently broke live agent
# watchers (the operator's messages went unanswered for hours because the agent
# watching the pad drowned in replayed history and was killed).
#
# The cure is to write back over the SAME file, through the existing inode and
# WITHOUT truncating it first: `dd conv=notrunc` overwrites in place, and the
# file is shortened afterwards only when the new content is genuinely smaller.
# A reader therefore never sees the pad's size go backwards, which matters just
# as much as the inode: `tail` treats a shrink as "file truncated" and rewinds
# to offset 0, replaying everything all over again. Roster edits and task edits
# grow the file, so after this change they produce a delta and nothing more.
#
#   sp_stage <target>            → path to a staging file next to <target>
#   sp_write_inplace <staged> <target>
#       0 = written · 2 = identical, nothing written · 1 = failed, target intact
#   sp_recover_inplace <target>  → replay an interrupted write
#
# Crash-safety is preserved WITHOUT a rename over the pad. The staged file is a
# complete copy on disk; it is promoted to "<target>.ready" (a rename between
# two TEMP files — the pad is never the destination) and only then copied over
# the target. If the process dies mid-copy, "<target>.ready" survives with the
# full intended content and sp_recover_inplace() replays it on the next command.
# A half-written staging file is never promoted, so it can never be replayed.
sp_stage() {
  local target="${1:-$PAD_MD}"
  mktemp "$(dirname "$target")/.sp-stage.XXXXXX"
}

sp_write_inplace() {
  local staged="$1" target="$2" ready="$2.ready"
  # Never let a broken awk/sed pipeline truncate a live pad to nothing.
  if [ ! -s "$staged" ]; then
    echo "stitchpad: refusing to write an empty $(basename "$target") — staged write produced no content" >&2
    rm -f "$staged" 2>/dev/null
    return 1
  fi
  # No-op guard: identical content means no write, no mtime bump, no watcher
  # event and no commit churn. `task move X <same status>` is now free.
  if [ -f "$target" ] && cmp -s "$staged" "$target"; then
    rm -f "$staged" 2>/dev/null
    return 2
  fi
  mv -f "$staged" "$ready" 2>/dev/null || { rm -f "$staged" 2>/dev/null; return 1; }
  local newsize oldsize
  newsize="$(wc -c < "$ready" | tr -d ' ')"
  oldsize="$(wc -c < "$target" 2>/dev/null | tr -d ' ')"; oldsize="${oldsize:-0}"
  # THE fix: same inode, and no truncation — so no watcher rewinds.
  if dd if="$ready" of="$target" conv=notrunc bs=65536 2>/dev/null; then
    if [ "$newsize" -lt "$oldsize" ]; then
      # genuinely shorter (clear/compact/archive): drop the stale tail bytes
      perl -e 'truncate($ARGV[0], $ARGV[1]) or exit 1' "$target" "$newsize" 2>/dev/null \
        || cat "$ready" > "$target"
    fi
    rm -f "$ready" 2>/dev/null
    return 0
  fi
  echo "stitchpad: in-place write of $(basename "$target") failed — content preserved in $ready" >&2
  return 1
}

sp_recover_inplace() {
  local target="${1:-$PAD_MD}" ready
  [ -n "$target" ] || return 0
  ready="$target.ready"
  [ -s "$ready" ] || { rm -f "$ready" 2>/dev/null; return 0; }
  echo "stitchpad: recovering interrupted write of $(basename "$target")" >&2
  cat "$ready" > "$target" && rm -f "$ready" 2>/dev/null
  return 0
}

# Append a small italic system/presence line to the pad (join/leave, etc.).
# Not a message — no @sender — so it never trips mention detection or the gate.
sp_system() {
  local msg="$1" ts; ts="$(date '+%I:%M %p')"
  printf '\n*%s · %s*\n' "$msg" "$ts" >> "$PAD_MD"
}

# Isolated git wrapper: history of just stitchpad.md, separate from project repo.
sgit() { git --git-dir="$PAD_GIT" --work-tree="$PAD_DIR" "$@"; }

# The pad's isolated git ignores everything but the pad file (info/exclude is
# `*` + `!stitchpad.md`). tasks.md and archive/ are pad content too — un-ignore
# them so they are versioned alongside the conversation.
sp_ensure_pad_git_exclude() {
  local ex="$PAD_GIT/info/exclude" pat
  [ -d "$PAD_GIT" ] || return 0
  mkdir -p "$PAD_GIT/info" 2>/dev/null || return 0
  for pat in '!tasks.md' '!archive/' '!archive/**'; do
    grep -Fqx "$pat" "$ex" 2>/dev/null || printf '%s\n' "$pat" >> "$ex"
  done
}

# sp_commit <msg> [path...]  — paths are relative to the pad dir; defaults to
# the pad file. Passing paths lets a task-only or archive-only change commit
# just that file instead of the whole conversation.
sp_commit() {
  local msg="$1"; shift 2>/dev/null || true
  local paths=("$@")
  [ "${#paths[@]}" -eq 0 ] && paths=("$(basename "$PAD_MD")")
  sgit rev-parse --git-dir >/dev/null 2>&1 || return 0
  # Never turn a transient outer-repo stash/clean window into a durable pad
  # deletion. Stage first so a file recreated after an older deletion is not
  # invisible as "untracked" to `git diff`, then inspect the staged delta.
  [ -f "$PAD_MD" ] || return 0
  sp_ensure_pad_git_exclude
  sgit add -A -f -- "${paths[@]}" 2>/dev/null || return 0
  sgit diff --cached --quiet -- "${paths[@]}" 2>/dev/null && return 0
  sgit commit -q -m "$msg" 2>/dev/null || true
}

# ── Roster parsing (the magic: roster is IN the markdown) ────────────
# Emits "name|adapter|wake|target" per participant from the ```roster fence.
sp_roster() {
  awk '
    /^```roster/ { inblk=1; next }
    /^```/       { inblk=0 }
    inblk {
      line=$0
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line == "" || line ~ /^#/) next
      n=split(line, f, /[ \t]*\|[ \t]*/)
      if (n>=2) {
        name=f[1]; adapter=f[2];
        # crews annotate models as a 3rd column (name|adapter|MODEL|wake|target)
        # — tolerate it: if col3 is not a wake mode, shift wake/target right.
        # (The ocean-os crew invented this and the strict parser read "push" as
        # a TERMINAL ID, minting a lock literally named push — never again.)
        if (n>=5 && f[3] !~ /^(push|pull)$/) { wake=f[4]; target=f[5] }
        else { wake=(n>=3?f[3]:"pull"); target=(n>=4?f[4]:"-") }
        gsub(/^[ \t]+|[ \t]+$/, "", name)
        print name "|" adapter "|" wake "|" target
      }
    }
  ' "$PAD_MD"
}

# Roster filtered to LIVE sessions: an agent is shown only if its heartbeat
# (alive.<name>, mtime < 90s) is fresh — same liveness rule as sp_any_alive.
# A session that closed without leaving simply stops appearing; no graveyard.
# Operators/humans have no heartbeat and are always kept (they read, not woken).
sp_roster_live() {
  local now; now=$(date +%s)
  sp_roster | while IFS='|' read -r name adapter wake target; do
    [ -n "$name" ] || continue
    local rt; rt="$(cat "$PAD_STATE/runtime.$name" 2>/dev/null || true)"
    if [ "$rt" = "operator" ] || [ "$rt" = "human" ]; then
      printf '%s|%s|%s|%s\n' "$name" "$adapter" "$wake" "$target"; continue
    fi
    local hb="$PAD_STATE/alive.$name" ts
    [ -f "$hb" ] || continue
    ts=$(stat -f %m "$hb" 2>/dev/null || stat -c %Y "$hb" 2>/dev/null || echo 0)
    [ $(( now - ts )) -lt 90 ] || continue
    printf '%s|%s|%s|%s\n' "$name" "$adapter" "$wake" "$target"
  done
}

# ── Tasks parser (```task blocks) ────────────────────────────────────────
# Each task is a ```task TASK-N fenced block with YAML-like frontmatter and
# a markdown description after the --- separator.
#
# Output: id|title|status|priority|assignee|labels|created
#
# sp_tasks                → all tasks in created order
# sp_tasks --mine <name>  → tasks assigned to <name>
# sp_tasks --status <s>    → tasks with matching status
#
# BACKWARD COMPATIBILITY: tasks are read from the pad AND from the sibling
# tasks.md. Old pads with inline ```task blocks keep working with no migration;
# new tasks are written to tasks.md. tasks.md is read LAST so a migrated card
# wins over a stale inline copy of the same id (the parser is last-wins).
sp_task_files() {
  local out=("$PAD_MD")
  [ -n "${PAD_TASKS:-}" ] && [ -f "$PAD_TASKS" ] && out+=("$PAD_TASKS")
  printf '%s\n' "${out[@]}"
}

# Which file holds <id>? tasks.md wins. Prints the path, or fails if unknown —
# so `task move` on a typo'd id errors instead of rewriting the whole pad.
sp_task_file() {
  local id="$1" f
  for f in "${PAD_TASKS:-}" "$PAD_MD"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    if awk -v tid="$id" '$1=="```task" && $2==tid { found=1; exit } END { exit !found }' "$f"; then
      printf '%s' "$f"; return 0
    fi
  done
  return 1
}

sp_tasks() {
  local filter_name="" filter_status=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --mine)   filter_name="$2"; shift 2 ;;
      --status) filter_status="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  local _tf=(); while IFS= read -r _f; do _tf+=("$_f"); done < <(sp_task_files)
  awk -v fn="$filter_name" -v fs="$filter_status" '
    BEGIN { id=""; title=""; status=""; priority=""; assignee=""; labels=""; created=""; desc="" }
    # multiple inputs (pad + tasks.md): never let an unterminated block in one
    # file bleed into the next
    FNR==1                           { inblk=0; meta=0; id="" }
    /^```task /                      { inblk=1; meta=1; id=$2; gsub(/^ *| *$/,"",id); title=""; status="todo"; priority="none"; assignee=""; labels=""; created=""; desc="" }
    /^```$/ && inblk                 { inblk=0; if (id!="") {
      # duplicate blocks (compact-carried copies, re-posts): LAST occurrence wins
      if (!(id in seen)) { order[++nord]=id; seen[id]=1 }
      data[id] = id "|" title "|" status "|" priority "|" assignee "|" labels "|" created "|" substr(desc, 1, 240)
      fa[id]=assignee; fst[id]=status; id="" } }
    inblk && /^---/                   { meta=0; next }
    inblk && !meta && !/^```/ {
      line=$0; gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line != "") desc = (desc == "" ? line : desc " / " line)
    }
    inblk && meta && !/^```/ {
      line=$0; gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line ~ /^title:/)    { gsub(/^title: */, "", line); title=line }
      if (line ~ /^status:/)   { gsub(/^status: */, "", line); status=line }
      if (line ~ /^priority:/) { gsub(/^priority: */, "", line); priority=line }
      if (line ~ /^assignee:/) { gsub(/^assignee: */, "", line); assignee=line }
      if (line ~ /^labels:/)   { gsub(/^labels: */, "", line); labels=line }
      if (line ~ /^created:/)  { gsub(/^created: */, "", line); created=line }
    }
    END { for (i=1; i<=nord; i++) { k=order[i]
      if ((fn=="" || fa[k]==fn) && (fs=="" || fst[k]==fs)) print data[k] } }
  ' "${_tf[@]}"
}

# Create tasks.md (with its header) if it does not exist yet. Callers hold the lock.
sp_ensure_tasks_file() {
  [ -n "${PAD_TASKS:-}" ] || return 1
  [ -f "$PAD_TASKS" ] && return 0
  cat > "$PAD_TASKS" <<'TASKSEOF'
# 📋 tasks

> Task cards for this pad, split out of the conversation so that creating or
> moving a ticket no longer rewrites (and re-commits) the whole transcript.
> Format is unchanged: one ```task TASK-N fenced block per ticket.
>
> Legacy inline ```task blocks still in the pad are read too — run
> `stitchpad task migrate` to move them here.

TASKSEOF
}

# Leave ONE pointer in the pad so every reader (and the phone bridge, which only
# ships the pad) knows where the board went. Idempotent: the marker means done.
# Callers hold the lock.
sp_ensure_tasks_pointer() {
  [ -f "$PAD_MD" ] || return 0
  grep -Fq '<!-- tasks:file -->' "$PAD_MD" 2>/dev/null && return 0
  local base tmp
  base="$(basename "$PAD_TASKS")"
  if grep -q '^## Tasks' "$PAD_MD" 2>/dev/null; then
    tmp="$(sp_stage "$PAD_MD")"
    awk -v base="$base" '
      { print }
      !stamped && /^## Tasks/ {
        print ""
        print "<!-- tasks:file -->"
        print "> 📋 Task cards live in `" base "` beside this pad. `stitchpad task list|new|move|edit` reads and writes there, so a ticket update no longer rewrites this conversation. Legacy task blocks left below are still read."
        stamped=1
      }
    ' "$PAD_MD" > "$tmp"
    sp_write_inplace "$tmp" "$PAD_MD"
  else
    # No Tasks section: append (cheap, tail-safe — an append never moves bytes
    # a watcher already read).
    {
      printf '\n## Tasks\n\n<!-- tasks:file -->\n'
      printf '> 📋 Task cards live in `%s` beside this pad. `stitchpad task list|new|move|edit` reads and writes there.\n' "$base"
    } >> "$PAD_MD"
  fi
  return 0
}

# Look up one field for a user. sp_user_field <name> <adapter|wake|target>
sp_user_field() {
  local who="$1" field="$2"
  sp_roster | awk -F'|' -v w="$who" -v f="$field" '
    tolower($1)==tolower(w) {
      if (f=="adapter") print $2;
      else if (f=="wake") print $3;
      else if (f=="target") print $4;
      exit
    }'
}

sp_user_exists() { [ -n "$(sp_user_field "$1" adapter)" ]; }

# ── @mention detection ───────────────────────────────────────────────
# Count lines in the pad addressed TO <name> (a line starting with @name). Used
# by the watcher to detect when a NEW mention has landed (count went up).
sp_count_to() {
  local who="$1" file="${2:-$PAD_MD}" n
  # @all is a broadcast — it counts as a mention TO everyone.
  n=$(grep -icE "(^|[^a-z0-9_-])@(${who}|all)([^a-z0-9_-]|$)" "$file" 2>/dev/null) || true
  echo "${n:-0}"
}

# Extract the latest message block addressed to <name>: from the last "## "
# header owning an @name mention, up to the next "## " header. Mentions can be
# inline ("dale @larry ..."), but must respect handle boundaries.
sp_latest_to() {
  local who="$1"
  local since="${2:-0}"  # skip mentions with ordinal <= since (FIFO cursor)
  awk -v who="$who" -v since="$since" '
    BEGIN { mention = "(^|[^a-z0-9_-])@" tolower(who) "([^a-z0-9_-]|$)" }
    # Only authored blocks (## @...) are candidates. Anonymous blocks like
    # ## Tasks or ## Summary are never wake sources. Track author for self-skip.
    /^## / {
      if (last && !end) end=NR-1
      sub_start=NR
      # Extract author: "## @name" blocks are authored; all others are anonymous.
      if ($2 ~ /^@/) { a=$2; sub(/^@/,"",a); author=tolower(a); n++ }
      else           { author="" }
    }
    { lines[NR]=$0 }
    # FIFO: find first block authored by someone ELSE mentioning <who>
    # with ordinal > since. Never overwrite — the wake cursor steps one
    # ordinal per delivery instead of jumping to the newest.
    !last && author != "" && author != tolower(who) && tolower($0) ~ mention && n > since {
      last=sub_start; end=0
    }
    END { if (!end) end=NR; if (last) for (i=last;i<=end;i++) print lines[i] }
  ' "$PAD_MD"
}

# Engagement gate derived from pad CONTENT, not git commit subjects. The watch.sh
# daemon auto-commits the pad as "update (HH:MM:SS)", which clobbers the authored
# "<name>: <text>" subject the old gate relied on — so git subjects are unreliable.
# The markdown is ground truth. Walks "## @author · time" blocks in order:
#   - a block authored by someone ELSE that @-mentions me  → a mention TO me
#   - a block authored by ME that @-mentions anyone else   → an addressed reply
# Prints "<last_mention_ordinal> <last_reply_ordinal>" (0 if none). Blocked iff
# last_mention > last_reply. Author-skip is built in: my own blocks never count as
# mentions to me, killing the self-ack loop too.
# Silent-ack convention: a block whose first content line starts with "." or "[ack]"
# is invisible to the gate — it neither wakes a mentioned target nor counts as an
# addressed reply. Lets agents post acknowledgements/status without costing anyone a
# wake. Sender opt-in, no content guessing.
sp_engagement() {
  local who="$1"
  local since="${2:-0}"  # skip mentions with ordinal <= since (FIFO cursor)
  # roster names, for the implicit-silent word list below: only AGENT authors get
  # their bare "ack"/"noted" posts silenced. A human operator typing "@pi ack"
  # means "wake pi" — guessing it silent made operator pings vanish (the pi bug).
  local agents
  agents="$(sp_roster 2>/dev/null | cut -d'|' -f1 | tr 'A-Z' 'a-z' | paste -sd, -)"
  awk -v who="$(printf '%s' "$1" | tr 'A-Z' 'a-z')" -v agents="$agents" -v since="$since" '
    # An ADDRESS is "@name" at line-start or after whitespace — NOT after punctuation
    # like / ` " (), so a quoted/referenced "@name" (e.g. "the @john/@dale discussion")
    # or a backticked `@name` does not count as addressing someone. buf joins lines with
    # a leading space, so (^|[ \t]) covers block-start, every line-start, and mid-sentence.
    function body_mentions(name,   re) { re="(^|[ \t])@(" name "|all)([^a-z0-9_-]|$)"; return (buf ~ re) }
    function flush() {
      if (author=="") return
      n++
      if (author==who) {                                          # my own block:
        if (silent || buf ~ /(^|[ \t])@[a-z0-9_-]/) {           # a silent ack OR a real @-address reply
          last_reply=n                                           # last reply ordinal
          # Try to extract the first @-target: the first non-who agent name address.
          # This is the sender we replied TO, used for same-sender gate narrowing.
          # PORTABLE: no gawk match()-with-array; uses substr + sub.
          split(buf, tokens, /[ \t\n]+/)
          for (i in tokens) {
            if (i > 20) break
            t = tolower(tokens[i])
            if (t ~ /^@[a-z0-9_-]+/) {
              name = substr(t, 2)
              sub(/[^a-z0-9_-].*$/, "", name)
              if (name != "" && name != "all" && name != who) { reply_target = name; break }
            }
          }
        }
      } else if (!silent && body_mentions(who)) {
        # FIFO cursor: record the FIRST mention after `since`, never overwrite.
        # The seen cursor steps one ordinal per delivery; this returns the next
        # unanswered mention instead of jumping to the newest.
        if (!last_mention && n > since) { last_mention=n; mention_sender=author }
      }
    }
    /^## @/ {
      flush()
      a=$2; sub(/^@/,"",a); author=tolower(a); buf=""; silent=0; seen_body=0; infence=0
      next
    }
    # A fenced code block (``` toggles) is never an address — doctor output, diffs and
    # code paste "@name" listings (e.g. "✓ @dale — healthy") must not wake anyone. The
    # fence lines themselves and their contents are excluded from the mention buffer.
    /^[[:space:]]*```/ { infence = !infence; next }
    infence { next }
    # first non-empty content line decides silent-ack (leading "." or "[ack]")
    !seen_body && /[^[:space:]]/ {
      seen_body=1
      b=tolower($0); sub(/^[ \t]*/,"",b)
      # count @mentions before stripping; 2+ means broadcast — never silent
      n_at=0; tmp=b; while (match(tmp,/@[a-z0-9_-]+/)) { n_at++; tmp=substr(tmp,RSTART+RLENGTH) }
      sub(/^(@[a-z0-9_-]+[ \t]*)+/,"",b); sub(/[ \t]+$/,"",b)
      if (n_at < 2) {
        if (b ~ /^(\.|\[ack\])/) silent=1   # explicit opt-in: silent for anyone
        # implicit word-list: agents only — an operator addressing an agent always wakes it
        if (index("," agents ",", "," author ",") > 0 && b ~ /^(ack|read|noted|got it|standing down|standing by|stand by|will do|understood|done here|copy|sounds good)[. !]*$/) silent=1
      }
    }
    # Strip inline code (`...`) before appending to buffer — prevents `@name` in code
    # snippets from counting as an address. Real addresses survive because only the
    # backtick-delimited content is blanked, not the surrounding text.
    { line = tolower($0); gsub(/`[^`]*`/, " ", line); buf = buf " " line }
    END { flush(); print (last_mention+0) " " (mention_sender) " " (last_reply+0) " " (reply_target) }
  ' "$PAD_MD"
}

# ── Terminal-identity locks (machine-global) ─────────────────────────
# ONE TERMINAL = ONE (pad, name). ~/.stitchpad-terminals/<surface_id> holds
# "pad_dir|name|epoch" (pad_dir = the .stitchpad dir). join/set-wake CLAIM the
# terminal, heartbeats refresh the claim, leave releases it; wake delivery,
# DM routing and the MCP server all consult it. This is the wall that stops
# two pads from cross-wiring into the same terminal: a terminal freshly bound
# to pad A cannot be claimed by pad B, addressed by pad B's wakes, or used to
# post into pad B, unless the operator explicitly steals it (STITCHPAD_STEAL=1)
# or the old claim goes stale (>300s without a heartbeat).
# migrated machines use ~/.pasture-terminals (stage 2 moves the registry whole);
# until then the legacy dir remains the single source of truth
if [ -d "$HOME/.pasture-terminals" ]; then SP_TERMDIR="$HOME/.pasture-terminals"; else SP_TERMDIR="$HOME/.stitchpad-terminals"; fi
sp_term_surface_of() { printf '%s' "$1"; }   # Herdr terminal ids and Ocean session ids are direct targets
# The terminal id of THIS shell's Herdr pane. Herdr exports a pane id, so
# resolve it to the stable terminal id used by roster targets and isolation locks.
sp_this_surface() {
  if [ -n "${HERDR_PANE_ID:-}" ] && command -v herdr >/dev/null 2>&1; then
    herdr pane get "$HERDR_PANE_ID" 2>/dev/null \
      | sed -n 's/.*"terminal_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
  fi
  return 0
}
sp_term_lock_claim() { # $1=target/surface $2=name — refuses on a live foreign claim
  local surface who cur pad name ts now
  surface="$(sp_term_surface_of "$1")"; who="$2"
  [ -n "$surface" ] && [ "$surface" != "-" ] || return 0
  mkdir -p "$SP_TERMDIR"
  cur="$(cat "$SP_TERMDIR/$surface" 2>/dev/null || true)"
  if [ -n "$cur" ]; then
    IFS='|' read -r pad name ts <<<"$cur"
    now="$(date +%s)"
    if { [ "$pad" != "$PAD_DIR" ] || [ "$name" != "$who" ]; } \
       && [ $((now - ${ts:-0})) -lt 300 ] && [ "${STITCHPAD_STEAL:-0}" != "1" ]; then
      echo "stitchpad: REFUSED — terminal $surface is live as @$name in $pad. One terminal = one pad. 'stitchpad leave $name' there first, or STITCHPAD_STEAL=1 to take it over." >&2
      return 1
    fi
  fi
  printf '%s|%s|%s' "$PAD_DIR" "$who" "$(date +%s)" > "$SP_TERMDIR/$surface"
}
sp_term_lock_touch() { # heartbeat path: refresh ours / claim vacant — NEVER steal
  local surface who cur pad name ts
  surface="$(sp_term_surface_of "$1")"; who="$2"
  [ -n "$surface" ] && [ "$surface" != "-" ] || return 0
  cur="$(cat "$SP_TERMDIR/$surface" 2>/dev/null || true)"
  if [ -n "$cur" ]; then
    IFS='|' read -r pad name ts <<<"$cur"
    { [ "$pad" = "$PAD_DIR" ] && [ "$name" = "$who" ]; } || return 0
  fi
  mkdir -p "$SP_TERMDIR"
  printf '%s|%s|%s' "$PAD_DIR" "$who" "$(date +%s)" > "$SP_TERMDIR/$surface"
}
sp_term_lock_release() { # drop every claim this (pad, name) holds
  local who="$1" f pad name ts
  for f in "$SP_TERMDIR"/*; do
    [ -f "$f" ] || continue
    IFS='|' read -r pad name ts < "$f"
    [ "$pad" = "$PAD_DIR" ] && [ "$name" = "$who" ] && rm -f "$f"
  done
  return 0
}
sp_term_lock_check() { # $1=target $2=name → 0 ok; 1 = LIVE claim by someone else (prints holder)
  local surface who cur pad name ts now
  surface="$(sp_term_surface_of "$1")"; who="$2"
  [ -n "$surface" ] && [ "$surface" != "-" ] || return 0
  cur="$(cat "$SP_TERMDIR/$surface" 2>/dev/null || true)"; [ -n "$cur" ] || return 0
  IFS='|' read -r pad name ts <<<"$cur"; now="$(date +%s)"
  [ $((now - ${ts:-0})) -ge 300 ] && return 0
  if [ "$pad" != "$PAD_DIR" ] || [ "$name" != "$who" ]; then printf '%s' "$cur"; return 1; fi
  return 0
}

# ── Notifications ────────────────────────────────────────────────────
sp_notify() {
  local title="$1" msg="$2" sound="${3:-Glass}"
  if command -v terminal-notifier >/dev/null 2>&1; then
    terminal-notifier -title "$title" -message "$msg" -sound "$sound" 2>/dev/null || true
  else
    osascript -e "display notification \"${msg//\"/\\\"}\" with title \"${title//\"/\\\"}\" sound name \"$sound\"" 2>/dev/null || true
  fi
}

# ── Watcher lifecycle (singleton) ────────────────────────────────────
# ensure_watcher: called on every stitchpad subcommand exit. Spawns the pad
# watcher (watch.sh) iff (a) any agent heartbeat is fresh AND (b) no watcher
# already holds the singleton lock. Uses mkdir-atomic to guarantee exactly one
# watcher per pad — same pattern as sp_lock() and claims.
#
# Heartbeat freshness: .state/alive.<name> mtime < 90s AND kill -0 pid succeeds.
# Self-exit: watch.sh polls heartbeats and removes the lock + exits when ALL
# heartbeats are stale (all agents' terminals closed).
# Has any agent posted a fresh heartbeat recently?
# MATCHES watch.sh react(): fresh mtime alone counts as alive when pid is empty
# or zero (e.g. pre-ticker pads, corrupted alive files). Only stale mtime means
# dead. This prevents the supervisor from exiting just because heartbeats lack
# a pid field.
sp_any_alive() {
  local now alive heart file pid ts
  now=$(date +%s)
  for heart in "$PAD_STATE"/alive.*; do
    [ -f "$heart" ] || continue
    ts=$(stat -f %m "$heart" 2>/dev/null || stat -c %Y "$heart" 2>/dev/null || echo 0)
    [ $(( now - ts )) -lt 90 ] || continue
    pid=$(grep -o '"pid":[0-9]*' "$heart" 2>/dev/null | head -1 | cut -d: -f2)
    # Fresh heartbeat with no pid still counts as alive (unknown != dead).
    [ -z "$pid" ] && return 0
    # Fresh heartbeat with live pid counts as alive.
    kill -0 "$pid" 2>/dev/null && return 0
  done
  return 1
}

# Physically delete the corpses the 90s-TTL liveness rules already ignore, so
# .state/ doesn't accumulate a graveyard across sessions. Logic was always
# self-healing (roster/sp_any_alive skip stale mtime); this just reclaims disk.
# Safe to call any time — it only removes things proven dead. Called on join
# and on supervisor exit.
sp_reap_dead() {
  [ -n "${PAD_STATE:-}" ] || return 0
  local now; now=$(date +%s)
  # 1. leftover atomic-write tmp files (.alive.<who>.<pid>) whose rename never
  #    completed — never read by anything, pure litter.
  for f in "$PAD_STATE"/.alive.*; do
    [ -e "$f" ] || continue
    local pid="${f##*.}"
    kill -0 "$pid" 2>/dev/null || rm -f "$f"
  done
  # 1b. abandoned .sp-stage.* files from a rewrite that died before promotion.
  #     Never touches .ready files — those are recoverable content, not litter.
  for f in "$PAD_DIR"/.sp-stage.*; do
    [ -f "$f" ] || continue
    local sts; sts=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo "$now")
    [ $(( now - sts )) -gt 3600 ] && rm -f "$f"
  done
  # 2. presence heartbeats (alive.<name>) gone stale: mtime >90s AND pid dead.
  #    operators/humans have no pid and never expire — leave them.
  for f in "$PAD_STATE"/alive.*; do
    [ -f "$f" ] || continue
    local ts; ts=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
    [ $(( now - ts )) -lt 90 ] && continue
    local pid; pid=$(grep -o '"pid":[0-9]*' "$f" 2>/dev/null | head -1 | cut -d: -f2)
    [ -z "$pid" ] || [ "$pid" = "0" ] && continue   # unknown/operator → keep
    kill -0 "$pid" 2>/dev/null || rm -rf "$f" "$PAD_STATE/heartbeat.${f##*/alive.}.lock" 2>/dev/null
  done
  # 3. file-claims whose holder pid is gone (holder line: "<name> <ts> <path>";
  #    no pid recorded, so fall back to staleness — claims older than 1h are dead).
  for d in "$PAD_STATE"/claims/*.d; do
    [ -d "$d" ] || continue
    local cts; cts=$(stat -f %m "$d" 2>/dev/null || stat -c %Y "$d" 2>/dev/null || echo 0)
    [ $(( now - cts )) -gt 3600 ] && rm -rf "$d"
  done
  return 0
}

# Is the watcher running? (lock dir exists AND PID alive)
sp_watcher_alive() {
  local watch_lock="$PAD_STATE/watch.lock.d"
  [ -d "$watch_lock" ] || return 1
  local ts now age
  ts=$(cat "$watch_lock/ts" 2>/dev/null)
  [ -n "$ts" ] && ts=$(date -ju -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null || echo 0)
  [ "$ts" = "0" ] && ts=$(stat -f %m "$watch_lock" 2>/dev/null || stat -c %Y "$watch_lock" 2>/dev/null || echo 0)
  now=$(date +%s)
  age=$(( now - ts ))
  # Grace period (< 5s): trust the lock even if PID not registered yet.
  # The watcher writes its real PID within 100ms of startup.
  [ "$age" -lt 5 ] && return 0
  # Older lock: check PID liveness.
  local p; p="$(cat "$watch_lock/pid" 2>/dev/null)"
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null && return 0
  # Dead or stale — clean so we can re-acquire.
  rm -rf "$watch_lock" 2>/dev/null || true
  return 1
}

sp_watch_processes_for_pad() {
  [ -n "${PAD_MD:-}" ] || return 0
  ps -axo pid=,ppid=,command= | awk -v pad="$PAD_MD" '
    index($0, "fswatch -0 " pad) && $0 !~ /awk/ {
      print $1
      print $2
    }
  ' | sort -nu
}

sp_watch_fswatch_parents_for_pad() {
  [ -n "${PAD_MD:-}" ] || return 0
  ps -axo pid=,ppid=,command= | awk -v pad="$PAD_MD" '
    index($0, "fswatch -0 " pad) && $0 !~ /awk/ {
      print $2
    }
  ' | sort -nu
}

sp_stop_watchers_for_pad() {
  [ -n "${PAD_STATE:-}" ] || return 0
  local watch_lock="$PAD_STATE/watch.lock.d"
  local p pids=()
  p="$(cat "$watch_lock/pid" 2>/dev/null || true)"
  [ -n "$p" ] && pids+=( "$p" )
  while IFS= read -r p; do
    [ -n "$p" ] && pids+=( "$p" )
  done < <(sp_watch_processes_for_pad)

  rm -rf "$watch_lock" 2>/dev/null || true
  for p in "${pids[@]}"; do
    kill "$p" 2>/dev/null || true
  done
  sleep 0.2
  for p in "${pids[@]}"; do
    kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null || true
  done
}

sp_reap_duplicate_watchers_for_pad() {
  [ -n "${PAD_STATE:-}" ] || return 0
  local watch_lock="$PAD_STATE/watch.lock.d"
  local keep parent parents=()
  keep="$(cat "$watch_lock/pid" 2>/dev/null || true)"
  if [ -z "$keep" ] || ! kill -0 "$keep" 2>/dev/null; then
    sp_stop_watchers_for_pad
    return 1
  fi

  while IFS= read -r parent; do
    [ -n "$parent" ] && parents+=( "$parent" )
  done < <(sp_watch_fswatch_parents_for_pad)

  if [ "${#parents[@]}" -eq 1 ] && [ "${parents[0]}" = "$keep" ]; then
    return 0
  fi

  sp_stop_watchers_for_pad
  return 1
}

ensure_watcher() {
  [ -n "${PAD_DIR:-}" ] || sp_init_paths || return 0
  local watch_lock="$PAD_STATE/watch.lock.d"
  local watch_log="$PAD_STATE/watch.log"
  # Only spawn if someone is alive and listening
  sp_any_alive || return 0
  # Already running? Nothing to do.
  if sp_watcher_alive; then
    if sp_reap_duplicate_watchers_for_pad; then
      sleep 0.2
      sp_watcher_alive && return 0
    fi
  fi
  sp_stop_watchers_for_pad
  # ATOMIC acquire: exactly one caller wins.
  if ! mkdir "$watch_lock" 2>/dev/null; then
    # Lost the race. Brief sleep lets winner write its PID, then re-check.
    sleep 0.3
    sp_watcher_alive && return 0
    # Stale lock. Clean and retry once.
    rm -rf "$watch_lock" 2>/dev/null || true
    mkdir "$watch_lock" 2>/dev/null || return 0
  fi
  # Spawn the watcher. No trap — the watcher removes the lock on exit.
  ( STITCHPAD_PAD_DIR="$PAD_DIR" bash "$STITCHPAD_HOME/bin/watch.sh" >>"$watch_log" 2>&1 ) &
  # Placeholder PID+ts so concurrent callers see a fresh lock during the grace
  # period. The watcher overwrites both with its real PID on startup.
  echo $$ > "$watch_lock/pid"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$watch_lock/ts"
  disown %-
  return 0
}
