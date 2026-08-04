#!/usr/bin/env bash
# stitchpad relay bridge — runs on the Mac. Mirrors EVERY local stitchpad up to
# the Cloudflare relay (keyed by pad name = directory basename), and drains each
# pad's phone→pad queue back into the real pad via `stitchpad say` (which the
# watcher then wakes agents from). The CLI stays the source of truth.
#
#   STITCHPAD_RELAY=https://stitchpad.agentsworld.org \
#   STITCHPAD_TOKEN=<secret> \
#   stitchpad-bridge [roots...]      # roots to scan for .stitchpad dirs (default: ~ )
set -uo pipefail
RELAY="${STITCHPAD_RELAY:?set STITCHPAD_RELAY}"
TOKEN="${STITCHPAD_TOKEN:?set STITCHPAD_TOKEN}"
ROOTS=("${@:-$HOME}")
SP="$(command -v stitchpad || echo "$HOME/.stitchpad/bin/stitchpad")"
INTERVAL="${STITCHPAD_BRIDGE_INTERVAL:-3}"

api() { curl -fsS -H "authorization: Bearer $TOKEN" -H "content-type: application/json" "$@"; }

# find all .stitchpad pads under the roots, excluding scratch pads (P18)
find_pads() {
  for r in "${ROOTS[@]}"; do
    find "$r" -maxdepth 4 -type d -name .stitchpad 2>/dev/null
  done | grep -v "/.stitchpad/.stitchpad" \
        | while IFS= read -r pd; do [ -f "$pd/.scratch" ] || printf '%s\n' "$pd"; done \
        | sort -u
}

echo "[bridge] relay=$RELAY  interval=${INTERVAL}s  scanning: ${ROOTS[*]}"
while :; do
  _bridge_current=""
  while IFS= read -r padd; do
    [ -f "$padd/stitchpad.md" ] || continue
    name="$(basename "$(dirname "$padd")")"            # pad name = project dir
    _bridge_current="${_bridge_current}${name}
