#!/usr/bin/env bash
# roster-recovery-guard-regression.sh — TASK-9 fix lane (km2, non-author fix
# of fx1's CONFIRMED findings on km3's 5c8c046). F9-1: the .ready recovery
# replay must not bypass the roster guard. F9-2: say must refuse an EMPTY
# roster fence. F9-3: REFUTED (dedupe is case-insensitive) — pinned as a
# regression gate together with the refusal-propagation fixes (a refused
# guarded write must abort the verb, never print success).
# Isolated mktemp fixtures, isolated HOME, no network, all children reaped.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/stitchpad-rog.XXXXXX")"
cleanup() { ( cd "$tmp/pad" 2>/dev/null && "$SP" daemon stop >/dev/null 2>&1 ); rm -rf "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/home"
export HOME="$tmp/home"
export STITCHPAD_HEARTBEAT_AUTOSTART=0
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID 2>/dev/null || true
unset STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID 2>/dev/null || true

PASSED=0; FAILED=0
ok()   { PASSED=$((PASSED + 1)); printf '  PASS %s\n' "$1"; }
bad()  { FAILED=$((FAILED + 1)); printf '  FAIL %s: %s\n' "$1" "$2" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
refused() { case "$2" in *REFUSED*|*refused*|*refusing*) ok "$1" ;; *) bad "$1" "not refused: $2" ;; esac; }

PAD_MD="$tmp/pad/.stitchpad/stitchpad.md"
mkdir -p "$tmp/pad"
( cd "$tmp/pad" && "$SP" init --name rogtest >/dev/null 2>&1 && "$SP" daemon stop >/dev/null 2>&1 )
( cd "$tmp/pad" && "$SP" join alice codex pull - >/dev/null 2>&1 )
( cd "$tmp/pad" && "$SP" join bob codex pull - >/dev/null 2>&1 )

# craft a .ready generation whose content is $2 applied to a copy of the pad
craft_ready() { # craft_ready <transform: drop-fence|append|drop-member>
  local content="$tmp/gen-content.$$"
  cp "$PAD_MD" "$content"
  case "$1" in
    drop-fence)  python3 -c '
import sys,re
p=sys.argv[1]; s=open(p).read()
s=re.sub(r"```roster.*?```\n","",s,flags=re.S)
open(p,"w").write(s)' "$content" ;;
    drop-member) python3 -c '
import sys
p=sys.argv[1]; s=open(p).read()
s="\n".join(l for l in s.splitlines() if not l.startswith("bob |"))+"\n"
open(p,"w").write(s)' "$content" ;;
    append)      printf '\n*recovered line*\n' >> "$content" ;;
    empty-roster) python3 -c '
import sys,re
p=sys.argv[1]; s=open(p).read()
s=re.sub(r"(```roster\n).*?(```)",r"\1# name | adapter | wake(push|pull) | target\n\2",s,flags=re.S)
open(p,"w").write(s)' "$content" ;;
  esac
  local ready="$PAD_MD.ready"
  rm -rf "$ready"; mkdir -p "$ready"
  mv "$content" "$ready/content"
  # the tool canonicalizes PAD_MD — compute the manifest target the same way
  local canon_md
  canon_md="$( cd "$tmp/pad" && PAD_DIR= bash -c '. "'"$ROOT"'/tool/bin/lib.sh" >/dev/null 2>&1; sp_init_paths >/dev/null 2>&1; printf %s "$PAD_MD"' )"
  python3 - "$ready/content" "$canon_md" "$1" > "$ready/owner" <<'PY'
import hashlib, json, os, sys
content, target, tag = sys.argv[1], sys.argv[2], sys.argv[3]
data = open(content, "rb").read()
print(json.dumps({
    "generation": "gen-" + tag,
    "pid": 99999999,                      # dead pid → replayable
    "processStart": "Mon Jan  1 00:00:00 2001",
    "command": "probe",
    "target": target,
    "size": len(data),
    "sha256": hashlib.sha256(data).hexdigest(),
}))
PY
}

printf '\n=== F9-1: recovery replay is roster-guarded ===\n'
craft_ready drop-fence
out="$( cd "$tmp/pad" && STITCHPAD_NAME=alice "$SP" say 'post triggering evil recovery' 2>&1 )"
refused 'R1 fence-dropping recovery generation refused' "$out"
check 'R1b roster fence survives' '1' "$(grep -c '^```roster' "$PAD_MD")"
check 'R1c roster members survive' '2' "$( cd "$tmp/pad" && "$SP" roster 2>/dev/null | grep -c '|' )"
check 'R1d generation quarantined (never replays)' '1' "$(ls -d "$PAD_MD".ready.refused.* 2>/dev/null | wc -l | tr -d ' ')"
check 'R1e .ready consumed (no infinite replay loop)' '0' "$(ls -d "$PAD_MD".ready 2>/dev/null | wc -l | tr -d ' ')"
out="$( cd "$tmp/pad" && STITCHPAD_NAME=alice "$SP" say 'second post after quarantine' 2>&1 )"
case "$out" in *'✓ posted'*) ok 'R1f pad keeps posting after quarantine' ;; *) bad 'R1f pad keeps posting after quarantine' "$out" ;; esac

