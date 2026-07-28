#!/bin/bash
# Builds Marker.app from the Swift package.
#
#   ./build.sh            release build into ./build/Marker.app
#   ./build.sh debug      debug build
#   ./build.sh release install   also copy to /Applications

set -euo pipefail

CONFIG="${1:-release}"
INSTALL="${2:-}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Marker.app"

echo "==> Compiling ($CONFIG)"
swift build -c "$CONFIG" --package-path "$ROOT"
BINARY="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/Marker"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Marker"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# KaTeX + Mermaid, used by the offscreen renderer.
if [ -d "$ROOT/Resources/Web" ]; then
  cp -R "$ROOT/Resources/Web" "$APP/Contents/Resources/Web"
fi

# BPE vocabulary for the token counter.
if [ -d "$ROOT/Resources/Tokenizer" ]; then
  cp -R "$ROOT/Resources/Tokenizer" "$APP/Contents/Resources/Tokenizer"
fi

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"

if [ "$INSTALL" = "install" ]; then
  echo "==> Installing to /Applications"
  rm -rf "/Applications/Marker.app"
  cp -R "$APP" "/Applications/Marker.app"
  echo "Installed: /Applications/Marker.app"
else
  echo "Built: $APP"
fi
