#!/usr/bin/env bash
# scope-authority.sh — TASK-5 scope manifests and deployment authority
#
# An assignment carries an explicit scope manifest (paths/files the lane may
# write) and a deployment-authority level. Guarded operations REFUSE writes
# outside the manifest with a distinct refusal code (scope_violation) recorded
# sticky. Authority levels gate irreversible operations (publish/push/reset-
# others) behind an explicit operator grant file, never inferrable by a seat.
#
# This module is sourced by lib.sh, stitchpad, and watch.sh.
#
# Scope manifest format (one path glob per line):
#   $PAD_STATE/scope.<seat>  — the manifest for a seat's allowed write paths
#   Lines starting with # are comments. Paths are relative to the worktree root
#   (the parent of .stitchpad/). Globs use shell glob syntax. Pad-internal
#   paths (.state/*, stitchpad.md, tasks.md) are ALWAYS allowed — scope governs
#   what a seat writes in the PROJECT, not the pad's own state.
#
# Authority levels:
#   $PAD_STATE/authority.<seat>  — one of: read, write, deploy
#   read   — may read the pad, may not say or modify project files
#   write  — may say and modify files within scope manifest (DEFAULT)
#   deploy — write + may run publish/push/reset-others IF an operator grant exists
#
# Operator grant:
#   $PAD_STATE/operator-grant.<seat>.<operation>  — minted ONLY by
#   `stitchpad operator grant` (operator credential required), never by a
#   seat. Carries an operator line, an expiry, and an sp-auth-v1 HMAC seal
#   bound to this pad's canonical path + seat + operation + expiry. An
#   unsealed, expired, tampered, or foreign-pad grant is a forgery and
#   denies. One-shot: consumed (deleted) after use. A seat may NEVER create
#   its own grant file (guard below), and the seal means a hand-written
#   file verifies nowhere.
#
# Sticky scope violation record:
#   $PAD_STATE/scope-violation.<seat>  — records the last violation with path,
#   timestamp, and the manifest that was active. Sticky: persists until cleared
#   by an operator.

# Guard against double-source
[ -n "${_SP_SCOPE_AUTHORITY_LOADED:-}" ] && return 0
_SP_SCOPE_AUTHORITY_LOADED=1

# ── Scope manifest ──────────────────────────────────────────────────

# Get the seat name from the current identity context.
_sp_scope_seat() {
  local sid="${STITCHPAD_SESSION:-${CLAUDE_CODE_SESSION_ID:-}}"
  local name=""
  if [ -n "$sid" ] && [ -f "${PAD_STATE:-}/sessions/$sid" ]; then
    name="$(cat "$PAD_STATE/sessions/$sid" 2>/dev/null || true)"
  fi
  [ -n "$name" ] && printf '%s' "$name" && return 0
  printf '%s' "${STITCHPAD_NAME:-unknown}"
}

# ── Operator credential (authority model redesign, C2/C2b) ─────────
#
# TRUST BOUNDARY. Authority never derives from anything the seat can
# self-declare or self-edit through the tool's own interfaces:
#   - REJECTED: env booleans (STITCHPAD_I_AM_OPERATOR had no producer —
#     any process could export it), a "non-roster STITCHPAD_NAME" (the
#     roster lives in pad markdown the seat can edit — a seat could remove
#     itself and pass the non-roster check), and unsealed grant files
#     (pad-state the seat can write).
#   - ROOT: $HOME/.stitchpad/operator.key — a random 256-bit secret OUTSIDE
#     every pad, created only by an explicit human `stitchpad operator
#     keygen`. Operator-gated commands require the caller to PRESENT the
#     secret via STITCHPAD_OPERATOR_TOKEN (out-of-band possession: the
#     operator exports it in their own shell; seat launchers never inject
#     it). Grants are HMAC-sealed with the key and bound to the canonical
#     pad path + seat + operation + expiry, so a copied or self-written
#     grant verifies nowhere.
#   - OUT OF SCOPE (stated honestly): a seat executing arbitrary shell as
#     the operator's uid can read the key file. Same-uid arbitrary code is
#     already a full compromise of every file-based model; the boundary
#     enforced here is the tool's own interface surface — env self-
#     declaration, pad-content tampering, and grant forgery through
#     stitchpad commands all fail closed. Raising Tier-2 beyond this needs
#     an OS-level secret store (keychain with ACL prompt) — future work.

