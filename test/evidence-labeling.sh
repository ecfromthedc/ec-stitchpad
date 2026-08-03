#!/usr/bin/env bash
# TASK-6 evidence-labeling regression: two different environments produce
# distinguishable stamps, identical candidates + environments compare equal.
#
# Acceptance stories this guards:
#   - glm ambient-sid   : session-var PRESENCE alters results → stamp records
#                         ambient session vars present (names only, no values)
#   - pro2 stderr-json  : toolchain variant (awk/python) changes output →
#                         stamp records awk + python versions
#   - glm sliceB 21/9   : counts with no env/candidate label were unverifiable
#                         → stamp binds counts' command + candidate SHA/tree
#   - flash2 awk-variance: TMPDIR shape (spaces) and awk variant changed
#                         behavior → stamp records tmpdir_shape + awk variant
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$ROOT/tool/bin/evidence-stamp"
tmp="$(mktemp -d /tmp/stitchpad-evidence.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home"

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { case "$1" in *"$2"*) return 0;; *) return 1;; esac; }

[ -x "$STAMP" ] || fail "evidence-stamp helper missing at $STAMP"

# Clean ambient session vars so absence is deterministic (a seat shell may
# export STITCHPAD_NAME etc.).
clean_env() {
  env -u STITCHPAD_NAME -u STITCHPAD_CWD -u STITCHPAD_SESSION \
      -u STITCHPAD_PAD_DIR -u SESSION_ID -u SP_DATE_DIVIDER_CLOCK "$@"
}

# --- 1) immutable candidate identity recorded from git reality --------------
sha="$(git -C "$ROOT" rev-parse HEAD)"
tree="$(git -C "$ROOT" rev-parse 'HEAD^{tree}')"
dirty="$(git -C "$ROOT" status --porcelain | head -1 || true)"
canon="$(clean_env TMPDIR="$tmp/plain" "$STAMP" --canonical)"
contains "$canon" "sha=$sha" || fail "candidate sha not recorded ($canon)"
contains "$canon" "tree=$tree" || fail "candidate tree not recorded ($canon)"
if [ -n "$dirty" ]; then
  contains "$canon" "dirty=yes" || fail "dirty tree not marked dirty"
else
  contains "$canon" "dirty=no" || fail "clean tree not marked clean"
fi

# --- 2) identical candidates + identical env → byte-identical, compare equal --
a="$(clean_env TMPDIR="$tmp/plain" "$STAMP" --canonical)"
b="$(clean_env TMPDIR="$tmp/plain" "$STAMP" --canonical)"
[ "$a" = "$b" ] || fail "identical env/candidate produced different stamps"
[ "$("$STAMP" --compare "$a" "$b")" = "equal" ] || fail "--compare rejected identical stamps"

# --- 3) different env → distinguishable: TMPDIR shape (spaces vs plain) ------
c="$(clean_env TMPDIR="$tmp/with space" "$STAMP" --canonical)"
[ "$c" != "$a" ] || fail "TMPDIR shape change did not alter the stamp"
contains "$a" "tmpdir_shape=plain" || fail "plain TMPDIR not labeled plain"
contains "$c" "tmpdir_shape=spaces" || fail "spaces TMPDIR not labeled spaces"
if "$STAMP" --compare "$a" "$c" >/dev/null 2>&1; then
  fail "--compare accepted differing stamps (TMPDIR shape)"
fi

# --- 4) different env → distinguishable: ambient session var PRESENCE --------
d1="$(clean_env TMPDIR="$tmp/plain" STITCHPAD_NAME=glm "$STAMP" --canonical)"
d0="$(clean_env TMPDIR="$tmp/plain" "$STAMP" --canonical)"
contains "$d1" "session_vars=" && contains "$d1" "STITCHPAD_NAME" \
  || fail "present ambient session var not recorded"
if contains "$d0" "STITCHPAD_NAME"; then
  fail "absent ambient session var recorded as present"
fi
[ "$d1" != "$d0" ] || fail "session-var presence change did not alter the stamp"
if "$STAMP" --compare "$d0" "$d1" >/dev/null 2>&1; then
  fail "--compare accepted differing stamps (session-var presence)"