craft_ready drop-member
out="$( cd "$tmp/pad" && STITCHPAD_NAME=alice "$SP" say 'post triggering shrink recovery' 2>&1 )"
case "$out" in *recovering*) ok 'R2 killed-leave shrink replay APPLIES (atomicity semantics)' ;; *) bad 'R2 killed-leave shrink replay APPLIES (atomicity semantics)' "$out" ;; esac
check 'R2b legit shrink replay removes bob' '0' "$( cd "$tmp/pad" && "$SP" roster 2>/dev/null | grep -c '^bob|' )"
( cd "$tmp/pad" && "$SP" join bob codex pull - >/dev/null 2>&1 )
# populated→EMPTY through recovery stays refused (the TASK-9 origin)
craft_ready empty-roster
out="$( cd "$tmp/pad" && STITCHPAD_NAME=alice "$SP" say 'post triggering emptying recovery' 2>&1 )"
refused 'R2c populated→EMPTY recovery refused' "$out"
check 'R2d roster survives the refused emptying replay' '2' "$( cd "$tmp/pad" && "$SP" roster 2>/dev/null | grep -c '|' )"

craft_ready append
out="$( cd "$tmp/pad" && STITCHPAD_NAME=alice "$SP" say 'post triggering legit recovery' 2>&1 )"
check 'R3 roster-preserving recovery still applies' '1' "$(grep -c 'recovered line' "$PAD_MD")"
check 'R3b legit generation retired normally' '0' "$(ls -d "$PAD_MD".ready "$PAD_MD".ready.applied.* 2>/dev/null | wc -l | tr -d ' ')"

printf '\n=== F9-2: empty roster fence refuses posts ===\n'
python3 - "$PAD_MD" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
s = re.sub(r"(```roster\n).*?(```)", r"\1# name | adapter | wake(push|pull) | target\n\2", s, flags=re.S)
open(p, "w").write(s)
PY
out="$( cd "$tmp/pad" && STITCHPAD_NAME=alice "$SP" say 'post on empty roster' 2>&1 )"
refused 'R4 say refuses EMPTY roster fence' "$out"
case "$out" in *heal-roster*) ok 'R4b refusal names heal-roster' ;; *) bad 'R4b refusal names heal-roster' "$out" ;; esac
check 'R4c nothing was posted' '0' "$(grep -c 'post on empty roster' "$PAD_MD")"
out="$( cd "$tmp/pad" && "$SP" join carol codex pull - 2>&1 )"
case "$out" in *joined*|'✓'*) ok 'R5 join onto empty roster still works (fresh-pad path)' ;; *) bad 'R5 join onto empty roster still works (fresh-pad path)' "$out" ;; esac
out="$( cd "$tmp/pad" && STITCHPAD_NAME=carol "$SP" say 'post after rejoin' 2>&1 )"
case "$out" in *'✓ posted'*) ok 'R5b say works once a member exists' ;; *) bad 'R5b say works once a member exists' "$out" ;; esac

printf '\n=== F9-3 refuted + refusal propagation ===\n'
python3 - "$PAD_MD" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("carol | codex | pull | -", "carol | codex | pull | -\nCarol | codex | pull | -", 1)
open(p, "w").write(s)
PY
out="$( cd "$tmp/pad" && STITCHPAD_NAME=carol "$SP" set-wake carol pull - 2>&1 )"
rc=$?
refused 'R6 case-aliased duplicate refused by dedupe (F9-3 refuted)' "$out"
check 'R6b refused verb exits nonzero (no swallowed refusal)' '1' "$([ $rc -ne 0 ] && echo 1 || echo 0)"
case "$out" in *'✓'*) bad 'R6c no false success line after refusal' "$out" ;; *) ok 'R6c no false success line after refusal' ;; esac
check 'R6d roster unchanged after refused set-wake' '2' "$(grep -ci '^carol | codex' "$PAD_MD")"

printf '\n========== RESULTS ==========\n'
printf 'Passed:  %d\nFailed:  %d\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] && { printf '\nAll roster-recovery-guard gates PASSED.\n'; exit 0; }
printf '\nSome roster-recovery-guard gates FAILED.\n'; exit 1
