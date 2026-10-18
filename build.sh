#!/bin/bash
# Builds Everything.app and everything-cli from source using the command line
# tools only (no Xcode project required).
#
#   ./build.sh                      # host architecture, macOS 13+ deployment target
#   UNIVERSAL=1 ./build.sh          # universal binary (arm64 + x86_64)
#   MACOSX_DEPLOYMENT_TARGET=14.0 ./build.sh
#   ARCHS="arm64" ./build.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="Everything"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
CLI="$BUILD_DIR/everything-cli"
TMPDIR_BUILD="$ROOT/.buildtmp"
MODULE_CACHE="$ROOT/.modulecache"

# Portability: without an explicit -target the binaries inherit the host OS as
# their minimum (e.g. minos 27.0), which makes them useless to anybody on an
# older macOS.
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
ARCHS="${ARCHS:-$(uname -m)}"
if [ "${UNIVERSAL:-0}" = "1" ]; then
  ARCHS="arm64 x86_64"
fi

mkdir -p "$TMPDIR_BUILD" "$MODULE_CACHE" "$BUILD_DIR"
export TMPDIR="$TMPDIR_BUILD"

SWIFT_FLAGS=(-O -swift-version 5 -module-cache-path "$MODULE_CACHE")
APP_FRAMEWORKS=(-framework AppKit -framework Quartz
                -framework UniformTypeIdentifiers -framework QuickLookThumbnailing)
CORE_SOURCES=("$ROOT"/Sources/Core/*.swift)
APP_SOURCES=("$ROOT"/Sources/App/*.swift)
CLI_SOURCES=("$ROOT"/Sources/CLI/*.swift)

# Compiles one executable for every requested architecture and lipos the slices.
compile() {
  local out="$1"
  shift
  local slices=()
  local arch
  for arch in $ARCHS; do
    local slice="$out.$arch"
    echo "    [$arch] $(basename "$out")"
    swiftc "${SWIFT_FLAGS[@]}" -target "$arch-apple-macos$DEPLOYMENT_TARGET" "$@" -o "$slice"
    slices+=("$slice")
  done
  if [ "${#slices[@]}" -gt 1 ]; then
    lipo -create "${slices[@]}" -output "$out"
    rm -f "${slices[@]}"
  else
    mv "${slices[0]}" "$out"
  fi
}

echo "==> building $APP_NAME.app  (macOS $DEPLOYMENT_TARGET+, arch: $ARCHS)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

compile "$APP/Contents/MacOS/$APP_NAME" \
  "${CORE_SOURCES[@]}" "${APP_SOURCES[@]}" "${APP_FRAMEWORKS[@]}"

echo "==> building everything-cli"
compile "$CLI" "${CORE_SOURCES[@]}" "${CLI_SOURCES[@]}"

echo "==> signing (ad-hoc)"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "   (codesign skipped)"

echo ""
echo "Architectures:  $(lipo -archs "$APP/Contents/MacOS/$APP_NAME") / $(lipo -archs "$CLI")"
MINOS="$(xcrun vtool -show-build "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null | awk '/minos/ {print $2}')"
echo "Minimum macOS:  ${MINOS:-unknown}"
echo ""
echo "Built:"
echo "  $APP"
echo "  $CLI"
echo ""
echo "Run with:  open \"$APP\"       (or: \"$APP/Contents/MacOS/$APP_NAME\")"
echo "CLI:       $CLI --help"
