#!/usr/bin/env bash
# stitchpad installer — symlinks the CLI + TUI onto your PATH and exposes the
# checkout at a stable path (~/.stitchpad) so the wake adapters resolve from
# hook configs no matter where you cloned the repo.
#
# Usage:
#   ./tool/install.sh            # CLI into ~/.local/bin, home at ~/.stitchpad
#   ./tool/install.sh /usr/local/bin
set -euo pipefail

SRC_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/bin" && pwd)"
HOME_DIR="$(dirname "$SRC_BIN")"          # the tool/ dir = STITCHPAD_HOME
DEST="${1:-$HOME/.local/bin}"
STD_HOME="$HOME/.stitchpad"

mkdir -p "$DEST"
ln -sf "$SRC_BIN/stitchpad"     "$DEST/stitchpad"
ln -sf "$SRC_BIN/stitchpad-tui" "$DEST/stitchpad-tui"

# Stable home symlink so adapters/bin resolve from a fixed path in hook configs.
# (If ~/.stitchpad is already a real dir, leave it; only manage the symlink.)
if [ -L "$STD_HOME" ] || [ ! -e "$STD_HOME" ]; then
  ln -sfn "$HOME_DIR" "$STD_HOME"
  echo "✓ home: $STD_HOME -> $HOME_DIR"
else
  echo "⚠  $STD_HOME exists and is not a symlink — leaving it."
  echo "    Point hook commands at: $HOME_DIR/adapters/  and  $HOME_DIR/bin/"
fi

echo "✓ linked:"
echo "    $DEST/stitchpad     -> $SRC_BIN/stitchpad"
echo "    $DEST/stitchpad-tui -> $SRC_BIN/stitchpad-tui"
echo

case ":$PATH:" in
  *":$DEST:"*) ;;
  *) echo "⚠  $DEST is not on your PATH — add it:"
     echo "    export PATH=\"$DEST:\$PATH\""; echo;;
esac

# ─── WIRING LEDGER ───────────────────────────────────────────────────────────
# k3 F16: this installer used to print "✓ stitchpad installed — multi-agent
# collaboration is wired." unconditionally, rc=0, even when every hook-wiring
# step had raised a traceback and NOTHING was wired. On a fresh machine with a
# trailing comma in ~/.claude/settings.json — the commonest JSON wound — that
# produced a fleet that can never be woken, wearing a success banner.
#
# Every wiring step now records its own outcome here. The closing banner is
# chosen from this ledger and the installer exits non-zero when it is non-empty.
# Nothing prints ✓ unless the thing it names actually happened.
WIRE_FAILED=""
_wire_fail() {
  WIRE_FAILED="${WIRE_FAILED}${WIRE_FAILED:+
}    • $1"
}

