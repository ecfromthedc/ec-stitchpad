#!/usr/bin/env bash
# stitchpad bridge — push ONE pad snapshot to the relay, once.
# Extracted from bridge.sh so the websocket sidecar (bridge-ws.mjs) and the
# legacy polling bridge share a single payload implementation.
#
#   STITCHPAD_RELAY=... STITCHPAD_TOKEN=... bridge-push-once.sh <path/to/.stitchpad>
set -uo pipefail
RELAY="${STITCHPAD_RELAY:?set STITCHPAD_RELAY}"
TOKEN="${STITCHPAD_TOKEN:?set STITCHPAD_TOKEN}"
padd="${1:?usage: bridge-push-once.sh <path/to/.stitchpad>}"
SP="$(command -v stitchpad || echo "$HOME/.stitchpad/bin/stitchpad")"

api() { curl -fsS -H "authorization: Bearer $TOKEN" -H "content-type: application/json" "$@"; }

PADMD="$padd/pasture.md"; [ -f "$PADMD" ] || PADMD="$padd/stitchpad.md"; [ -f "$PADMD" ] || exit 0
name="$(basename "$(dirname "$padd")")"            # pad name = project dir
md="$(cat "$PADMD")"
# Task cards live in the sibling tasks.md now, but the PHONE BOARD renders from
# this pushed doc (parseTasks over body.pad in the PWA) — append tasks.md's
# ```task blocks or every migrated/new card silently vanishes from the kanban.
# Appended AFTER the pad so the PWA's last-wins parser prefers these over any
# stale legacy inline copy of the same id still sitting in the conversation.
TASKSMD="$padd/tasks.md"
if [ -s "$TASKSMD" ]; then
  tblocks="$(awk '/^```task /{inblk=1} inblk{print} inblk&&/^```$/{inblk=0; print ""}' "$TASKSMD")"
  [ -n "$tblocks" ] && md="$md"$'\n\n'"$tblocks"
fi
# Cloudflare WS frames cap at 1MiB — a pad past that kills the DO broadcast
# (error 1101) and NOTHING updates. Phones only need the recent window; keep
# the roster block + EVERY task block (the board renders from this doc — a
# task above the cut must not vanish from the kanban) + the newest ~350KB.
if [ "${#md}" -gt 400000 ]; then
  md="$(printf '%s' "$md" | python3 -c '
import re, sys
t = sys.stdin.read()
m = re.search(r"```roster\n[\s\S]*?```", t)
roster = m.group(0) if m else ""
tail = t[-350000:]
cut = tail.find("\n## @")
tail = tail[cut + 1:] if cut != -1 else tail
blocks = {}
for mm in re.finditer(r"```task (\S+)\n[\s\S]*?```", t):
    blocks[mm.group(1)] = mm.group(0)          # last occurrence wins (in-place edits)
have = set(re.findall(r"```task (\S+)\n", tail))
pinned = [b for i, b in blocks.items() if i not in have]
parts = [roster, "\n\n*…earlier history trimmed for phone — full pad lives on the mac…*\n"]
if pinned:
    parts.append("\n" + "\n\n".join(pinned) + "\n")
parts.append("\n" + tail)
sys.stdout.write("".join(parts))
')"
fi
# --doc: print the assembled doc (exactly what the phone will render) and stop.
# Lets tests assert the pad↔tasks.md↔board contract without a relay.
if [ "${2:-}" = "--doc" ]; then printf '%s\n' "$md"; exit 0; fi
roster="$(cd "$(dirname "$padd")" && "$SP" roster 2>/dev/null | awk -F'|' '{gsub(/[ \t]/,"",$4); printf "%s{\"name\":\"%s\",\"adapter\":\"%s\",\"target\":\"%s\"}", (NR>1?",":""), $1, $2, $4}')"
# file list for the `>` attach dropdown: project files, relative paths, skip junk/dotdirs
proj="$(dirname "$padd")"
files="$(cd "$proj" && find . -maxdepth 3 -type f \
    -not -path '*/.git/*' -not -path '*/.stitchpad/*' -not -path '*/node_modules/*' \
    -not -path '*/target/*' -not -path '*/.*/*' 2>/dev/null \
    | sed 's|^\./||' | sort | head -500 | jq -R . | jq -sc .)"