fi

# --- 5) different env → distinguishable: awk + python variants via PATH ------
# Acceptance story: flash2 awk-variance / pro2 stderr-json — the same suite
# behaved differently under different awk/python toolchains. A fake toolchain
# earlier in PATH must show up as a distinct awk=/python= field.
fakebin="$tmp/fakebin"
mkdir -p "$fakebin"
cat > "$fakebin/awk" <<'EOF'
#!/usr/bin/env bash
printf 'awk version 9999-fake-variant\n'
EOF
cat > "$fakebin/python3" <<'EOF'
#!/usr/bin/env bash
printf 'Python 9.9.9-fake\n'
EOF
chmod +x "$fakebin/awk" "$fakebin/python3"

e="$(clean_env TMPDIR="$tmp/plain" PATH="$fakebin:$PATH" "$STAMP" --canonical)"
contains "$e" "awk=awk_version_9999-fake-variant" \
  || fail "fake awk variant not recorded"
contains "$e" "python=Python_9.9.9-fake" \
  || fail "fake python variant not recorded"
[ "$e" != "$a" ] || fail "toolchain variant change did not alter the stamp"
if "$STAMP" --compare "$a" "$e" >/dev/null 2>&1; then
  fail "--compare accepted differing stamps (toolchain variant)"
fi
# same fake env twice → reproducible (identical candidates compare equal)
e2="$(clean_env TMPDIR="$tmp/plain" PATH="$fakebin:$PATH" "$STAMP" --canonical)"
[ "$e" = "$e2" ] || fail "same fake toolchain env not reproducible"
[ "$("$STAMP" --compare "$e" "$e2")" = "equal" ] || fail "--compare rejected identical fake-env stamps"

# --- 6) suite runner emits the evidence header (retrofit hook) ---------------
# Mirrors test-runner.sh: a tmp tool/ with the helper + one trivial fixture.
# stitchpad sources date-divider.sh + session-registry.sh at startup, so they
# must ride along in the copy.
mkdir -p "$tmp/runtool/bin" "$tmp/runtool/test"
cp "$ROOT/tool/bin/stitchpad" "$ROOT/tool/bin/lib.sh" "$ROOT/tool/bin/evidence-stamp" \
   "$ROOT/tool/bin/date-divider.sh" "$ROOT/tool/bin/session-registry.sh" "$tmp/runtool/bin/"
cat > "$tmp/runtool/test/one.sh" <<'EOF'
#!/usr/bin/env bash
printf 'one ok\n'
EOF
chmod +x "$tmp/runtool/test/one.sh"
run_out="$(env -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_ENV \
  -u HERDR_SOCKET_PATH -u HERDR_WORKSPACE_ID \
  -u STITCHPAD_NAME -u STITCHPAD_CWD -u SESSION_ID \
  STITCHPAD_HOME="$tmp/runtool" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  "$tmp/runtool/bin/stitchpad" test 2>&1)"
contains "$run_out" '--- evidence ---' || fail "runner did not emit evidence header"
contains "$run_out" '# candidate: sha=' || fail "runner evidence header lacks candidate line"
contains "$run_out" "tree=" || fail "runner evidence header lacks candidate tree"
contains "$run_out" 'PASS: one.sh' || fail "runner did not run the fixture"
# runner degrades cleanly when the helper is absent
rm -f "$tmp/runtool/bin/evidence-stamp"
run_out2="$(env -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_ENV \
  -u HERDR_SOCKET_PATH -u HERDR_WORKSPACE_ID \
  -u STITCHPAD_NAME -u STITCHPAD_CWD -u SESSION_ID \
  STITCHPAD_HOME="$tmp/runtool" STITCHPAD_HEARTBEAT_AUTOSTART=0 \
  "$tmp/runtool/bin/stitchpad" test 2>&1)"
contains "$run_out2" 'PASS: one.sh' || fail "runner broke without evidence-stamp"
if contains "$run_out2" '--- evidence ---'; then
  fail "runner emitted evidence header with helper missing"
fi

echo "evidence labeling ok"
