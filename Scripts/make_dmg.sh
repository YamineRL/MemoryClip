#!/usr/bin/env bash
set -euo pipefail

# Build MemoryClip.app and wrap it in a drag-to-install disk image:
#   dist/MemoryClip-<version>.dmg  =  MemoryClip.app + /Applications symlink
#
# The window is dressed: Resources/dmg-background.png (and its @2x twin, drawn
# by Scripts/make_dmg_background.swift) go into a hidden .background folder and
# Finder is scripted to lay the icons out on top of the art. That art tells the
# user to quit MemoryClip before dragging, because macOS refuses to replace a
# running application and the update check opens this image while the app is
# still up. Dressing the window is the only thing here that needs Finder, so a
# machine that has not granted control of Finder warns and gets a plain window
# rather than a failed release.
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
RW_MOUNT=""
RW_DMG=""
OSA=""
OSA_LOG=""

# How long Finder gets to lay the window out before we give up on it. The
# scripting can sit on a "wants to control Finder" prompt forever otherwise,
# and a release must never hang on window dressing.
OSASCRIPT_TIMEOUT="${OSASCRIPT_TIMEOUT:-90}"

# The window, in the coordinate space Finder uses: origin at the top-left of
# the content area, y counting down. These must match the layout constants in
# Scripts/make_dmg_background.swift, which draws the art they sit on.
WINDOW_W=640
WINDOW_H=440
ICON_SIZE=112
APP_POS="170, 250"
APPLICATIONS_POS="470, 250"
# Bottom centre, below the arrow's caption. Not the bottom *corner*: an item
# whose grid cell would start left of x=0 makes Finder shift the whole icon
# layer right to bring it into view, and the icons then sit off the artwork.
LICENSE_POS="320, 350"
# Only ever seen by someone browsing with hidden files shown, but when it is
# seen it lands on the heading unless it is told otherwise.
BACKGROUND_POS="545, 350"

# The bounds Finder takes for a window include its title bar, so the content
# area comes out shorter than what is asked for by however tall Finder draws
# one (32pt on macOS 26, 28pt for years before that). Allowing the smaller
# figure is the safe direction: the art then always covers the whole content
# area, and what gets cropped is the empty band the background leaves at its
# bottom for exactly this reason. Allowing too much would leave a bare strip
# under the picture instead.
TITLE_BAR=28