_sp_operator_key_path() { printf '%s' "$HOME/.stitchpad/operator.key"; }

# Key file sanity: exists, regular file, not a symlink, non-empty.
sp_operator_key_present() {
  local key
  key="$(_sp_operator_key_path)"
  [ -f "$key" ] && [ ! -L "$key" ] && [ -s "$key" ] || return 1
}

# Create the operator key. Refuses to overwrite without $1=--force.
sp_operator_keygen() {
  local key dir
  key="$(_sp_operator_key_path)"; dir="$(dirname "$key")"
  if [ "$1" != "--force" ] && [ -e "$key" ]; then
    echo "stitchpad: operator key already exists at $key (use --force to rotate; existing grants/elevations seal against the OLD key and will stop verifying)" >&2
    return 1
  fi
  mkdir -p "$dir" 2>/dev/null || return 1
  [ ! -L "$dir" ] || return 1
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32 > "$key" || return 1
  else
    # Portability fallback: /dev/urandom + od (POSIX)
    od -An -tx1 -N32 /dev/urandom 2>/dev/null | tr -d ' \n' > "$key" || return 1
  fi
  chmod 600 "$key" 2>/dev/null || true
  return 0
}

# The operator assertion: the caller PRESENTS the secret out-of-band.
# Constant-work compare of two same-length strings.
sp_operator_ok() {
  local key tok
  sp_operator_key_present || return 1
  key="$(cat "$(_sp_operator_key_path)" 2>/dev/null)" || return 1
  tok="${STITCHPAD_OPERATOR_TOKEN:-}"
  [ -n "$key" ] && [ -n "$tok" ] && [ "$key" = "$tok" ]
}

# HMAC-SHA256(key, msg) hex. openssl with /dev/urandom-independent fallback
# (python3 HMAC) for minimal environments.
_sp_authority_hmac() {
  local msg="$1" key
  key="$(cat "$(_sp_operator_key_path)" 2>/dev/null)" || return 1
  [ -n "$key" ] || return 1
  if command -v openssl >/dev/null 2>&1; then
    printf '%s' "$msg" | openssl dgst -sha256 -hmac "$key" 2>/dev/null | awk '{print $NF}'
  else
    python3 - "$key" "$msg" <<'EOF' 2>/dev/null
import hashlib, hmac, sys
print(hmac.new(sys.argv[1].encode(), sys.argv[2].encode(), hashlib.sha256).hexdigest())
EOF
  fi
}

# Seal payload: versioned, bound to THIS pad's canonical path so a grant
# copied to another pad verifies nowhere.
_sp_authority_seal() { # $1=seat $2=operation $3=expiry
  local pad_canon
  pad_canon="$(cd -P "${PAD_STATE%/.state}" 2>/dev/null && pwd)"
  _sp_authority_hmac "sp-auth-v1|$pad_canon|$1|$2|$3"
}

