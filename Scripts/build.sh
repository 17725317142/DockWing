#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE="$BUILD_DIR/DockWing.app"
INSTALL_PATH="/Applications/DockWing.app"
ARCH="$(uname -m)"

rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

echo "[1/4] Generating AppIcon.icns..."
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
swift "$PROJECT_DIR/Scripts/generate_icon.swift" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

echo "[2/4] Compiling ultra-light pure AppKit binary ($ARCH)..."
swiftc \
  -Osize \
  -swift-version 5 \
  -target "${ARCH}-apple-macosx14.0" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework CoreGraphics \
  "$PROJECT_DIR/Sources/Models.swift" \
  "$PROJECT_DIR/Sources/AXHelper.swift" \
  "$PROJECT_DIR/Sources/DockManager.swift" \
  "$PROJECT_DIR/Sources/DockClickMinimizer.swift" \
  "$PROJECT_DIR/Sources/DockHoverWindowPicker.swift" \
  "$PROJECT_DIR/Sources/NotchMissionControlTrigger.swift" \
  "$PROJECT_DIR/Sources/SmoothScrollEngine.swift" \
  "$PROJECT_DIR/Sources/MiddleButtonDragScroller.swift" \
  "$PROJECT_DIR/Sources/StageManagerContextMenu.swift" \
  "$PROJECT_DIR/Sources/LastWindowAutoQuitter.swift" \
  "$PROJECT_DIR/Sources/EventTapManager.swift" \
  "$PROJECT_DIR/Sources/AppDelegate.swift" \
  "$PROJECT_DIR/Sources/main.swift" \
  -o "$APP_BUNDLE/Contents/MacOS/DockWing"

strip -x "$APP_BUNDLE/Contents/MacOS/DockWing"

echo "[3/4] Packaging and signing DockWing.app..."
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
codesign --force --deep --sign - --identifier com.dockwing.app "$APP_BUNDLE"

if [[ "${SKIP_INSTALL:-0}" != "1" ]]; then
  echo "[4/4] Installing to $INSTALL_PATH..."
  pkill -x DockWing 2>/dev/null || true
  rm -rf "$INSTALL_PATH"
  cp -R "$APP_BUNDLE" "$INSTALL_PATH"
  echo "Build and install complete: $INSTALL_PATH"
  ls -lh "$INSTALL_PATH/Contents/MacOS/DockWing"
else
  echo "[4/4] Skipping /Applications install (SKIP_INSTALL=1). Built at: $APP_BUNDLE"
  ls -lh "$APP_BUNDLE/Contents/MacOS/DockWing"
fi
