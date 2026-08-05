#!/usr/bin/env bash
# p28-herdr-parity-gate.sh — P28: the product must work THROUGH herdr, not only
# with herdr switched off.
#
# THE FINDING THIS GATE EXISTS TO STOP:
#   37 of 77 suites open by unsetting HERDR_PANE_ID / HERDR_TAB_ID / HERDR_ENV /
#   HERDR_SOCKET_PATH / HERDR_WORKSPACE_ID, and regression-tripwire's run_suite()
#   blanks those same five for EVERY suite it runs. So 100% of enforcement ran
#   against the CLI path and 0% against the integration path production uses.
#   sp_this_surface() PREFERS HERDR_PANE_ID and only falls back to session ids —
#   and every terminal-identity defect found this build (P12 ambient session
#   identity, P27 stolen terminal) lived in that fallback. A product that only
#   works with its own integration disabled is not shipped.
#
#     G1  core flow completes with HERDR unset
#     G2  core flow completes with HERDR set
#     G3  PARITY: the two transcripts agree, step for step
#     G4  MUTANT: an unstable surface under HERDR must turn this gate RED
#
# SCOPE, STATED HONESTLY:
#   The gate sets a SYNTHETIC pane id. It deliberately does NOT bind to a live
#   herdr pane, because a fixture that claims the operator's real pane IS P27.
#   It exercises the pane-id branch of sp_this_surface() — where P12 and P27
#   both lived — not the `herdr pane get` branch, which needs a real pane and is
#   covered by hand in the dogfood record.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
export STITCHPAD_HEARTBEAT_AUTOSTART=0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/p28-herdr.XXXXXX")" || { echo "mkdtemp failed" >&2; exit 1; }
cleanup() { _rc=$?; rm -rf "$TMP" 2>/dev/null || true; return $_rc; }
trap cleanup EXIT

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

# ── the core flow ───────────────────────────────────────────────────────────
# $1=label $2="herdr"|"cli" $3=STITCHPAD_HOME (so the mutant can swap lib.sh).
# Emits one "step=rc" line per step so the two runs diff exactly. A failed step
# is recorded, never fatal — divergence must surface as a transcript difference.
core_flow() {
  local label="$1" mode="$2" home="$3"
  local dir="$TMP/$label" out rc
  mkdir -p "$dir/project" "$dir/home"
  (
    cd "$dir/project"
    export STITCHPAD_HOME="$home"
    export HOME="$dir/home"
    export PATH="$home/bin:$PATH"
    export STITCHPAD_HEARTBEAT_AUTOSTART=0
    # Both runs start from the SAME identity baseline: the runner's own session
    # env is the P12 leak, and leaving it in would make HERDR not the only
    # variable under test.
    unset CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID
    # Identity binds to the SESSION, and the CLI `join` deliberately does not
    # bind one — its own refusal says "set STITCHPAD_NAME for CLI/testing". So
    # this fixture uses the documented CLI identity path, exactly like every
    # other suite in test/. Both runs get the SAME session and name, so the ONLY
    # variable under test is HERDR_*.
    export STITCHPAD_SESSION="p28session"
    export STITCHPAD_NAME="alpha"
    export STITCHPAD_TERMINAL_NAMESPACE="p28-$label"
    if [ "$mode" = "herdr" ]; then
      export HERDR_PANE_ID="p28synthetic:pane$$"
      export HERDR_TAB_ID="p28synthetic:tab$$"
      export HERDR_WORKSPACE_ID="p28synthetic"
      export HERDR_ENV=1
      export HERDR_SOCKET_PATH="$dir/home/nonexistent.sock"
    else
      unset HERDR_PANE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH HERDR_WORKSPACE_ID
    fi
    step() { local name="$1"; shift
      set +e; out="$("$@" 2>&1)"; rc=$?; set -e
      printf '%s=%s\n' "$name" "$rc"; }
    contains() { local name="$1" needle="$2"; shift 2
      set +e; out="$("$@" 2>&1)"; rc=$?; set -e
      if printf '%s' "$out" | grep -qF "$needle"; then printf '%s=ok\n' "$name"
      else printf '%s=MISSING(rc=%s)\n' "$name" "$rc"; fi; }

    step     init     "$SP" init --name "p28$label"
    step     join     "$SP" join alpha claude pull -
    step     say      "$SP" say "hello from p28"
    contains read     "hello from p28" "$SP" read --new
    step     tasknew  "$SP" task new "T-1" --to alpha
    contains tasklist "T-1"            "$SP" task list
    contains roster   "alpha"          "$SP" roster
    step     doctor   "$SP" doctor
  ) 2>/dev/null
}

