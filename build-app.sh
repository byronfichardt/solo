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

# Sign with a stable self-signed identity if available, so macOS TCC / Full Disk
# Access grants persist across rebuilds. Falls back to ad-hoc otherwise.
# Override the identity name with: SOLO_SIGN_ID="Your Cert Name" ./build-app.sh
# Note: no -v — a self-signed cert is "untrusted" (CSSMERR_TP_NOT_TRUSTED) but
# codesign can still sign with it, which is all we need for stable TCC identity.
SIGN_ID="${SOLO_SIGN_ID:-Solo Dev}"
if security find-identity -p codesigning 2>/dev/null | grep -qF "$SIGN_ID"; then
    echo "==> Signing with identity: $SIGN_ID (TCC grants will persist)"
    codesign --force --deep --sign "$SIGN_ID" "$APP"
else
    echo "==> Identity \"$SIGN_ID\" not found — ad-hoc signing (TCC grants won't persist across rebuilds)"
    codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   (codesign skipped)"
fi

echo "==> Done: $(pwd)/$APP"
echo "    Launch with:  open $APP"
echo "    Or open a specific folder:  open $APP --args /path/to/folder"