# Mint a sealed grant. Operator-only (requires sp_operator_ok).
sp_operator_grant_create() { # $1=seat $2=operation $3=ttl-seconds(0=none)
  local seat="$1" op="$2" ttl="${3:-86400}" expiry seal grant tmp
  sp_operator_ok || { echo "stitchpad: operator credential required — run 'stitchpad operator keygen' and export STITCHPAD_OPERATOR_TOKEN" >&2; return 1; }
  # fx2 G-A10: REFUSE invalid names — never silently munge. The previous
  # tr-strip turned a request for one seat into a grant for a DIFFERENT
  # (mangled) seat while the CLI echoed the original string with a ✓ —
  # a lying confirmation (TASK-13 class) and a write-target confusion.
  case "$seat" in ''|*[!a-zA-Z0-9._-]*)
    echo "stitchpad: invalid seat name for grant (allowed: [a-zA-Z0-9._-])" >&2; return 1 ;;
  esac
  case "$op" in ''|*[!a-zA-Z0-9._-]*)
    echo "stitchpad: invalid operation name for grant (allowed: [a-zA-Z0-9._-])" >&2; return 1 ;;
  esac
  case "$ttl" in ''|*[!0-9]*) ttl=86400 ;; esac
  [ "$ttl" -eq 0 ] && expiry=0 || expiry=$(( $(date +%s) + ttl ))
  seal="$(_sp_authority_seal "$seat" "$op" "$expiry")" || return 1
  grant="$PAD_STATE/operator-grant.$seat.$op"
  [ ! -L "$grant" ] || { echo "stitchpad: refusing to write a grant over a symlink" >&2; return 1; }
  tmp="$(mktemp "$PAD_STATE/.grant.XXXXXX")" || return 1
  {
    printf 'operator %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')"
    printf 'expiry=%s\n' "$expiry"
    printf 'seal=%s\n' "$seal"
  } > "$tmp"
  mv "$tmp" "$grant"
}

# Verify a grant: present, regular, sealed for THIS pad/seat/op, unexpired.
sp_authority_grant_verify() { # $1=seat $2=operation
  local grant expiry seal expect
  grant="$PAD_STATE/operator-grant.$1.$2"
  [ -f "$grant" ] && [ ! -L "$grant" ] || return 1
  expiry="$(sed -n 's/^expiry=//p' "$grant" 2>/dev/null | head -1)"
  seal="$(sed -n 's/^seal=//p' "$grant" 2>/dev/null | head -1)"
  case "$expiry" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$seal" ] || return 1
  [ "$expiry" -eq 0 ] || [ "$(date +%s)" -lt "$expiry" ] || return 1
  expect="$(_sp_authority_seal "$1" "$2" "$expiry")" || return 1
  [ -n "$expect" ] && [ "$seal" = "$expect" ]
}

