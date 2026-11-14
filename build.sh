#!/bin/bash
# Builds TabFlow.app.   ./build.sh            -> build/TabFlow.app
#                        ./build.sh --install  -> also copies to /Applications and launches it
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
APP="build/TabFlow.app"
SWIFT_FLAGS=(-O -swift-version 5)
NATIVE_TARGET=(-target "$(uname -m)-apple-macosx13.0")

# Work around a Command Line Tools packaging bug (duplicate SwiftBridging module map).
if [ -f /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap ] && \
   [ -f /Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap ]; then
  : > scripts/empty.modulemap
  cat > build-overlay.yaml <<EOF
{ "version": 0, "case-sensitive": "false", "roots": [
  { "type": "directory", "name": "/Library/Developer/CommandLineTools/usr/include/swift",
    "contents": [ { "type": "file", "name": "module.modulemap", "external-contents": "$ROOT/scripts/empty.modulemap" } ] } ] }
EOF
  mkdir -p build && mv build-overlay.yaml build/overlay.yaml
  SWIFT_FLAGS+=(-vfsoverlay "$ROOT/build/overlay.yaml")
fi

mkdir -p build
echo "▸ Compiling…"
FRAMEWORKS=(-framework Cocoa -framework Carbon -framework ServiceManagement)
if [ "${UNIVERSAL:-0}" = "1" ]; then
  # Release builds: one binary that runs on both Apple Silicon and Intel Macs.
  for arch in arm64 x86_64; do
    swiftc "${SWIFT_FLAGS[@]}" -target "$arch-apple-macosx13.0" -o "build/TabFlow-$arch" \
      Sources/TabFlow/*.swift "${FRAMEWORKS[@]}"
  done
  lipo -create -output build/TabFlow build/TabFlow-arm64 build/TabFlow-x86_64
  rm -f build/TabFlow-arm64 build/TabFlow-x86_64
else
  swiftc "${SWIFT_FLAGS[@]}" "${NATIVE_TARGET[@]}" -o build/TabFlow Sources/TabFlow/*.swift "${FRAMEWORKS[@]}"
fi

if [ ! -f Resources/AppIcon.icns ]; then
  echo "▸ Drawing icon…"
  swiftc "${SWIFT_FLAGS[@]}" "${NATIVE_TARGET[@]}" -o build/make-icon scripts/make-icon.swift -framework Cocoa
  build/make-icon build/icon-1024.png
  ICONSET=build/AppIcon.iconset; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi

echo "▸ Bundling…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/TabFlow "$APP/Contents/MacOS/TabFlow"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Signing: uses the "TabFlow Local Signing" certificate from the login keychain when
# present, so macOS keeps Accessibility/Screen Recording permission across rebuilds.
# Falls back to ad-hoc ("-"). Override with TABFLOW_SIGN_IDENTITY.
DEFAULT_ID="-"
if security find-identity -p codesigning 2>/dev/null | grep -q '"TabFlow Local Signing"'; then
  DEFAULT_ID="TabFlow Local Signing"
fi
IDENTITY="${TABFLOW_SIGN_IDENTITY:-$DEFAULT_ID}"
echo "▸ Signing with: $IDENTITY"
codesign --force --sign "$IDENTITY" --identifier local.tabflow.app "$APP" 2>&1 | grep -v "replacing existing signature" || true
echo "✓ Built $APP"

if [ "${1:-}" = "--install" ]; then
  pkill -x TabFlow 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/TabFlow.app
  # Move (not copy) so only one TabFlow.app exists and macOS always launches /Applications.
  mv "$APP" /Applications/TabFlow.app
  echo "✓ Installed to /Applications/TabFlow.app"
  open /Applications/TabFlow.app
fi
