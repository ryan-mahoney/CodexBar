#!/bin/bash
# Build a self-contained payload for the Homebrew formula (Python is supplied by Homebrew).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  echo 'This release package requires an Apple Silicon Mac.' >&2
  exit 1
}
VERSION=$(python3 -c 'from ai_capacity import __version__; print(__version__)')
swift build -c release --product CodexBarCLI
BIN_DIR=$(swift build -c release --show-bin-path)
STAGE_DIR=$(mktemp -d "$ROOT_DIR/.build/ai-capacity-package.XXXXXX")
PAYLOAD="$STAGE_DIR/ai-capacity"
mkdir -p "$PAYLOAD/report-cli" "$PAYLOAD/ai_capacity/static" "$PAYLOAD/licenses"
cp "$BIN_DIR/CodexBarCLI" "$PAYLOAD/report-cli/codexbar"
cp -R "$BIN_DIR/CodexBar_CodexBarCore.bundle" "$PAYLOAD/report-cli/"
cp ai_capacity/__init__.py ai_capacity/__main__.py ai_capacity/server.py "$PAYLOAD/ai_capacity/"
cp ai_capacity/static/index.html ai_capacity/static/app.js ai_capacity/static/app.css \
  ai_capacity/static/THIRD_PARTY_NOTICES.txt "$PAYLOAD/ai_capacity/static/"
cp Scripts/ai_capacity_launch.py "$PAYLOAD/launch.py"
cp LICENSE README.md "$PAYLOAD/"
cp Sources/CQuickJS/LICENSE "$PAYLOAD/licenses/QuickJS.txt"
# Include dependency license notices without including checkout metadata or local files.
for dependency in "$ROOT_DIR"/.build/checkouts/*; do
  [[ -d "$dependency" ]] || continue
  for notice in "$dependency"/LICENSE* "$dependency"/NOTICE*; do
    [[ -f "$notice" ]] || continue
    cp "$notice" "$PAYLOAD/licenses/$(basename "$dependency")-$(basename "$notice")"
  done
done
strip -S "$PAYLOAD/report-cli/codexbar"
codesign --force --sign - "$PAYLOAD/report-cli/codexbar"
CODEXBAR_RESOURCE_SMOKE=1 "$PAYLOAD/report-cli/codexbar"
python3 -B "$PAYLOAD/launch.py" --version
"$PAYLOAD/report-cli/codexbar" report --help >/dev/null
ARCHIVE="$ROOT_DIR/.build/ai-capacity-${VERSION}-macos-arm64.tar.gz"
COPYFILE_DISABLE=1 tar --exclude='__pycache__' --exclude='*.pyc' -czf "$ARCHIVE" -C "$STAGE_DIR" ai-capacity
shasum -a 256 "$ARCHIVE"
