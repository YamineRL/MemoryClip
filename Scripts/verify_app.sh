#!/usr/bin/env bash
set -euo pipefail

# Verify that a built MemoryClip.app is self-contained.
#
# The invariant this checks: a SwiftPM module with resources gets a
# generated `Bundle.module` accessor that expects
# <Package>_<Target>.bundle in the app's resources — and fatalErrors the
# first time that module localizes a string. KeyboardShortcuts did
# exactly that: the Shortcuts settings pane crashed on every shipped
# release because its bundle was never copied into the app, and neither
# `swift build` nor `swift test` could see it — the test bundle already
# carries every module's resources. This script compares what the build
# produced against what the app ships, so the gap fails the build
# instead of the user.
#
# Usage:
#   ./Scripts/verify_app.sh [path/to/MemoryClip.app] [products-dir]
# make_app.sh calls it with both; standalone it locates the release
# products dir itself.

cd "$(dirname "$0")/.."

APP="${1:-dist/MemoryClip.app}"
PRODUCTS="${2:-}"
RES="$APP/Contents/Resources"

fail() { echo "error: $*" >&2; exit 1; }

[ -d "$APP" ] || fail "$APP does not exist — run Scripts/make_app.sh first"
[ -f "$APP/Contents/Info.plist" ] || fail "Info.plist missing from $APP"
[ -f "$APP/Contents/MacOS/MemoryClip" ] || fail "executable missing from $APP"

if [ -z "$PRODUCTS" ]; then
    for dir in \
        .build/out/Products/Release \
        .build/release \
        .build/arm64-apple-macosx/release; do
        [ -d "$dir" ] && { PRODUCTS="$dir"; break; }
    done
fi
[ -d "$PRODUCTS" ] || fail "no release products dir found under .build/"

missing=0

# Every module bundle the build emitted must be inside the app — an
# absent one is a Bundle.module fatalError waiting for its first
# localized string.
for bundle in "$PRODUCTS"/*_*.bundle; do
    [ -d "$bundle" ] || continue
    name="$(basename "$bundle")"
    if [ ! -d "$RES/$name" ]; then
        echo "error: $name was built but is missing from $RES" >&2
        missing=1
    fi
done

# InfoPlist.strings: macOS reads the permission prompts from the app's
# root lproj directories, not from a module bundle.
for lproj in Resources/*.lproj; do
    [ -d "$lproj" ] || continue
    name="$(basename "$lproj")"
    if [ ! -d "$RES/$name" ]; then
        echo "error: $name missing from $RES — permission prompts lose their wording" >&2
        missing=1
    fi
done

[ "$missing" -eq 0 ] || exit 1

[ -f "$RES/AppIcon.icns" ] || fail "AppIcon.icns missing from $RES"
[ -f "$RES/Metadata.appintents/extract.actionsdata" ] || \
    fail "Metadata.appintents missing from $RES — Shortcuts cannot see the intents"

echo "OK: $APP is self-contained"