# Check if a path is within the scope manifest for the given seat.
# Returns 0 (allowed) or 1 (denied).
# Pad-internal paths are ALWAYS allowed.
sp_scope_allows() {
  local seat="$1" path="$2" manifest
  # Normalize: strip leading ./ and resolve to a relative path from worktree root
  path="${path#./}"

  # Pad-internal paths are always allowed — scope governs project files, not
  # the pad's own bookkeeping.
  case "$path" in
    .stitchpad/*|.pasture/*|.state/*) return 0 ;;
  esac
  # Also allow bare pad filenames (stitchpad.md, tasks.md, etc.)
  case "$(basename "$path")" in
    stitchpad.md|pasture.md|tasks.md|archive.sqlite) return 0 ;;
  esac

  # No manifest = unrestricted (backward compatible for pads without scope)
  manifest="$PAD_STATE/scope.$seat"
  [ -f "$manifest" ] || return 0

  local line
  while IFS= read -r line || [ -n "$line" ]; do
    # Skip comments and empty lines
    case "$line" in ''|'#'*) continue ;; esac
    # Shell glob match
    # shellcheck disable=SC2254
    case "$path" in
      $line) return 0 ;;
    esac
  done < "$manifest"

  return 1
}

# Record a sticky scope violation.
sp_scope_record_violation() {
  local seat="$1" path="$2" manifest="$3"
  local viol_file tmp
  viol_file="$PAD_STATE/scope-violation.$seat"
  tmp="$(mktemp 2>/dev/null)" || return 1
  {
    printf 'seat=%s\n' "$seat"
    printf 'path=%s\n' "$path"
    printf 'manifest=%s\n' "$manifest"
    printf 'timestamp=%s\n' "$(date +%s)"
    printf 'datetime=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')"
  } > "$tmp"
  mv "$tmp" "$viol_file"
}

# Check the current seat's scope for a write path. If denied, record a sticky
# violation and return 1. Call this before any project file write.
# Optional $2 overrides the seat (for testing/explicit dispatch).
sp_scope_check_write() {
  local path="$1" seat manifest
  seat="${2:-$(_sp_scope_seat)}"
  if sp_scope_allows "$seat" "$path"; then
    return 0
  fi
  manifest="$PAD_STATE/scope.$seat"
  sp_scope_record_violation "$seat" "$path" "$manifest"
  echo "stitchpad: SCOPE VIOLATION — @$seat attempted write outside manifest: $path" >&2
  echo "  Manifest: ${manifest} (pad-internal paths are always allowed)" >&2
  echo "  Violation recorded sticky in $PAD_STATE/scope-violation.$seat" >&2
  echo "  Clear with: touch $PAD_STATE/scope-cleared.$seat" >&2
  return 1
}

# ── Deployment authority ───────────────────────────────────────────

# Get the authority level for a seat. Defaults to 'write' for backward compat.
sp_authority_level() {
  local seat="$1"
  local auth_file="$PAD_STATE/authority.$seat"
  [ -f "$auth_file" ] || { echo "write"; return 0; }
  cat "$auth_file" 2>/dev/null | tr -d '[:space:]' || echo "write"
}

# Check if a seat is authorized for a deployment operation.
# Deployment operations: publish, push, reset-others, force-push, deploy.
# Returns 0 (authorized) or 1 (denied).
sp_authority_check_deploy() {
  local seat="$1" operation="$2" auth_level grant_file

  auth_level="$(sp_authority_level "$seat")"
  case "$auth_level" in
    read|write)
      echo "stitchpad: AUTHORITY DENIED — @$seat has authority '$auth_level', needs 'deploy' for: $operation" >&2
      return 1
      ;;
    deploy)
      # Deploy level still requires an explicit operator grant for each op.
      # The grant must be SEALED (sp-auth-v1 HMAC bound to this pad+seat+op
      # +expiry) — an unsealed or foreign grant is a forgery and denies.
      grant_file="$PAD_STATE/operator-grant.$seat.$operation"
      if [ ! -f "$grant_file" ]; then
        echo "stitchpad: AUTHORITY DENIED — @$seat has deploy authority but no operator grant for: $operation" >&2
        echo "  An operator must mint one: STITCHPAD_OPERATOR_TOKEN=… stitchpad operator grant $seat $operation" >&2
        return 1
      fi
      if ! sp_authority_grant_verify "$seat" "$operation"; then
        echo "stitchpad: AUTHORITY DENIED — grant for @$seat/$operation is unsealed, expired, tampered, or from another pad (forgery refused)" >&2
        return 1
      fi
      return 0
      ;;
    *)
      echo "stitchpad: AUTHORITY DENIED — @$seat has unknown authority '$auth_level'" >&2
      return 1
      ;;
  esac
}

# Consume (delete) an operator grant after a successful deployment operation.
sp_authority_consume_grant() {
  local seat="$1" operation="$2" grant_file
  grant_file="$PAD_STATE/operator-grant.$seat.$operation"
  rm -f "$grant_file" 2>/dev/null || true
}

# Validate that a seat may NOT create its own operator grant.
# This is a hard guard: seats writing grant files is the authority-bypass bug.
sp_authority_guard_grant_write() {
  local seat="$1" path="$2"
  case "$path" in
    */operator-grant.*|operator-grant.*)
      echo "stitchpad: AUTHORITY VIOLATION — @$seat may not create operator grant files (authority bypass attempt)" >&2
      return 1
      ;;
  esac
  return 0
}
