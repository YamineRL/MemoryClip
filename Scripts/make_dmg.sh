#!/usr/bin/env bash
set -euo pipefail

# Build MemoryClip.app and wrap it in a drag-to-install disk image:
#   dist/MemoryClip-<version>.dmg  =  MemoryClip.app + /Applications symlink
#
# Ad-hoc signed only — there is no Developer ID and no notarisation, so on a
# machine other than this one the DMG's app needs a right-click → Open (or
# `xattr -dr com.apple.quarantine`) the first time.
#
# Usage: ./Scripts/make_dmg.sh

cd "$(dirname "$0")/.."
ROOT="$PWD"

STAGE=""
MOUNT=""

cleanup() {
    local status=$?
    if [ -n "$MOUNT" ] && [ -d "$MOUNT" ]; then
        hdiutil detach "$MOUNT" -quiet -force >/dev/null 2>&1 || true
    fi
    if [ -n "$STAGE" ] && [ -d "$STAGE" ]; then
        rm -rf "$STAGE"
    fi
    if [ "$status" -ne 0 ]; then
        echo "error: make_dmg.sh failed (exit $status)" >&2
    fi
}
trap cleanup EXIT

die() {
    echo "error: $*" >&2
    exit 1
}

# --- 1. Build the app bundle. ------------------------------------------------
echo "==> Building app bundle"
"$ROOT/Scripts/make_app.sh"

APP="$ROOT/dist/MemoryClip.app"
[ -d "$APP" ] || die "dist/MemoryClip.app was not produced by Scripts/make_app.sh"

# --- 2. Version comes from the bundle, never hardcoded. ----------------------
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP/Contents/Info.plist" 2>/dev/null || true)"
[ -n "$VERSION" ] || die "could not read CFBundleShortVersionString from $APP/Contents/Info.plist"

DMG="$ROOT/dist/MemoryClip-$VERSION.dmg"
VOLNAME="MemoryClip $VERSION"
echo "==> Version $VERSION -> $(basename "$DMG")"

# --- 3. Verify the signature we are about to ship. ---------------------------
codesign --verify --deep --strict "$APP" \
    || die "ad-hoc signature on $APP did not verify"

# --- 4. Stage the DMG contents. ----------------------------------------------
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/memoryclip-dmg.XXXXXX")"
cp -R "$APP" "$STAGE/MemoryClip.app" || die "could not stage MemoryClip.app"
ln -s /Applications "$STAGE/Applications" || die "could not create /Applications symlink"

# --- 5. Build the image (idempotent: any previous DMG is replaced). ----------
rm -f "$DMG"
echo "==> Creating disk image"
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    -quiet \
    "$DMG" || die "hdiutil create failed"

[ -f "$DMG" ] || die "hdiutil reported success but $DMG does not exist"

# --- 6. Smoke-test: mount, check contents, unmount. --------------------------
echo "==> Verifying disk image"
MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/memoryclip-mnt.XXXXXX")"
hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -readonly -quiet \
    || die "could not mount $DMG"

[ -d "$MOUNT/MemoryClip.app" ] || die "mounted image has no MemoryClip.app"
[ -L "$MOUNT/Applications" ] || die "mounted image has no /Applications symlink"
[ -x "$MOUNT/MemoryClip.app/Contents/MacOS/MemoryClip" ] || die "mounted MemoryClip.app has no executable"
[ -f "$MOUNT/MemoryClip.app/Contents/Resources/AppIcon.icns" ] || die "mounted MemoryClip.app has no icon"
codesign --verify --strict "$MOUNT/MemoryClip.app" || die "signature broken inside the DMG"

hdiutil detach "$MOUNT" -quiet || die "could not unmount $MOUNT"
rmdir "$MOUNT" 2>/dev/null || true
MOUNT=""

echo "OK: $DMG ($(du -h "$DMG" | cut -f1))"
