#!/usr/bin/env bash
# date-divider.sh — canonical date-divider insertion for stitchpad say.
# Source this from stitchpad; it expects PAD_MD, PAD_STATE to be set and
# the mutation lock to be held by the caller.
#
# Public API:
#   sp_date_divider_snapshot     → captures epoch + timezone once per operation
#   sp_date_divider_needed       → 0 if a divider for today is needed, 1 if exists
#   sp_date_divider_insert       → writes the divider line atomically to PAD_MD
#                                  (enforces monotonic last-divider rules)
#   sp_date_divider_line <epoch> <tz> → prints the divider text for inspection
#   sp_date_divider_hhmm         → formats HH:MM AM/PM from the captured epoch
#   sp_date_divider_epoch        → prints the captured epoch (for git timestamps)
#
# Timezone resolution (first wins):
#   1. STITCHPAD_TIMEZONE env var (IANA zone, e.g. America/New_York)
#   2. .state/timezone file (single-line IANA zone)
#   3. System local timezone (via Python zoneinfo or /etc/localtime)
#
# Clock injection for tests:
#   SP_DATE_DIVIDER_CLOCK=<epoch>  → use this fixed epoch instead of date +%s

_SP_DATE_EPOCH=""
_SP_DATE_TZ=""
_SP_DATE_DATE=""

# ── Safe epoch capture ─────────────────────────────────────────────────
# Uses SP_DATE_DIVIDER_CLOCK if set (test injection), otherwise date +%s.
_sp_divider_now_epoch() {
  if [ -n "${SP_DATE_DIVIDER_CLOCK:-}" ]; then
    printf '%s' "$SP_DATE_DIVIDER_CLOCK"
  else
    date +%s
  fi
}

# ── Timezone resolution (shared, safe) ─────────────────────────────────
_sp_divider_resolve_tz() {
  local tz="${STITCHPAD_TIMEZONE:-}"
  if [ -z "$tz" ] && [ -f "$PAD_STATE/timezone" ] && [ ! -L "$PAD_STATE/timezone" ]; then
    tz="$(head -c 256 "$PAD_STATE/timezone" 2>/dev/null | tr -d '\n\r' || true)"
  fi
  if [ -z "$tz" ]; then
    # Derive system timezone from /etc/localtime symlink (macOS/Linux).
    # zoneinfo.ZoneInfo("localtime") is NOT portable — it requires the optional
    # tzdata package and was removed from the final PEP 615 API.
    tz="$(python3 -c '
import os
tz = None
try:
    p = os.readlink("/etc/localtime")
    for prefix in ("/var/db/timezone/zoneinfo/", "/usr/share/zoneinfo/"):
        if p.startswith(prefix):
            tz = p[len(prefix):]
            break
except Exception:
    pass
if tz:
    print(tz)
else:
    # Fallback: try /etc/timezone (Debian/Ubuntu)
    try:
        with open("/etc/timezone") as f:
            tz = f.read(256).strip()
            if tz:
                print(tz)
    except Exception:
        pass
' 2>/dev/null || true)"
  fi
  printf '%s' "$tz"
}

# ── Validate and derive from one captured epoch ────────────────────────
# All values (date string, weekday, HH:MM) derive from this single epoch.
# TZ and epoch are passed via argv to Python — NEVER interpolated into the script.

# Capture one epoch snapshot per authored operation. Call at the top of `say`.
sp_date_divider_snapshot() {
  _SP_DATE_EPOCH=""
  _SP_DATE_TZ=""
  _SP_DATE_DATE=""
  if ! command -v python3 >/dev/null 2>&1; then
    echo "stitchpad: date-divider requires python3" >&2
    return 2
  fi

  local tz
  tz="$(_sp_divider_resolve_tz)"
  if [ -z "$tz" ]; then
    echo "stitchpad: cannot determine timezone for date divider" >&2
    return 2
  fi

  # Validate the IANA timezone name — passed via argv, not interpolated
  if ! python3 -c '
import zoneinfo, sys
try:
    zoneinfo.ZoneInfo(sys.argv[1])
except Exception:
    raise SystemExit(1)
' "$tz" 2>/dev/null; then
    echo "stitchpad: unknown timezone '$tz'" >&2
    return 2
  fi

  _SP_DATE_EPOCH="$(_sp_divider_now_epoch)"
  _SP_DATE_TZ="$tz"

  # Derive the canonical date string in that timezone (YYYY-MM-DD).
  # Epoch and TZ passed via argv, never interpolated.
  _SP_DATE_DATE="$(python3 -c '
from datetime import datetime, timezone as tzmod
import zoneinfo, sys
epoch = int(sys.argv[1])
z = zoneinfo.ZoneInfo(sys.argv[2])
dt = datetime.fromtimestamp(epoch, tz=z)
print(dt.strftime("%Y-%m-%d"))
' "$_SP_DATE_EPOCH" "$_SP_DATE_TZ" 2>/dev/null || true)"

  [ -n "$_SP_DATE_DATE" ] || return 2
  return 0
}

# Print the captured epoch (for git author/committer date alignment).
sp_date_divider_epoch() {
  printf '%s' "${_SP_DATE_EPOCH:-}"
}

# Format HH:MM AM/PM from the captured epoch (for the message header).
sp_date_divider_hhmm() {
  local epoch="${1:-$_SP_DATE_EPOCH}" tz="${2:-$_SP_DATE_TZ}"
  [ -n "$epoch" ] && [ -n "$tz" ] || return 1

  python3 -c '
from datetime import datetime
import zoneinfo, sys
epoch = int(sys.argv[1])
z = zoneinfo.ZoneInfo(sys.argv[2])
dt = datetime.fromtimestamp(epoch, tz=z)
# 12-hour clock with leading-zero hour and AM/PM: "08:30 AM"
print(dt.strftime("%I:%M %p"))
' "$epoch" "$tz"
}

