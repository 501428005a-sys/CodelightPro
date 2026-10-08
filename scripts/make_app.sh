#!/bin/bash
# Build CodelightPro and assemble a runnable .app bundle.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/CodelightPro.app"
CONFIG="${1:-release}"

# UNIVERSAL=1 builds arm64 + x86_64 (used by make_release.sh for downloads).
ARCH_FLAGS=()
[ "${UNIVERSAL:-0}" = 1 ] && ARCH_FLAGS=(--arch arm64 --arch x86_64)

echo "▶ swift build -c $CONFIG ${ARCH_FLAGS[*]:-}"
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}

BIN="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/CodelightPro"

echo "▶ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CodelightPro"

echo "▶ generating app icon"
ICONSET="$ROOT/.build/CodelightPro.iconset"
ICON_RENDERER="$ROOT/.build/render_app_icon"
rm -rf "$ICONSET"
swiftc \
    "$ROOT/Sources/CodelightPro/UI/CatIconRenderer.swift" \
    "$ROOT/scripts/render_app_icon.swift" \
    -o "$ICON_RENDERER"
"$ICON_RENDERER" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>             <string>CodelightPro</string>
    <key>CFBundleDisplayName</key>      <string>CodelightPro</string>
    <key>CFBundleIdentifier</key>       <string>com.codelightpro.app</string>
    <key>CFBundleExecutable</key>       <string>CodelightPro</string>
    <key>CFBundleIconFile</key>         <string>AppIcon</string>
    <key>CFBundleVersion</key>          <string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>LSMinimumSystemVersion</key>   <string>13.0</string>
    <key>LSUIElement</key>              <true/>
    <key>NSHumanReadableCopyright</key> <string>CodelightPro</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so notifications & TCC behave for a locally-built app.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "✅ Built $APP"
echo "   运行：open \"$APP\"   （右上角会出现一个悬浮小球）"