echo "=== P28: herdr parity gate ==="
echo ""
CLI_OUT="$(core_flow cli   cli   "$ROOT/tool" || true)"
HRD_OUT="$(core_flow herdr herdr "$ROOT/tool" || true)"

echo "--- HERDR unset (the path 37 suites test) ---"
printf '%s\n' "$CLI_OUT" | sed 's/^/      /'
echo "--- HERDR set (the path production uses) ---"
printf '%s\n' "$HRD_OUT" | sed 's/^/      /'
echo ""

_cli_bad="$(printf '%s' "$CLI_OUT" | grep -cvE '=(0|ok)$' || true)"
_hrd_bad="$(printf '%s' "$HRD_OUT" | grep -cvE '=(0|ok)$' || true)"

if [ -n "$CLI_OUT" ] && [ "${_cli_bad:-1}" -eq 0 ]; then
  ok "G1: core flow completes with HERDR unset"
else
  bad "G1: core flow with HERDR unset had ${_cli_bad} bad step(s)"
fi
if [ -n "$HRD_OUT" ] && [ "${_hrd_bad:-1}" -eq 0 ]; then
  ok "G2: core flow completes with HERDR SET (the real integration path)"
else
  bad "G2: core flow with HERDR SET had ${_hrd_bad} bad step(s) — the product works only with its integration disabled"
fi
if [ "$CLI_OUT" = "$HRD_OUT" ]; then
  ok "G3: PARITY — both paths agree step for step"
else
  bad "G3: PARITY BROKEN — herdr path diverges from CLI path"
  diff <(printf '%s\n' "$CLI_OUT") <(printf '%s\n' "$HRD_OUT") | sed 's/^/        /' || true
fi

# ── G4/G5: SURFACE STABILITY under HERDR (the invariant, asserted directly) ──
# The first mutant attempt — varying the pane surface per process — changed
# nothing observable in the core flow, and that is itself the finding: an
# unstable surface does not make commands FAIL, it makes sp_term_lock_check find
# no claim and silently stop enforcing one-terminal-one-pad. A guard that quietly
# stops guarding cannot be caught by watching exit codes, so assert the invariant
# itself: with a FIXED HERDR_PANE_ID, two separate processes must resolve the
# SAME surface. That is precisely the property P12 and P27 violated.
surface_of() { # $1=tool root
  env -u CLAUDE_CODE_SESSION_ID -u CODEX_SESSION_ID -u STITCHPAD_SESSION \
      HERDR_PANE_ID="p28synthetic:paneFIXED" HERDR_TAB_ID="p28synthetic:tabFIXED" \
      HERDR_ENV=1 HERDR_WORKSPACE_ID="p28synthetic" \
      bash -c 'source "$1/bin/lib.sh" >/dev/null 2>&1; sp_this_surface' _ "$1" 2>/dev/null
}

S1="$(surface_of "$ROOT/tool")"; S2="$(surface_of "$ROOT/tool")"
if [ -n "$S1" ] && [ "$S1" = "$S2" ]; then
  ok "G4: herdr surface is STABLE across processes ($S1)"
else
  bad "G4: herdr surface is UNSTABLE across processes ('$S1' vs '$S2') — the terminal guard silently stops enforcing"
fi