# Format the divider line for a given epoch and IANA timezone.
#   *— YYYY-MM-DD (IANA-Zone) · Weekday —*
# Wrapped in asterisks for markdown italic rendering.
sp_date_divider_line() {
  local epoch="${1:-$_SP_DATE_EPOCH}" tz="${2:-$_SP_DATE_TZ}"
  [ -n "$epoch" ] && [ -n "$tz" ] || return 1

  # Epoch and TZ passed via argv — never interpolated.
  python3 -c '
from datetime import datetime, timezone as tzmod
import zoneinfo, sys
epoch = int(sys.argv[1])
z = zoneinfo.ZoneInfo(sys.argv[2])
dt = datetime.fromtimestamp(epoch, tz=z)
date_str = dt.strftime("%Y-%m-%d")
weekday = dt.strftime("%A")
# Asterisks for italic, em dash, space, date, space, paren-zone-paren, space,
# middle-dot, space, weekday, space, em dash, close asterisks
print(f"*\u2014 {date_str} ({z.key}) \u00b7 {weekday} \u2014*")
' "$epoch" "$tz"
}

# Check whether a date divider is needed: return 0 if the pad has no divider
# for the captured date, 1 if it already exists.
# Must be called AFTER sp_date_divider_snapshot.
sp_date_divider_needed() {
  [ -n "$_SP_DATE_DATE" ] || return 2
  [ -f "$PAD_MD" ] || return 0  # no pad yet, definitely needed (but pad is created by init)

  # Scan the pad for a divider matching today's date.
  # Format: *— YYYY-MM-DD (Zone) · Weekday —*
  # The date part is always at position 5-14 (after "*— ").
  local want="$_SP_DATE_DATE"
  if grep -q "^\*— ${want} (" "$PAD_MD" 2>/dev/null; then
    return 1  # already present
  fi
  return 0
}

# ── Last-divider monotonic tracking ────────────────────────────────────
# Stores the last-inserted divider's epoch in .state/last-divider-epoch.
# Enforces:
#   1. No backward clock drift (epoch must be >= last divider epoch).
#   2. First-authored message per canonical pad-local date inserts the divider.
#   3. A forward date change (new day) is always allowed, even if epoch is close.

_sp_divider_last_epoch() {
  local f="$PAD_STATE/last-divider-epoch"
  if [ -f "$f" ] && [ ! -L "$f" ]; then
    head -c 32 "$f" 2>/dev/null | tr -d '[:space:]' || true
  fi
}

_sp_divider_save_last_epoch() {
  local epoch="$1"
  printf '%s' "$epoch" > "$PAD_STATE/last-divider-epoch" 2>/dev/null || true
}

# Canonical date (YYYY-MM-DD) for an epoch in an IANA zone. Argv only.
_sp_divider_date_of() {
  python3 -c '
from datetime import datetime
import zoneinfo, sys
epoch = int(sys.argv[1])
z = zoneinfo.ZoneInfo(sys.argv[2])
dt = datetime.fromtimestamp(epoch, tz=z)
print(dt.strftime("%Y-%m-%d"))
' "$1" "$2" 2>/dev/null || true
}

# Insert the date divider atomically into PAD_MD. Must be called under the pad lock.
# Returns 0 on success, 1 if already present, 2 on error.
sp_date_divider_insert() {
  [ -n "$_SP_DATE_EPOCH" ] || return 2
  [ -n "$_SP_DATE_TZ" ] || return 2
  [ -f "$PAD_MD" ] || return 0  # no pad to insert into (shouldn't happen for say)

  # ── Monotonic enforcement (BEFORE the pad scan) ────────────────────
  # The locked last-divider epoch only moves forward. A backward clock is
  # tolerated within the same canonical date (late message, no new divider)
  # and refused across dates — never insert a divider for an older date.
  local last_epoch
  last_epoch="$(_sp_divider_last_epoch)"
  if [ -n "$last_epoch" ] && [ "$_SP_DATE_EPOCH" -lt "$last_epoch" ]; then
    local last_date
    last_date="$(_sp_divider_date_of "$last_epoch" "$_SP_DATE_TZ")"
    if [ "$last_date" = "$_SP_DATE_DATE" ]; then
      # Same date, backward clock — the divider for this date already exists.
      return 1
    fi
    echo "stitchpad: refusing date divider — captured epoch $_SP_DATE_EPOCH is before last divider epoch $last_epoch (date $_SP_DATE_DATE < $last_date)" >&2
    return 2
  fi

  # Double-check under lock: if another writer already inserted a divider for
  # this canonical date, skip. This — not the last-epoch state — is the
  # idempotence source of truth, so a pad that lacks today's divider still
  # gets one even when the last-divider epoch falls on the same date.
  if ! sp_date_divider_needed; then
    return 1  # already present
  fi

  # ── Insert the divider ─────────────────────────────────────────────
  local divider
  divider="$(sp_date_divider_line "$_SP_DATE_EPOCH" "$_SP_DATE_TZ")" || return 2
  [ -n "$divider" ] || return 2

  # Append the divider followed by a blank line.
  # This MUST be atomic with respect to the pad file. Since we hold the lock,
  # a simple >> append is safe — no other writer can interleave.
  printf '\n%s\n' "$divider" >> "$PAD_MD" || return 2

  # Record the last-divider epoch for monotonic enforcement.
  _sp_divider_save_last_epoch "$_SP_DATE_EPOCH"

  return 0
}
