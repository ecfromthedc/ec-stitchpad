#!/usr/bin/env bash
# golden-harness — characterization goldens for the sp_engagement oracle.
#
# Usage:
#   test/golden/harness.sh capture <corpus.md> <out.tsv>
#     Runs sp_engagement for every (seat, since) tuple over the corpus
#     and writes a golden TSV.
#
#   test/golden/harness.sh diff <corpus.md> <golden.tsv>
#     Re-runs sp_engagement against the corpus and diffs the stored golden.
#     Exit 0 = byte-identical. Exit 1 = diff found (prints it).
#
#   test/golden/harness.sh all
#     Captures all corpus files under test/golden/ and diffs them against
#     existing goldens. Exit 0 if all match, 1 if any differ.
#
# Goldens are CHANGE DETECTORS, not correctness oracles. A changed golden
# means PROVE which side is right — never re-bless the file without that proof.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STITCHPAD_HOME="${STITCHPAD_HOME:-}"
[ -n "$STITCHPAD_HOME" ] || STITCHPAD_HOME="$(cd "$SCRIPT_DIR/../../tool" && pwd)"

# Set PAD_DIR before sourcing lib.sh — its init code needs it.
# Use a transient directory so the harness never touches repo state.
PAD_TMP="$(mktemp -d "${TMPDIR:-/tmp}/golden-pad.XXXXXX")"
export PAD_DIR="$PAD_TMP/.stitchpad"
mkdir -p "$PAD_DIR/.state" "$PAD_DIR" 2>/dev/null || true
touch "$PAD_DIR/stitchpad.md"  # lib.sh init looks for stitchpad.md or pasture.md

. "$STITCHPAD_HOME/bin/lib.sh"

# ── helpers ──────────────────────────────────────────────────────────
# We re-export PAD_MD to point at the actual corpus for sp_engagement/sp_roster.
set_pad() {
  local corpus="$1"
  PAD_MD="$(cd "$(dirname "$corpus")" && pwd)/$(basename "$corpus")"
  export PAD_MD
  PAD_STATE="$PAD_DIR/.state"
}

total_ordinals() {
  grep -c '^## ' "$PAD_MD" 2>/dev/null || echo 0
}

roster_names() {
  sp_roster 2>/dev/null | cut -d'|' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^#' | grep -v '^$'
}

run_oracle() {
  local seat="$1" since="$2" ord sender lr rt
  read -r ord sender lr rt <<<"$(sp_engagement "$seat" "$since" 2>/dev/null)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$seat" "$since" "${ord:-0}" "${sender:-}" "${lr:-0}" "${rt:-}"
}

# ── capture ──────────────────────────────────────────────────────────
capture() {
  local corpus="$1" n_ord ordinals seats seat since
  set_pad "$corpus"

  n_ord=$(total_ordinals)
  ordinals=$((n_ord > 0 ? n_ord : 0))

  printf 'seat\tsince\tordinal\tsender\tlast_reply\treply_target\n'

  seats="$(roster_names)"
  if [ -z "$seats" ]; then
    echo "WARNING: no roster seats found in $corpus" >&2
    return 0
  fi

  for seat in $seats; do
    for since in $(seq 0 "$ordinals"); do
      run_oracle "$seat" "$since"
    done
  done
}

# ── diff ─────────────────────────────────────────────────────────────
diff_golden() {
  local corpus="$1" golden="$2" tmp fresh
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/golden-diff.XXXXXX")"
  fresh="$tmp/fresh.tsv"
  capture "$corpus" > "$fresh" 2>/dev/null

  if diff -u "$golden" "$fresh" > "$tmp/diff.out" 2>&1; then
    rm -rf "$tmp"
    return 0
  else
    cat "$tmp/diff.out" >&2
    rm -rf "$tmp"
    return 1
  fi
}

# ── all ──────────────────────────────────────────────────────────────
run_all() {
  local md tsv failed=0 total=0
  for md in "$SCRIPT_DIR"/synthetic/*.md "$SCRIPT_DIR"/live/*.md; do
    [ -f "$md" ] || continue
    tsv="${md%.md}.tsv"
    if [ ! -f "$tsv" ]; then
      echo "SKIP $md — no golden yet (run 'capture' first)"
      continue
    fi
    total=$((total + 1))
    if diff_golden "$md" "$tsv"; then
      echo "OK   $(basename "$md")"
    else
      echo "FAIL $(basename "$md")"
      failed=$((failed + 1))
    fi
  done
  echo ""
  echo "$total checked, $failed failed"
  return "$failed"
}

# ── dispatch ─────────────────────────────────────────────────────────
cmd="${1:-}"; arg1="${2:-}"; arg2="${3:-}"
case "$cmd" in
  capture)
    [ -n "$arg2" ] || { echo "usage: harness.sh capture <corpus.md> <out.tsv>" >&2; exit 2; }
    [ -f "$arg1" ] || { echo "corpus not found: $arg1" >&2; exit 2; }
    capture "$arg1" > "$arg2"
    echo "captured $(wc -l < "$arg2") lines (incl. header) to $arg2"
    ;;
  diff)
    [ -n "$arg2" ] || { echo "usage: harness.sh diff <corpus.md> <golden.tsv>" >&2; exit 2; }
    [ -f "$arg1" ] || { echo "corpus not found: $arg1" >&2; exit 2; }
    [ -f "$arg2" ] || { echo "golden not found: $arg2" >&2; exit 2; }
    echo "diffing $arg2 against $arg1 ..."
    if diff_golden "$arg1" "$arg2"; then
      echo "golden match — no change"
      exit 0
    else
      echo "GOLDEN MISMATCH — prove which side is right before re-blessing."
      exit 1
    fi
    ;;
  all)
    run_all
    ;;
  *)
    echo "usage: harness.sh capture|diff|all <corpus.md> <out.tsv>" >&2; exit 2
    ;;
esac

# Cleanup transient pad dir
rm -rf "$PAD_TMP" 2>/dev/null || true
