#!/usr/bin/env bash
# Regression test for `stitchpad say --image <path> [text...]`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SP="$ROOT/tool/bin/stitchpad"
FIXTURE_DIR="$(mktemp -d)"
FAKE_BIN="$FIXTURE_DIR/bin"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/curl" <<'CURL'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$STITCHPAD_FAKE_CURL_LOG"
case "$*" in
  *"/upload-image?pad=$STITCHPAD_EXPECT_PAD"*)
    ;;
  *)
    printf '{"error":"missing upload url"}\n' >&2
    exit 22
    ;;
esac
case "$*" in
  *"-F image=@"*)
    printf '{"url":"https://relay.test/img/abc.png","sha":"abc","mime":"image/png","size":68}\n'
    ;;
  *)
    printf '{"error":"missing multipart image field"}\n' >&2
    exit 22
    ;;
esac
CURL
chmod +x "$FAKE_BIN/curl"

cd "$FIXTURE_DIR"
"$SP" init --name fixture >/dev/null

# A valid 1x1 PNG.
IMG="$FIXTURE_DIR/tiny.png"
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p94AAAAASUVORK5CYII=' | base64 -d > "$IMG" 2>/dev/null \
  || printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p94AAAAASUVORK5CYII=' | base64 -D > "$IMG"

export PATH="$FAKE_BIN:$PATH"
export STITCHPAD_RELAY="https://relay.test"
export STITCHPAD_TOKEN="test-token"
export STITCHPAD_FAKE_CURL_LOG="$FIXTURE_DIR/curl.log"
export STITCHPAD_EXPECT_PAD
STITCHPAD_EXPECT_PAD="$(basename "$FIXTURE_DIR")"

STITCHPAD_NAME=alice "$SP" say --image "$IMG" "look at this" >/dev/null

grep -q "/upload-image?pad=$STITCHPAD_EXPECT_PAD" "$STITCHPAD_FAKE_CURL_LOG"
grep -qF '![tiny.png](https://relay.test/img/abc.png)' "$FIXTURE_DIR/.stitchpad/stitchpad.md"
grep -qF 'look at this' "$FIXTURE_DIR/.stitchpad/stitchpad.md"

echo "say image ok"
