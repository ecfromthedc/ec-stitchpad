#!/usr/bin/env bash
# stitchpad TUI — a live Slack-style terminal view of stitchpad.md.
# Re-renders on every change (fswatch). Color-codes each author, shows the roster
# rail and any unread pings. Read-only viewer; post with `stitchpad say`.
#
# Usage: stitchpad-tui   (or: tui.sh)   ·  q / Ctrl-C to quit
set -uo pipefail
_src="${BASH_SOURCE[0]}"; while [ -h "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"; _src="$(readlink "$_src")"
  [ "${_src#/}" = "$_src" ] && _src="$_dir/$_src"
done
BIN_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
source "$BIN_DIR/lib.sh"
sp_init_paths || { echo "no .stitchpad here"; exit 1; }

# Author colors: use 'stitchpad color' CLI (single source of truth).
# Outputs #rrggbb hex; convert to ANSI RGB escape.
color_for() {
  local hex; hex="$("$BIN_DIR/stitchpad" color "$1" 2>/dev/null)"
  hex="${hex###}"  # strip leading #
  local r=$((16#${hex:0:2})) g=$((16#${hex:2:2})) b=$((16#${hex:4:2}))
  printf '\033[38;2;%d;%d;%dm' "$r" "$g" "$b"
}
c()    { printf '\033[38;5;%sm' "$1"; }
dim()  { printf '\033[2m'; }
bold() { printf '\033[1m'; }
rst()  { printf '\033[0m'; }

render() {
  clear
  local cols; cols=$(tput cols 2>/dev/null || echo 100)
  local name="$(basename "$(dirname "$PAD_DIR")")"

  # Header
  bold; c 45; printf '  🧵 #%s' "$name"; rst
  dim; printf '   ·   live stitchpad   ·   q to quit\n'; rst
  printf '  '; printf '─%.0s' $(seq 1 $((cols-4))); printf '\n'

  # Roster rail
  printf '  '; dim; printf 'in the room: '; rst
  while IFS='|' read -r rname radapter rwake rtarget; do
    [ -n "$rname" ] || continue
    c "$(color_for "$rname")"; printf '@%s' "$rname"; rst
    dim; printf '(%s) ' "$radapter"; rst
  done < <(sp_roster)
  # unread pings?
  local pings; pings=$(ls "$PAD_STATE"/ping.* 2>/dev/null | wc -l | tr -d ' ')
  [ "$pings" -gt 0 ] && { c 203; bold; printf '  ● %s unread ping(s)' "$pings"; rst; }
  printf '\n'
  printf '  '; printf '─%.0s' $(seq 1 $((cols-4))); printf '\n\n'

  # Messages: parse "## @from · time" headers, render as chat bubbles.
  awk '
    /^```roster/ { skip=1; next }
    skip && /^```/ { skip=0; next }
    skip { next }
    /^## / {
      hdr=$0; sub(/^## /,"",hdr); print "\x01HDR\x01" hdr; next
    }
    /^# / { next }       # title
    /^> / { next }       # blockquote intro
    /^---/ { next }
    { print }
  ' "$PAD_MD" | {
    while IFS= read -r line; do
      if [[ "$line" == $'\x01HDR\x01'* ]]; then
        hdr="${line#$'\x01HDR\x01'}"
        # "@from · time"  or  "@from → @to · time"
        who="${hdr%% *}"; who="${who#@}"
        printf '\n  '; c "$(color_for "$who")"; bold; printf '%s' "${hdr%% ·*}"; rst
        dim; printf '  %s\n' "${hdr#*· }"; rst
      else
        [ -z "$line" ] && { printf '\n'; continue; }
        printf '      %s\n' "$line"
      fi
    done
  }
  printf '\n'
}

cleanup() { tput cnorm 2>/dev/null; printf '\n'; exit 0; }
trap cleanup INT TERM
tput civis 2>/dev/null   # hide cursor

render
# Re-render on any channel change; also poll keyboard for 'q'.
( fswatch -0 "$PAD_MD" | while read -r -d "" _; do echo R; done ) &
WATCHER=$!
trap 'kill $WATCHER 2>/dev/null; cleanup' INT TERM
last=$(stat -f %m "$PAD_MD" 2>/dev/null || stat -c %Y "$PAD_MD" 2>/dev/null || echo 0)
while true; do
  if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ] 2>/dev/null; then
    # bash 4+ fractional timeouts
    read -r -t 0.4 -n 1 key 2>/dev/null
  else
    # bash 3.2 (macOS default) only accepts integer -t; 1s is fine for UI poll
    read -r -t 1 -n 1 key 2>/dev/null
  fi
  if [ "${PIPESTATUS[0]:-1}" -eq 0 ]; then
    [ "$key" = "q" ] && break
  fi
  # re-render if file mtime changed
  cur=$(stat -f %m "$PAD_MD" 2>/dev/null || stat -c %Y "$PAD_MD" 2>/dev/null || echo 0)
  if [ "${cur:-0}" != "${last:-0}" ]; then render; last="$cur"; fi
done
kill $WATCHER 2>/dev/null
cleanup
