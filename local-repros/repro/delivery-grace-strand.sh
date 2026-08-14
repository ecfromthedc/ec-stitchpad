#!/bin/bash
# OPEN #3 reproduction: delivery_start_worker's 5s ownerless-lock grace
# returns WITHOUT spawning, so a brand-new delivery generation landing in
# that window has no worker and waits for the next enqueue. With no further
# pad writes, the mention sits.
# Usage: delivery-grace-strand.sh [repo-root]
set -u
ROOT="${1:-/Users/ecfromthedc/dev/rt/rt-stitchpad-prs/wt}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sp-grace.XXXXXX")"
export TMPDIR="$TMP"

# mock adapter that always accepts and records calls
TEST_TOOL="$TMP/tool"; mkdir -p "$TEST_TOOL/adapters"
ln -s "$ROOT/tool/bin" "$TEST_TOOL/bin"
cat > "$TEST_TOOL/adapters/okay.sh" <<'MOCK'
#!/usr/bin/env bash
set -u
name="$2"; state="$SP_PAD_DIR/.state"
printf '%s\n' "$(date +%s)" >> "$state/okay.$name.calls"
exit 0
MOCK
chmod +x "$TEST_TOOL/adapters/okay.sh"
export STITCHPAD_HOME="$TEST_TOOL"
BIN_DIR="$ROOT/tool/bin"
# shellcheck disable=SC1090
source "$ROOT/tool/bin/lib.sh"

CASE_PAD="$TMP/case/.stitchpad"; mkdir -p "$CASE_PAD/.state"
{ printf '# grace fixture\n\n```roster\n'; printf 'stranded | okay | push | t\n'; printf '```\n'; } > "$CASE_PAD/stitchpad.md"
sp_init_paths "$CASE_PAD" >/dev/null

STITCHPAD_WATCH_LIB_ONLY=1
# shellcheck disable=SC1090
source "$ROOT/tool/bin/watch.sh"
unset STITCHPAD_WATCH_LIB_ONLY
export SP_DELIVERY_RETRY_SECONDS=1

# The dead starter: worker lock with token+born, NO owner — its creator died
# between mkdir and spawn.
lock="$(delivery_worker_lock stranded)"
mkdir -p "$lock"
printf '%s' "dead-starter-token" > "$lock/token"
date +%s > "$lock/born"

printf '\n## @operator · 00:00\n\n@stranded are you there?\n' >> "$PAD_MD"

t0="$(date +%s)"
delivery_enqueue stranded okay push t
t1="$(date +%s)"

# give the (possibly spawned) worker time to run the adapter
perl -e 'select(undef,undef,undef,8)'

state="$(sed -n 's/^state=//p' "$(delivery_state_file stranded)" 2>/dev/null | tail -1)"
calls="$(wc -l < "$PAD_STATE/okay.stranded.calls" 2>/dev/null | tr -d ' ' || echo 0)"
pending="$( [ -f "$(delivery_pending_file stranded)" ] && echo yes || echo no )"
echo "enqueue took $((t1-t0))s; state='${state:-<none>}' adapter_calls=${calls:-0} pending=$pending"

if [ "${calls:-0}" -eq 0 ] && [ "$pending" = "yes" ]; then
  echo "REPRODUCED: one enqueue during the ownerless grace left the mention sitting (no worker, no adapter call)"
  status=0
else
  echo "NOT REPRODUCED: delivery proceeded (state=${state:-<none>}, calls=${calls:-0})"
  status=1
fi
rm -rf "$TMP"
exit $status
