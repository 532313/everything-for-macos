#!/bin/bash
# Builds Everything.app and everything-cli from source using the command line
# tools only (no Xcode project required).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="Everything"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
CLI="$BUILD_DIR/everything-cli"
TMPDIR_BUILD="$ROOT/.buildtmp"
MODULE_CACHE="$ROOT/.modulecache"

mkdir -p "$TMPDIR_BUILD" "$MODULE_CACHE" "$BUILD_DIR"
export TMPDIR="$TMPDIR_BUILD"

SWIFT_FLAGS=(-O -swift-version 5 -module-cache-path "$MODULE_CACHE")
CORE_SOURCES=("$ROOT"/Sources/Core/*.swift)
APP_SOURCES=("$ROOT"/Sources/App/*.swift)
CLI_SOURCES=("$ROOT"/Sources/CLI/*.swift)

echo "==> building $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

swiftc "${SWIFT_FLAGS[@]}" \
  "${CORE_SOURCES[@]}" "${APP_SOURCES[@]}" \
  -framework AppKit -framework Quartz -framework UniformTypeIdentifiers -framework QuickLookThumbnailing \
  -o "$APP/Contents/MacOS/$APP_NAME"

echo "==> building everything-cli"
swiftc "${SWIFT_FLAGS[@]}" \
  "${CORE_SOURCES[@]}" "${CLI_SOURCES[@]}" \
  -o "$CLI"

echo "==> signing (ad-hoc)"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "   (codesign skipped)"

echo ""
echo "Built:"
echo "  $APP"
echo "  $CLI"
echo ""
echo "Run with:  open \"$APP\"       (or: \"$APP/Contents/MacOS/$APP_NAME\")"
echo "CLI:       $CLI --help"