cleanup() {
    local status=$?
    if [ -n "$MOUNT" ] && [ -d "$MOUNT" ]; then
        hdiutil detach "$MOUNT" -quiet -force >/dev/null 2>&1 || true
    fi
    if [ -n "$RW_MOUNT" ] && [ -d "$RW_MOUNT" ]; then
        hdiutil detach "$RW_MOUNT" -quiet -force >/dev/null 2>&1 || true
    fi
    if [ -n "$RW_DMG" ] && [ -f "$RW_DMG" ]; then
        rm -f "$RW_DMG"
    fi
    if [ -n "$OSA" ]; then
        rm -f "$OSA" "$OSA_LOG"
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
cp "$ROOT/LICENSE" "$STAGE/LICENSE" || die "could not stage LICENSE"

# The window background, committed as a build input the way AppIcon.icns is.
# A multi-resolution TIFF keeps it crisp on a Retina display; where tiffutil
# cannot make one, the 1x PNG is still a correct background.
BG_1X="$ROOT/Resources/dmg-background.png"
BG_2X="$ROOT/Resources/dmg-background@2x.png"
BG_NAME=""
mkdir -p "$STAGE/.background"
if [ -f "$BG_1X" ]; then
    if [ -f "$BG_2X" ] && command -v tiffutil >/dev/null 2>&1 \
        && tiffutil -cathidpicheck "$BG_1X" "$BG_2X" \
            -out "$STAGE/.background/background.tiff" >/dev/null 2>&1; then
        BG_NAME="background.tiff"
    else
        rm -f "$STAGE/.background/background.tiff"
        cp "$BG_1X" "$STAGE/.background/background.png" || die "could not stage the background"
        BG_NAME="background.png"
    fi
    echo "==> Window background: $BG_NAME"
else
    rmdir "$STAGE/.background"
    echo "warning: $BG_1X is missing — the disk image will have a plain window." >&2
    echo "warning: run 'swift Scripts/make_dmg_background.swift' and commit what it writes." >&2
fi

# --- 5. Build a read-write image to dress. -----------------------------------
rm -f "$DMG"
RW_DMG="$ROOT/dist/.MemoryClip-$VERSION.rw.dmg"
rm -f "$RW_DMG"

# Slack for the .DS_Store Finder writes and for HFS+ overhead; the image is
# compressed down to its real size by the convert in step 8 either way.
STAGE_MB="$(du -sm "$STAGE" | cut -f1)"
IMAGE_MB=$((STAGE_MB + 60))

echo "==> Creating read-write disk image (${IMAGE_MB}m)"
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDRW \
    -size "${IMAGE_MB}m" \
    -ov \
    -quiet \
    "$RW_DMG" || die "hdiutil create failed"

# Mounted *without* -nobrowse: Finder will not lay out a window for a volume
# it has been told to ignore. A leftover mount of the same volume name would
# make this one land at "<name> 1", so clear it first.
if [ -d "/Volumes/$VOLNAME" ]; then
    hdiutil detach "/Volumes/$VOLNAME" -quiet -force >/dev/null 2>&1 || true
fi
ATTACHED="$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen)" \
    || die "could not mount the read-write image"
RW_MOUNT="$(printf '%s\n' "$ATTACHED" | awk -F '\t' '$3 != "" { print $3 }' | tail -1)"
[ -d "$RW_MOUNT" ] || die "could not work out where the read-write image mounted"
RW_VOLNAME="$(basename "$RW_MOUNT")"

# --- 6. Ask Finder to lay the window out. ------------------------------------
# Best-effort by design. Finder scripting needs an Automation grant that a
# fresh machine has not given, and the prompt for it can sit unanswered; a
# failure here costs the artwork, not the release.
OSA="$STAGE/../$(basename "$STAGE").applescript"
OSA_LOG="$OSA.log"

if [ -n "$BG_NAME" ]; then
    BG_CLAUSE="set background picture of opts to file \".background:$BG_NAME\""
else
    BG_CLAUSE=""
fi

cat >"$OSA" <<APPLESCRIPT
tell application "Finder"
    tell disk "$RW_VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, $((200 + WINDOW_W)), $((120 + WINDOW_H + TITLE_BAR))}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to $ICON_SIZE
        set text size of opts to 12
        $BG_CLAUSE
        set position of item "MemoryClip.app" of container window to {$APP_POS}
        set position of item "Applications" of container window to {$APPLICATIONS_POS}
        set position of item "LICENSE" of container window to {$LICENSE_POS}
        try
            set position of item ".background" of container window to {$BACKGROUND_POS}
        end try
        close
        open
        delay 1
        -- Placed a second time on purpose. On the first pass Finder drops every
        -- icon roughly a title bar lower than it was asked to, because the view
        -- has not taken its final geometry yet; repeating the placement once the
        -- window has reopened lands them on the artwork exactly.
        set position of item "MemoryClip.app" of container window to {$APP_POS}
        set position of item "Applications" of container window to {$APPLICATIONS_POS}
        set position of item "LICENSE" of container window to {$LICENSE_POS}
        try
            set position of item ".background" of container window to {$BACKGROUND_POS}
        end try
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

# osascript run under a watchdog: a TCC prompt would otherwise block forever.
run_osascript() {
    local pid watchdog status=0
    osascript "$OSA" >"$OSA_LOG" 2>&1 &
    pid=$!
    (sleep "$OSASCRIPT_TIMEOUT"; kill -TERM "$pid") >/dev/null 2>&1 &
    watchdog=$!
    wait "$pid" || status=$?
    kill -TERM "$watchdog" >/dev/null 2>&1 || true
    wait "$watchdog" >/dev/null 2>&1 || true
    return "$status"
}

echo "==> Laying out the disk image window"
if run_osascript; then
    echo "==> Finder window settings applied"
else
    echo "warning: Finder would not lay the disk image window out (exit $?)." >&2
    echo "warning: the DMG is still valid and still installs — it just opens as a" >&2
    echo "warning: plain Finder window. Grant this terminal control of Finder in" >&2
    echo "warning: System Settings > Privacy & Security > Automation to fix it." >&2
    if [ -s "$OSA_LOG" ]; then
        while IFS= read -r line; do
            echo "warning:     $line" >&2
        done <"$OSA_LOG"
    fi
fi
rm -f "$OSA" "$OSA_LOG"

# --- 7. Flush Finder's .DS_Store to the image and unmount. -------------------
# The volume bookkeeping macOS makes on mounting is not worth shipping, and it
# shows up in the window for anyone browsing with hidden files on.
rm -rf "$RW_MOUNT/.fseventsd" "$RW_MOUNT/.Trashes" >/dev/null 2>&1 || true
sync
hdiutil detach "$RW_MOUNT" -quiet \
    || hdiutil detach "$RW_MOUNT" -quiet -force \
    || die "could not unmount $RW_MOUNT"
RW_MOUNT=""

# --- 8. Compress to the image we ship. ---------------------------------------
echo "==> Compressing disk image"
hdiutil convert "$RW_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG" \
    -ov \
    -quiet || die "hdiutil convert failed"

rm -f "$RW_DMG"
RW_DMG=""

[ -f "$DMG" ] || die "hdiutil reported success but $DMG does not exist"

# --- 9. Smoke-test: mount, check contents, unmount. --------------------------
echo "==> Verifying disk image"
MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/memoryclip-mnt.XXXXXX")"
hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -readonly -quiet \
    || die "could not mount $DMG"

[ -d "$MOUNT/MemoryClip.app" ] || die "mounted image has no MemoryClip.app"
[ -L "$MOUNT/Applications" ] || die "mounted image has no /Applications symlink"
[ -f "$MOUNT/LICENSE" ] || die "mounted image has no LICENSE"
[ -x "$MOUNT/MemoryClip.app/Contents/MacOS/MemoryClip" ] || die "mounted MemoryClip.app has no executable"
[ -f "$MOUNT/MemoryClip.app/Contents/Resources/AppIcon.icns" ] || die "mounted MemoryClip.app has no icon"
if [ -n "$BG_NAME" ]; then
    [ -f "$MOUNT/.background/$BG_NAME" ] || die "mounted image has no .background/$BG_NAME"
fi
codesign --verify --strict "$MOUNT/MemoryClip.app" || die "signature broken inside the DMG"

hdiutil detach "$MOUNT" -quiet || die "could not unmount $MOUNT"
rmdir "$MOUNT" 2>/dev/null || true
MOUNT=""

echo "OK: $DMG ($(du -h "$DMG" | cut -f1))"