# collect single-source color map from the pad (flat object: {name: hex})
colors="$(cd "$proj" && "$SP" color --all 2>/dev/null | jq -R 'split(" ") | {(.[0]): .[1]}' | jq -sc 'add // {}' 2>/dev/null || echo '{}')"
# collect per-agent profiles (role, persona, skills, model, harness)
profiles='{}'
for _name in $(echo "[$roster]" | jq -r '.[].name' 2>/dev/null); do
  _model="$(cat "$padd/.state/model.$_name" 2>/dev/null || echo '')"
  # daemon-seat agents: the session-config RPC is the model's source of truth —
  # a model switched over RPC must flip the card chip on the next push
  _tgt="$(echo "[$roster]" | jq -r '.[] | select(.name=="'"$_name"'") | .target // ""' 2>/dev/null)"
  _adp0="$(echo "[$roster]" | jq -r '.[] | select(.name=="'"$_name"'") | .adapter // ""' 2>/dev/null)"
  _last_model=""
  if [ "$_adp0" = "ocean" ] && [ -n "$_tgt" ] && [ "$_tgt" != "-" ]; then
    _live="$(curl -sf --max-time 2 "${OCEAN_DAEMON_URL:-http://127.0.0.1:4780}/v1/agent/sessions/$_tgt/config" 2>/dev/null | jq -r '.model // empty' 2>/dev/null)"
    if [ -n "$_live" ]; then _model="$_live"; printf '%s' "$_live" > "$padd/.state/model.$_name" 2>/dev/null; fi
    # what the session ACTUALLY ran last: clients (TUI/GUI) pass explicit
    # per-turn models that outrank the session default the chip shows
    _last_model="$(tail -c 2000000 /tmp/ocean-daemon.log 2>/dev/null | perl -pe 's/\e\[[0-9;]*m//g' | grep "provider_stream" | grep "$_tgt" | tail -1 | grep -oE 'model=[a-zA-Z0-9._-]+' | head -1 | cut -d= -f2)"
  fi
  _role="$(cat "$padd/.state/role.$_name" 2>/dev/null || echo '')"
  _level="$(cat "$padd/.state/level.$_name" 2>/dev/null || echo '')"
  _persona=""
  _skills='[]'
  _persona_dir="${STITCHPAD_HOME:+$STITCHPAD_HOME/tool/personas}"
  [ -z "$_persona_dir" ] || [ ! -d "$_persona_dir" ] && _persona_dir="$HOME/.stitchpad/personas"
  [ -d "$_persona_dir" ] || _persona_dir="$HOME/.stitchpad/tool/personas"
  _persona_file="$_persona_dir/$(echo "$_name" | tr '[:upper:]' '[:lower:]').md"
  if [ -f "$_persona_file" ]; then
    [ -z "$_role" ] && _role="$(grep -m1 '^ROLE:' "$_persona_file" | sed 's/^ROLE:[[:space:]]*//')"
    [ -z "$_role" ] && _role="$(head -1 "$_persona_file" | sed 's/^# //')"
    _persona="$(grep -m1 '^PERSONA:' "$_persona_file" | sed 's/^PERSONA:[[:space:]]*//')"
    _skills="$(python3 -c "
import json
with open('$_persona_file') as f:
    lines = f.readlines()
in_skills = False
skills = []
for line in lines:
    line = line.strip()
    if line.startswith('SKILLS:'):
        in_skills = True
        continue
    if in_skills and line.startswith('- '):
        parts = line[2:].split(' — ', 1)
        name = parts[0].strip()
        desc = parts[1].strip() if len(parts) > 1 else ''
        skills.append({'name': name, 'desc': desc})
    elif in_skills and not line.startswith('- ') and line:
        break
print(json.dumps(skills))
" 2>/dev/null || echo '[]')"
    [ -z "$_skills" ] && _skills='[]'
  fi
  _adapter="$(echo "[$roster]" | jq -r '.[] | select(.name=="'"$_name"'") | .adapter // ""' 2>/dev/null || echo '')"
  # herdr is a pane wrapper, not a harness — the runtime marker (claude/pi/codex)
  # is the agent's real identity for logos, colors, and slash capability
  _runtime="$(cat "$padd/.state/runtime.$_name" 2>/dev/null || echo '')"
  [ -n "$_runtime" ] && _adapter="$_runtime"
  _status="available"
  if [ -f "$padd/.state/dnd.$_name" ]; then
    _status="dnd"
  else
    _last_post_epoch="$(grep -a "^## @$_name" "$PADMD" | tail -1 | grep -o '[0-9]\{2\}:[0-9]\{2\}' | tail -1 | xargs -I{} date -j -f '%H:%M' '{}' +%s 2>/dev/null || echo 0)"
    _now_hour="$(date +%H:%M)"
    _now_epoch="$(date -j -f '%H:%M' "$_now_hour" +%s 2>/dev/null || echo 0)"
    _post_age=$(( _now_epoch - _last_post_epoch ))
    if [ "$_post_age" -gt 0 ] && [ "$_post_age" -lt 90 ]; then
      _status="working"
    fi
  fi
  _online="false"
  _alive="$padd/.state/alive.$_name"
  if [ -f "$_alive" ]; then
    _alive_ts="$(stat -f %m "$_alive" 2>/dev/null || stat -c %Y "$_alive" 2>/dev/null || echo 0)"
    _alive_age=$(( $(date +%s) - _alive_ts ))
    if [ "$_alive_age" -lt 90 ]; then
      _alive_pid="$(grep -o '"pid":[0-9]*' "$_alive" 2>/dev/null | head -1 | cut -d: -f2)"
      [ -n "$_alive_pid" ] && kill -0 "$_alive_pid" 2>/dev/null && _online="true"
    fi
  fi
  profiles="$(echo "$profiles" | jq --arg n "$_name" --arg m "$_model" --arg r "$_role" --arg lv "$_level" --arg p "$_persona" --argjson s "${_skills:-[]}" --arg h "$_adapter" --arg st "$_status" --arg lm "${_last_model:-}" --argjson on "$_online"\
    '. + {($n): {role:$r, level:$lv, persona:$p, skills:$s, model:$m, last_model:$lm, harness:$h, status:$st, online:$on}}')"
done
# file-write claims (who holds a lease on what) — tolerated absent
claims="$(cd "$proj" && "$SP" claims --json 2>/dev/null || echo '[]')"
echo "$claims" | jq -e . >/dev/null 2>&1 || claims='[]'
# push this pad up (markdown + roster + files + colors + profiles).
# pad text goes via --rawfile, NEVER --arg: a big pad as an argv blows ARG_MAX,
# jq dies, and curl posts an empty body the worker 500s on.
_mdf="$(mktemp)"; printf '%s' "$md" > "$_mdf"
jq -nc --rawfile pad "$_mdf" --argjson roster "[${roster}]" --argjson files "${files:-[]}" --argjson colors "${colors}" --argjson profiles "${profiles}" --argjson claims "${claims}" \
  '{pad:$pad, roster:$roster, files:$files, colors:$colors, profiles:$profiles, claims:$claims}' 2>/dev/null \
  | api -X POST "$RELAY/push?pad=$name" --data-binary @- >/dev/null
_rc=$?; rm -f "$_mdf"; [ $_rc -eq 0 ] || exit 1
exit 0
