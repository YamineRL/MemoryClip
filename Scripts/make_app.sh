#!/usr/bin/env bash
set -euo pipefail

# Build MemoryClip.app bundle from the SwiftPM release build.
cd "$(dirname "$0")/.."

echo "==> Building MemoryClip (release)"
swift build -c release

BIN=".build/release/MemoryClip"
if [ ! -f "$BIN" ]; then
    BIN=".build/arm64-apple-macosx/release/MemoryClip"
fi

if [ ! -f "$BIN" ]; then
    echo "error: release binary not found under .build/" >&2
    exit 1
fi

ICON="Resources/AppIcon.icns"
if [ ! -f "$ICON" ]; then
    echo "==> AppIcon.icns missing, generating it"
    swift Scripts/make_icon.swift
fi
if [ ! -f "$ICON" ]; then
    echo "error: $ICON not found; run 'swift Scripts/make_icon.swift'" >&2
    exit 1
fi

APP="dist/MemoryClip.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/MemoryClip"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

# The string catalogue: Bundle.module resolves against Contents/Resources.
BUNDLE="$(dirname "$BIN")/MemoryClip_MemoryClip.bundle"
if [ ! -d "$BUNDLE" ]; then
    echo "error: $BUNDLE not found; the localization catalogue would be missing" >&2
    exit 1
fi
cp -R "$BUNDLE" "$APP/Contents/Resources/"

# InfoPlist.strings, for the permission prompts macOS reads out of Info.plist.
for lproj in Resources/*.lproj; do
    [ -d "$lproj" ] || continue
    cp -R "$lproj" "$APP/Contents/Resources/"
done

# Ad-hoc signature: no Developer ID, no notarisation (local/personal use).
codesign --force --sign - "$APP"

echo "OK: built $APP"