MUT="$TMP/mutant-tool"
cp -R "$ROOT/tool" "$MUT"
python3 - "$MUT/bin/lib.sh" <<'PY_MUT'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = '    [ -n "$_p" ] && _s="pane-$_p"'
new = '    [ -n "$_p" ] && _s="pane-$_p-$$"   # MUTANT: surface varies per process'
assert s.count(old) == 1, "mutant anchor not found (count=%d)" % s.count(old)
open(p, 'w', encoding='utf-8').write(s.replace(old, new))
PY_MUT
if grep -q 'MUTANT: surface varies per process' "$MUT/bin/lib.sh"; then
  M1="$(surface_of "$MUT")"; M2="$(surface_of "$MUT")"
  if [ "$M1" != "$M2" ]; then
    ok "G5: MUTANT — per-process surface drift is DETECTED ('$M1' vs '$M2'), gate bites"
  else
    bad "G5: MUTANT applied but drift not detected — this gate cannot see a broken herdr surface"
  fi
else
  bad "G5: MUTANT DID NOT APPLY — inconclusive, never treat as a pass"
fi

# ── G6/G7: P35+P37 — a managed-terminal join must LEAVE YOU WITH AN IDENTITY ──
# Before this, `join` inside a herdr pane returned 0 and printed "joined", then
# `whoami` was EMPTY and `say` refused with "no identity". Two causes:
#   · join left target "-", and sp_me resolves a pane to a roster row by matching
#     the surface against the TARGET column — so nothing matched;
#   · `whoami` only ever read the session binding, never the full resolver, so
#     even once sp_me could resolve it, "who am I" answered nothing.
# NO STITCHPAD_NAME anywhere below — that is the whole point.
identity_probe() { # $1=tool root → "whoami=<name> say=<rc>"
  local root="$1" d="$TMP/ident-$(basename "$1")"
  mkdir -p "$d/project" "$d/home"
  ( cd "$d/project"
    export STITCHPAD_HOME="$root" HOME="$d/home" PATH="$root/bin:$PATH"
    export STITCHPAD_HEARTBEAT_AUTOSTART=0
    unset STITCHPAD_NAME STITCHPAD_SESSION CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID
    export STITCHPAD_TERMINAL_NAMESPACE="p28-ident-$(basename "$root")"
    export HERDR_PANE_ID="p28ident:pane$$" HERDR_TAB_ID="p28ident:tab$$"
    export HERDR_WORKSPACE_ID="p28ident" HERDR_ENV=1
    "$root/bin/stitchpad" init --name p28ident >/dev/null 2>&1
    "$root/bin/stitchpad" join identbot claude pull - >/dev/null 2>&1
    _w="$("$root/bin/stitchpad" whoami 2>/dev/null || true)"
    "$root/bin/stitchpad" say "identity probe" >/dev/null 2>&1; _s=$?
    printf 'whoami=%s say=%s\n' "${_w:-<empty>}" "$_s"
  ) 2>/dev/null
}

IDENT="$(identity_probe "$ROOT/tool")"
echo "--- managed-terminal identity (no STITCHPAD_NAME) ---"
echo "      $IDENT"
if printf '%s' "$IDENT" | grep -q 'whoami=identbot' && printf '%s' "$IDENT" | grep -q 'say=0'; then
  ok "G6: a managed-terminal join leaves you with a working identity"
else
  bad "G6: join in a managed pane left no usable identity ($IDENT)"
fi

MUT2="$TMP/mutant-ident"
cp -R "$ROOT/tool" "$MUT2"
_BIND_LINE='[ -n "$_join_surface" ] && target="$_join_surface"'
grep -vF "$_BIND_LINE" "$ROOT/tool/bin/stitchpad" > "$MUT2/bin/stitchpad"
chmod +x "$MUT2/bin/stitchpad"
if ! grep -qF "$_BIND_LINE" "$MUT2/bin/stitchpad"; then
  IDENT_MUT="$(identity_probe "$MUT2")"
  echo "      MUTANT: $IDENT_MUT"
  if printf '%s' "$IDENT_MUT" | grep -q 'whoami=identbot'; then
    bad "G7: MUTANT still resolved an identity — this gate cannot see the regression"
  else
    ok "G7: MUTANT — without the terminal binding the pane has no identity, gate bites"
  fi
else
  bad "G7: MUTANT DID NOT APPLY — inconclusive, never treat as a pass"
fi

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
