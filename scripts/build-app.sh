#!/bin/bash
# Builds MoxieTimer.app into ./build.
#   --install    copy to /Applications and launch
#   --universal  build for Apple Silicon + Intel
# VERSION / BUILD_NUMBER env vars override the bundle version.
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=0
ARCH_FLAGS=()
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --universal) ARCH_FLAGS=(--arch arm64 --arch x86_64) ;;
  esac
done

swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="build/MoxieTimer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MoxieTimer" "$APP/Contents/MacOS/MoxieTimer"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [[ -n "${VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$APP/Contents/Info.plist"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "$APP/Contents/Info.plist"
fi

codesign --force --sign - "$APP" >/dev/null

echo "Built $APP"

if [[ "$INSTALL" == 1 ]]; then
  pkill -x MoxieTimer 2>/dev/null || true
  rm -rf /Applications/MoxieTimer.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/MoxieTimer.app"
  open /Applications/MoxieTimer.app
fi
