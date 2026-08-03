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
#   $PAD_STATE/operator-grant.<seat>.<operation>  — created by a human, never
#   by a seat. Its content is an ISO timestamp + the operator's name. Its mere
#   existence authorizes ONE deployment operation; it is consumed (deleted)
#   after use. A seat may NEVER create its own grant file.
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
sp_scope_check_write() {
  local path="$1" seat manifest
  seat="$(_sp_scope_seat)"
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
      grant_file="$PAD_STATE/operator-grant.$seat.$operation"
      if [ ! -f "$grant_file" ]; then
        echo "stitchpad: AUTHORITY DENIED — @$seat has deploy authority but no operator grant for: $operation" >&2
        echo "  An operator must create: $grant_file" >&2
        echo "  Format: echo '<operator-name> <ISO-timestamp>' > $grant_file" >&2
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