# A config we are about to merge into must PARSE first. Missing or empty is
# fine — we create those. Anything else that python3 cannot load, we refuse to
# touch: rewriting a user's settings.json would silently discard their model,
# permissions and MCP config, which is a worse outcome than a loud refusal.
_json_ok() { [ -s "$1" ] || return 0; python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1; }
_json_err() { python3 -c 'import json,sys
try: json.load(open(sys.argv[1]))
except Exception as e: print(e)' "$1" 2>/dev/null; }

# ─── WIRE THE WAKE HOOKS AUTOMATICALLY ───────────────────────────────────────
# The plugin must ship working hooks, not instructions to hand-edit configs.
# Each runtime's Stop hook runs the same stable shim (adapters/stop-hook.sh →
# `stitchpad hook`). Idempotent: only adds if missing. Needs python3 (ships on macOS).
SHIM="$STD_HOME/adapters/stop-hook.sh"

# Claude Code: ~/.claude/settings.json  hooks.Stop[]
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CLAUDE_JSON_OK=0
if command -v python3 >/dev/null 2>&1; then
  mkdir -p "$HOME/.claude"
  [ -f "$CLAUDE_SETTINGS" ] || echo '{}' > "$CLAUDE_SETTINGS"
  if _json_ok "$CLAUDE_SETTINGS"; then
    CLAUDE_JSON_OK=1
  else
    echo "✗ $CLAUDE_SETTINGS is not valid JSON — REFUSING to edit it."
    echo "    $(_json_err "$CLAUDE_SETTINGS")"
    echo "    A trailing comma is the usual cause. Fix that file and re-run this"
    echo "    installer. Nothing was wired for Claude, and nothing was overwritten."
    _wire_fail "Claude Stop wake hook — $CLAUDE_SETTINGS is unparseable"
    _wire_fail "Claude PreToolUse claim hook — same file"
  fi
fi

if [ "$CLAUDE_JSON_OK" = 1 ]; then
  if python3 - "$CLAUDE_SETTINGS" "$SHIM" <<'PY'
import json,sys
p,shim=sys.argv[1],sys.argv[2]
d=json.load(open(p))
hooks=d.setdefault("hooks",{}); stop=hooks.setdefault("Stop",[])
def wired(s): return any(h.get("command")==shim for blk in s for h in blk.get("hooks",[]))
if not wired(stop):
    stop.append({"hooks":[{"type":"command","command":shim,"timeout":15}]})
    json.dump(d,open(p,"w"),indent=2)
PY
  then echo "✓ Claude Stop hook wired ($CLAUDE_SETTINGS)"
  else _wire_fail "Claude Stop wake hook — the merge into $CLAUDE_SETTINGS failed"
  fi

  # Claude PreToolUse claim hook (hard-deny on Write/Edit for claimed files)
  CLAIM_SHIM="$STD_HOME/adapters/claim-hook.sh"
  if python3 - "$CLAUDE_SETTINGS" "$CLAIM_SHIM" <<'PY'
import json,sys
p,shim=sys.argv[1],sys.argv[2]
d=json.load(open(p)); hooks=d.setdefault("hooks",{}); pre=hooks.setdefault("PreToolUse",[])
def wired(s): return any(h.get("command")==shim for blk in s for h in blk.get("hooks",[]))
if not wired(pre):
    pre.append({"matcher":"Write|Edit|MultiEdit","hooks":[{"type":"command","command":shim,"timeout":10}]})
    json.dump(d,open(p,"w"),indent=2)
PY
  then echo "✓ Claude PreToolUse claim hook wired"
  else _wire_fail "Claude PreToolUse claim hook — the merge into $CLAUDE_SETTINGS failed"
  fi
fi

# Codex: ~/.codex/hooks.json  hooks.Stop[]
if command -v python3 >/dev/null 2>&1; then
  CODEX_HOOKS="$HOME/.codex/hooks.json"
  if [ -d "$HOME/.codex" ] || [ -f "$CODEX_HOOKS" ]; then
    [ -f "$CODEX_HOOKS" ] || { mkdir -p "$HOME/.codex"; echo '{}' > "$CODEX_HOOKS"; }
    if ! _json_ok "$CODEX_HOOKS"; then
      echo "✗ $CODEX_HOOKS is not valid JSON — REFUSING to edit it."
      echo "    $(_json_err "$CODEX_HOOKS")"
      _wire_fail "Codex Stop wake hook — $CODEX_HOOKS is unparseable"
    elif python3 - "$CODEX_HOOKS" "$SHIM" <<'PY'
import json,sys
p,shim=sys.argv[1],sys.argv[2]
d=json.load(open(p))
hooks=d.setdefault("hooks",{}); stop=hooks.setdefault("Stop",[])
def wired(s): return any(h.get("command")==shim for blk in s for h in blk.get("hooks",[]))
if not wired(stop):
    stop.append({"hooks":[{"type":"command","command":shim,"timeout":15}]})
    json.dump(d,open(p,"w"),indent=2)
PY
    then echo "✓ Codex Stop hook wired ($CODEX_HOOKS)"
    else _wire_fail "Codex Stop wake hook — the merge into $CODEX_HOOKS failed"
    fi
  fi
else
  echo "⚠  python3 not found — cannot auto-wire hooks. Wire manually (see adapters/)."
  _wire_fail "every wake hook — python3 is not installed"
fi

# MCP server deps — install so `node mcp/server.mjs` doesn't crash (-32000).
if [ -f "$HOME_DIR/mcp/package.json" ] && command -v npm >/dev/null 2>&1; then
  ( cd "$HOME_DIR/mcp" && npm install --silent >/dev/null 2>&1 ) \
    && echo "✓ MCP server deps installed ($HOME_DIR/mcp)" \
    || echo "⚠  MCP deps install failed — run: (cd $HOME_DIR/mcp && npm install)"
fi

echo

# ─── MCP SERVER REGISTRATION (idempotent) ──────────────────────────────────
# Same python3 merge pattern as hook wiring above — checks if already
# registered, adds if missing. No duplicate errors, no interactive prompts.
MCP_SERVER="$HOME_DIR/mcp/server.mjs"

# Claude: ~/.claude.json  mcpServers.stitchpad
#
# k3 F17, PROVEN: Claude Code does NOT read mcpServers from
# ~/.claude/settings.json, which is where this installer used to write it. Two
# isolated HOMEs, identical server definition, `claude mcp list`:
#   entry in ~/.claude/settings.json → "No MCP servers configured"
#   entry in ~/.claude.json          → "probe: node … ✘ Failed to connect"
# i.e. only the second file is read. Every Claude seat this installer ever
# touched was left WITHOUT the stitchpad MCP tools, while the run printed
# "✓ Claude MCP stitchpad registered". The file's own comment named the right
# path all along; the code did not follow it.
CLAUDE_JSON="$HOME/.claude.json"
if command -v python3 >/dev/null 2>&1; then
  [ -f "$CLAUDE_JSON" ] || echo '{}' > "$CLAUDE_JSON"
  if ! _json_ok "$CLAUDE_JSON"; then
    echo "✗ $CLAUDE_JSON is not valid JSON — REFUSING to edit it."
    echo "    $(_json_err "$CLAUDE_JSON")"
    _wire_fail "Claude MCP server registration — $CLAUDE_JSON is unparseable"
  elif python3 - "$CLAUDE_JSON" "$MCP_SERVER" "$CLAUDE_SETTINGS" <<'PY'
import json,sys
p,sp,old=sys.argv[1],sys.argv[2],sys.argv[3]
d=json.load(open(p))
srv=d.setdefault("mcpServers",{})
changed=False
if "stitchpad" not in srv:
    srv["stitchpad"]={"type":"stdio","command":"node","args":[sp],"env":{}}
    changed=True
if changed:
    json.dump(d,open(p,"w"),indent=2)
# Clear the dead registration this installer used to write into settings.json.
# Only OUR entry, only when it is the whole of mcpServers, and only if the file
# parses — a user's other config is never touched.
try:
    s=json.load(open(old))
    m=s.get("mcpServers")
    if isinstance(m,dict) and set(m)=={"stitchpad"}:
        del s["mcpServers"]
        json.dump(s,open(old,"w"),indent=2)
        print("  (removed the dead mcpServers entry from settings.json)")
except Exception:
    pass
PY
  then echo "✓ Claude MCP stitchpad registered ($CLAUDE_JSON)"
  else _wire_fail "Claude MCP server registration — the merge into $CLAUDE_JSON failed"
  fi

  # Codex: ~/.codex/config.toml  [mcp_servers.stitchpad]
  CODEX_CONFIG="$HOME/.codex/config.toml"
  if [ -d "$HOME/.codex" ] || [ -f "$CODEX_CONFIG" ]; then
    [ -f "$CODEX_CONFIG" ] || { mkdir -p "$HOME/.codex"; touch "$CODEX_CONFIG"; }
    if ! grep -q '^\[mcp_servers\.stitchpad\]' "$CODEX_CONFIG" 2>/dev/null; then
      printf '\n[mcp_servers.stitchpad]\ncommand = "node"\nargs = ["%s"]\n' "$MCP_SERVER" >> "$CODEX_CONFIG"
      echo "✓ Codex MCP stitchpad registered ($CODEX_CONFIG)"
    fi
  fi
fi

# Pi: pi install the stitchpad extension (idempotent)
if command -v pi >/dev/null 2>&1; then
  pi install "$HOME_DIR/adapters/stitchpad" 2>/dev/null && echo "✓ Pi stitchpad extension installed" || echo "⚠  Pi extension install failed"
fi

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ -n "$WIRE_FAILED" ]; then
  echo "  ✗ stitchpad installed, but the wake wiring did NOT complete."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  These steps did not happen:"
  printf '%s\n' "$WIRE_FAILED"
  echo
  echo "  The CLI is linked and pads will work, but @mentions will NOT wake"
  echo "  anyone until the above is fixed. Fix it and re-run this installer."
