#!/bin/bash
# deepseek F6 reproduction: a duplicate roster row defeats the wake
# misdirection guard — the wake prints on the caller's terminal and burns the
# push seat's cursor.
set -u
RT="${1:-/Users/ecfromthedc/dev/rt/rt-stitchpad-prs/wt/tool}"
W="$(mktemp -d "${TMPDIR:-/tmp}/f6.XXXXXX")"
mkdir -p "$W/home" "$W/proj"
export HOME="$W/home" STITCHPAD_HEARTBEAT_AUTOSTART=0
unset CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID HERDR_PANE_ID 2>/dev/null || true
SP="$RT/bin/stitchpad"
run() { ( cd "$W/proj" && env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID STITCHPAD_NAME="$1" \
   STITCHPAD_TERMINAL_NAMESPACE=f6ns STITCHPAD_HEARTBEAT_AUTOSTART=0 "$SP" "${@:2}" ); }
run larry init >/dev/null 2>&1
run larry join larry cli pull - >/dev/null 2>&1
run dale  join dale  cli pull - >/dev/null 2>&1
PAD="$W/proj/.stitchpad/stitchpad.md"

echo "--- can join mint a SECOND row for a name that already exists?"
run dale join dale cli push sess-999; echo "  join rc=$?"
echo "  roster now:"; run larry roster 2>/dev/null | sed 's/^/    /'

echo "--- hand-edit the pad to carry an exact duplicate (the bridge/editor case)"
python3 - "$PAD" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
if s.count("dale | cli | push | sess-999")==0 and "dale|cli|push|sess-999" not in s:
    s=re.sub(r"(?m)^(dale \| cli \| pull \| -)$", r"\1\ndale | cli | push | sess-999", s, count=1)
    open(p,'w').write(s)
PY
echo "  roster now:"; run larry roster 2>/dev/null | sed 's/^/    /'
echo "  wake mode seen by the guard: [$(run larry whoami >/dev/null 2>&1; cd "$W/proj" && HOME="$HOME" "$SP" roster 2>/dev/null | awk -F'|' '$1=="dale"{print $3; exit}')]"

run larry say "@dale hello duplicate" >/dev/null 2>&1
echo "  seen.dale before: $(cat "$W/proj/.stitchpad/.state/seen.dale" 2>/dev/null || echo none)"
echo "--- larry (a third party) runs: stitchpad wake dale"
run larry wake dale; echo "  rc=$?"
echo "  seen.dale after : $(cat "$W/proj/.stitchpad/.state/seen.dale" 2>/dev/null || echo none)"
rm -rf "$W"