"
    md="$(cat "$padd/stitchpad.md")"
    roster="$(cd "$(dirname "$padd")" && "$SP" roster 2>/dev/null | awk -F'|' '{printf "%s{\"name\":\"%s\",\"adapter\":\"%s\"}", (NR>1?",":""), $1, $2}')"
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
    # $roster is the raw "{...},{...}" fragment (no brackets until the push), so wrap
    # it into a JSON array before iterating — bare it fails jq and the loop never runs.
    for _name in $(echo "[$roster]" | jq -r '.[].name' 2>/dev/null); do
      _model="$(cat "$padd/.state/model.$_name" 2>/dev/null || echo '')"
      _role="$(cat "$padd/.state/role.$_name" 2>/dev/null || echo '')"
      _level="$(cat "$padd/.state/level.$_name" 2>/dev/null || echo '')"
      _persona=""
      _skills='[]'
      # (do NOT blank _role here — it was just read from .state/role.<name> above)
      # Try to read persona from stitchpad install (not pad dir). NOTE: ~/.stitchpad
      # is itself a symlink to the repo's tool/ dir, so the personas live at
      # ~/.stitchpad/personas — NOT ~/.stitchpad/tool/personas (that doubles tool/).
      # If STITCHPAD_HOME points at the repo root, it needs /tool/personas; support both.
      _persona_dir="${STITCHPAD_HOME:+$STITCHPAD_HOME/tool/personas}"
      [ -z "$_persona_dir" ] || [ ! -d "$_persona_dir" ] && _persona_dir="$HOME/.stitchpad/personas"
      [ -d "$_persona_dir" ] || _persona_dir="$HOME/.stitchpad/tool/personas"  # last-resort
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
      # Get adapter from roster entry
      _adapter="$(echo "[$roster]" | jq -r '.[] | select(.name=="'"$_name"'") | .adapter // ""' 2>/dev/null || echo '')"
      # Derive status: dnd > working > available > idle
      _status="available"
      if [ -f "$padd/.state/dnd.$_name" ]; then
        _status="dnd"
      else
        # Check if agent posted within last 90s (working)
        # Portable date arithmetic: BSD date -j first, GNU date -d second.
        _last_post_epoch="$(grep -a "^## @$_name" "$padd/stitchpad.md" | tail -1 | grep -o '[0-9]\{2\}:[0-9]\{2\}' | tail -1 | xargs -I{} bash -c 'date -j -f "%H:%M" "$1" +%s 2>/dev/null || date -d "$1" +%s 2>/dev/null || echo 0' _ '{}')"
        _now_hour="$(date +%H:%M)"
        _now_epoch="$(date -j -f '%H:%M' "$_now_hour" +%s 2>/dev/null || date -d "$_now_hour" +%s 2>/dev/null || echo 0)"
        _post_age=$(( _now_epoch - _last_post_epoch ))
        if [ "$_post_age" -gt 0 ] && [ "$_post_age" -lt 90 ]; then
          _status="working"
        fi
      fi
      # Online: heartbeat file fresh (<90s) AND pid still alive
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
      profiles="$(echo "$profiles" | jq --arg n "$_name" --arg m "$_model" --arg r "$_role" --arg lv "$_level" --arg p "$_persona" --argjson s "${_skills:-[]}" --arg h "$_adapter" --arg st "$_status" --argjson on "$_online"\
        '. + {($n): {role:$r, level:$lv, persona:$p, skills:$s, model:$m, harness:$h, status:$st, online:$on}}')"
    done
    # push this pad up (markdown + roster + files + colors + profiles)
    jq -nc --arg pad "$md" --argjson roster "[${roster}]" --argjson files "${files:-[]}" --argjson colors "${colors}" --argjson profiles "${profiles}" \
      '{pad:$pad, roster:$roster, files:$files, colors:$colors, profiles:$profiles}' 2>/dev/null \
      | api -X POST "$RELAY/push?pad=$name" --data-binary @- >/dev/null || true
    # drain phone→pad messages for this pad, inject via stitchpad say
    out="$(api "$RELAY/outbox?pad=$name" 2>/dev/null || echo '{"messages":[]}')"
    echo "$out" | jq -c '.messages[]?' 2>/dev/null | while IFS= read -r m; do
      from="$(echo "$m" | jq -r '.from')"; text="$(echo "$m" | jq -r '.text')"
      ( cd "$(dirname "$padd")" && STITCHPAD_NAME="$from" "$SP" say "$text" >/dev/null 2>&1 ) || true
      echo "[bridge] $name ← @$from: ${text:0:50}"
    done
    # drain phone→agent TRUE DMs — inject straight into the agent's herdr pane,
    # NEVER onto the shared pad (steering pings were bloating thread context).
    # Fallback only if the pane is dead: land it as a pad mention so it's not lost.
    dmq="$(api "$RELAY/dmbox?pad=$name" 2>/dev/null || echo '{"messages":[]}')"
    echo "$dmq" | jq -c '.messages[]?' 2>/dev/null | while IFS= read -r m; do
      from="$(echo "$m" | jq -r '.from')"; to="$(echo "$m" | jq -r '.to')"; text="$(echo "$m" | jq -r '.text')"
      row="$(cd "$(dirname "$padd")" && "$SP" roster 2>/dev/null | awk -F'|' -v n="$to" '$1==n {print; exit}')"
      adapter="$(echo "$row" | cut -d'|' -f2)"; target="$(echo "$row" | cut -d'|' -f4)"
      delivered=0
      if [ "$adapter" = "herdr" ] && [ -n "$target" ] && [ "$target" != "-" ]; then
        hd="$(command -v herdr 2>/dev/null || echo "$HOME/.local/bin/herdr")"
        pane="$([ -x "$hd" ] && "$hd" agent get "$target" 2>/dev/null | sed -n 's/.*"pane_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
        if [ -n "$pane" ]; then
          # sanitize: pane run reaches a raw pty — strip control bytes, collapse whitespace
          dmsg="$(printf 'stitchpad DM from @%s (private — not on the pad; reply lands on the pad unless they DM you back): %s' "$from" "$text" | LC_ALL=C tr -d '\000-\037\177' | tr -s ' ')"
          "$hd" pane run "$pane" "$dmsg" >/dev/null 2>&1 && delivered=1
        fi
      fi
      if [ "$delivered" = "1" ]; then
        echo "[bridge] $name DM @$from → @$to terminal (${text:0:40})"
      else
        ( cd "$(dirname "$padd")" && STITCHPAD_NAME="$from" "$SP" say "@$to (dm — terminal unreachable) $text" >/dev/null 2>&1 ) || true
        echo "[bridge] $name DM @$from → @$to FELL BACK to pad (no live pane)"
      fi
    done
    # drain uploaded attachments → the project's .stitchpad/dropbox/
    fq="$(api "$RELAY/filebox?pad=$name" 2>/dev/null || echo '{"messages":[]}')"
    echo "$fq" | jq -c '.messages[]?' 2>/dev/null | while IFS= read -r m; do
      fname="$(echo "$m" | jq -r '.name')"; fkey="$(echo "$m" | jq -r '.key')"
      [ -n "$fname" ] && [ -n "$fkey" ] || continue
      drop="$padd/dropbox"; mkdir -p "$drop" 2>/dev/null || true
      if api "$RELAY/f/${fkey#files/}" -o "$drop/$fname" 2>/dev/null; then
        echo "[bridge] $name 📎 $fname → .stitchpad/dropbox/"
      else
        echo "[bridge] $name 📎 FAILED to download $fname"
      fi
    done
    # Write heartbeat after successful push+drain for this pad
    printf '{"ts":"%s","pad":"%s","interval":%s}' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$name" "$INTERVAL" > "$padd/.state/bridge-heartbeat" 2>/dev/null || true
  done < <(find_pads)

  # P26: reconcile — DELETE any pad on the relay that was pushed last cycle
  # but no longer exists on disk (pad directory deleted). Uses a simple
  # persisted name list in the relay state dir.
  _bridge_state_dir="${HOME}/.stitchpad/relay/state"
  mkdir -p "$_bridge_state_dir" 2>/dev/null || true
  _bridge_prev="$_bridge_state_dir/bridge-pads.prev"
  if [ -f "$_bridge_prev" ]; then
    while IFS= read -r _old_name; do
      [ -z "$_old_name" ] && continue
      if ! echo "$_bridge_current" | grep -Fxq "$_old_name"; then
        api -X DELETE "$RELAY/pads?pad=$_old_name" >/dev/null 2>&1 || true
        echo "[bridge] unregistered: #$_old_name (pad no longer on disk)"
      fi
    done < "$_bridge_prev"
  fi
  printf '%s\n' "$_bridge_current" > "$_bridge_prev"

  sleep "$INTERVAL"
done
