#!/bin/bash
# Build Solo and assemble a double-clickable Solo.app bundle.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Building release…"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/Solo"
APP="Solo.app"
CONTENTS="$APP/Contents"

echo "==> Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/Solo"
cp Info.plist "$CONTENTS/Info.plist"
if [ -f AppIcon.icns ]; then
    cp AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
else
    echo "   (warning: AppIcon.icns missing — run: swift tools/make_icon.swift && ./tools/make_icns.sh)"
fi

# Ad-hoc sign so macOS lets it run locally.
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   (codesign skipped)"

echo "==> Done: $(pwd)/$APP"
echo "    Launch with:  open $APP"
echo "    Or open a specific folder:  open $APP --args /path/to/folder"