else
  echo "  ✓ stitchpad installed — multi-agent collaboration is wired."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  # Echo back what actually got wired this run (detected, not assumed) so the
  # user sees a real system, not a TODO list. Each line only prints if present.
  echo "  Wired on this machine:"
  command -v claude >/dev/null 2>&1 && echo "    • Claude   — Stop wake + PreToolUse claim hook + MCP"
  command -v codex  >/dev/null 2>&1 && echo "    • Codex    — Stop wake hook + MCP"
  command -v pi     >/dev/null 2>&1 && echo "    • pi       — wake extension + MCP"
  command -v claude >/dev/null 2>&1 || command -v codex >/dev/null 2>&1 || command -v pi >/dev/null 2>&1 || \
    echo "    • (no claude/codex/pi runtime detected — install one, then re-run this)"
fi
echo
echo "  Start a room (in any project):"
echo "    stitchpad init                     # create the pad + start its watcher"
echo "    stitchpad join <you> <claude|codex|pi>"
echo "    export STITCHPAD_NAME=<you>        # so your wake hook knows who you are"
echo "    stitchpad say \"@teammate hello\"     # @mention wakes them"
echo "    stitchpad-tui                      # watch the room live"
echo
echo "  Optional — mirror every pad to the web PWA (login service, survives reboot):"
echo "    STITCHPAD_RELAY=<url> STITCHPAD_TOKEN=<tok> stitchpad bridge install"
echo
echo "  Verify any time:  stitchpad doctor"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# rc follows the ledger, not the last echo. An unattended installer that cannot
# wire the wake path must fail loudly enough for a script to notice.
[ -z "$WIRE_FAILED" ] || exit 1
