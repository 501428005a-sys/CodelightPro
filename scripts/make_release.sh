#!/bin/bash
# Build a universal (arm64 + x86_64) CodelightPro.app and zip it for a
# GitHub Release: dist/CodelightPro-<version>.zip + latest.json.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
OUT="$ROOT/dist"

UNIVERSAL=1 bash scripts/make_app.sh release

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/CodelightPro.app/Contents/Info.plist")"
ZIP="CodelightPro-$VERSION.zip"

echo "▶ packaging $ZIP"
mkdir -p "$OUT"
rm -f "$OUT"/CodelightPro-*.zip
# ditto keeps the code signature and extended attributes intact.
ditto -c -k --sequesterRsrc --keepParent "$ROOT/CodelightPro.app" "$OUT/$ZIP"

SIZE="$(stat -f%z "$OUT/$ZIP")"
cat > "$OUT/latest.json" <<JSON
{ "version": "$VERSION", "file": "$ZIP", "sizeBytes": $SIZE, "builtAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)" }
JSON

echo "✅ $OUT/$ZIP ($(lipo -archs "$ROOT/CodelightPro.app/Contents/MacOS/CodelightPro"), $((SIZE / 1024)) KB)"
