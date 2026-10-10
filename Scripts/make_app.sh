#!/usr/bin/env bash
set -euo pipefail

# Build MemoryClip.app bundle from the SwiftPM release build.
cd "$(dirname "$0")/.."

echo "==> Building MemoryClip (release)"

# App Intents metadata, part 1 of 2. Shortcuts and Spotlight see only the
# intents that appintentsmetadataprocessor writes into Metadata.appintents,
# and it reads them from the compiler's "const values": a JSON dump of the
# literals (title, description, phrases) on every type conforming to one of
# the AppIntents protocols. A plain swift build emits neither the dump nor
# the bundle, so:
#   -emit-const-values            a swiftc driver flag: writes
#                                 <SourceFile>.swiftconstvalues beside each
#                                 object file in MemoryClip.build/
#   -const-gather-protocols-file  frontend-only (hence the -Xfrontend pairs):
#                                 a JSON array naming the protocols whose
#                                 conformers get gathered. This list mirrors
#                                 the file Xcode's build system generates and
#                                 covers everything the intents need
#                                 (AppIntent, AppEntity, AppEnum, EntityQuery,
#                                 AppShortcutsProvider, DynamicOptionsProvider).
APPINTENTS_DIR=".build/appintents"
CONST_PROTOCOLS="$APPINTENTS_DIR/const_extract_protocols.json"
mkdir -p "$APPINTENTS_DIR"
cat > "$CONST_PROTOCOLS" <<'EOF'
["AppIntent","EntityQuery","AppEntity","TransientEntity","AppEnum","AppShortcutProviding","AppShortcutsProvider","AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider"]
EOF

swift build -c release \
    -Xswiftc -emit-const-values \
    -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file \
    -Xswiftc -Xfrontend -Xswiftc "$PWD/$CONST_PROTOCOLS"

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
# FSL asks that the terms travel with any copy, and most copies of MemoryClip are
# this bundle rather than the repository.
cp "LICENSE" "$APP/Contents/Resources/LICENSE"

# The string catalogues: Bundle.module resolves against Contents/Resources,
# for this module and for every package with resources — a missing bundle is
# a fatalError the first time that package localizes a string (Recorder in
# KeyboardShortcuts does it in its initializer, so the Shortcuts settings
# pane cannot open without KeyboardShortcuts_KeyboardShortcuts.bundle).
for bundle in "$(dirname "$BIN")"/*_*.bundle; do
    [ -d "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
done
if [ ! -d "$APP/Contents/Resources/MemoryClip_MemoryClip.bundle" ]; then
    echo "error: MemoryClip_MemoryClip.bundle not found; the localization catalogue would be missing" >&2
    exit 1
fi

# InfoPlist.strings, for the permission prompts macOS reads out of Info.plist.
for lproj in Resources/*.lproj; do
    [ -d "$lproj" ] || continue
    cp -R "$lproj" "$APP/Contents/Resources/"
done

# App Intents metadata, part 2 of 2: what Xcode's ExtractAppIntentsMetadata
# build phase does for an .xcodeproj, done by hand for this SwiftPM build.
# The processor writes <output>/Metadata.appintents/{extract.actionsdata,
# version.json}, so --output is the app's Resources directory, and it has to
# land before the ad-hoc signature so the bundle signs as a whole.
#
# The invocation mirrors the Xcode 15+ one (cross-checked against
# rules_apple's app_intents.bzl, which replays it flag for flag):
#   --toolchain-dir    active toolchain, home of the extractor's helpers
#   --sdk-root         SDK the module was compiled against
#   --module-name      the Swift module the intents live in
#   --xcode-version    Xcode build version string, recorded in version.json
#   --platform-family  macOS for an app target
#   --deployment-target  matches platforms: [.macOS(.v26)] in Package.swift
#   --target-triple    one per built arch; this build is the host arch only
#   --binary-file      required even in compile-time mode (Apple FB347041279):
#                      the executable is passed although it is not read
#   --source-file-list       newline-separated list of the module's .swift
#                            files (scanned for @AppIntent(schema:) macros)
#   --swift-const-vals-list  newline-separated list of .swiftconstvalues paths
#   --compile-time-extraction  read the const values (Xcode 15+ mode; without
#                            it the tool does a legacy binary scan instead)
#   --force            skip the .dat dependency-file check, which expects a
#                      libtool dependency file SwiftPM does not produce
BUILD_DIR="$(dirname "$BIN")"
SOURCE_LIST="$APPINTENTS_DIR/sources.list"
CONST_LIST="$APPINTENTS_DIR/constvalues.list"
find "$PWD/Sources/MemoryClip" -name '*.swift' -print | sort > "$SOURCE_LIST"

# The const-values files sit beside the emitted objects, and the build
# systems disagree about where that is: the classic layout puts
# MemoryClip.build next to the product, the swiftbuild backend — the
# default now that 'native' is deprecated — nests it under
# .build/out/Intermediates.noindex. Take the first candidate that actually
# yields files, and keep only this configuration's: a shared intermediates
# tree can also hold Debug's.
CONST_LIST_TMP="$(mktemp -t memoryclip-constvalues)"
: > "$CONST_LIST"
for candidate in \
    "$BUILD_DIR/MemoryClip.build" \
    "$PWD/.build/arm64-apple-macosx/release/MemoryClip.build" \
    "$PWD/.build/out/Intermediates.noindex/MemoryClip.build"; do
    [ -d "$candidate" ] || continue
    find "$candidate" -name '*.swiftconstvalues' -print | grep -v '/Debug/' | sort > "$CONST_LIST_TMP"
    [ -s "$CONST_LIST_TMP" ] && { mv "$CONST_LIST_TMP" "$CONST_LIST"; break; }
done
rm -f "$CONST_LIST_TMP"
if [ ! -s "$CONST_LIST" ]; then
    echo "error: no .swiftconstvalues found; looked beside $BIN, under" >&2
    echo "       .build/arm64-apple-macosx/release and .build/out/Intermediates.noindex" >&2
    echo "       an incremental build skips unchanged files; delete .build and rerun" >&2
    exit 1
fi

XCODE_BUILD="$(xcodebuild -version 2>/dev/null | awk '/Build version/ {print $3}')"
META_LOG="$APPINTENTS_DIR/metadataprocessor.log"
if ! xcrun appintentsmetadataprocessor \
    --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
    --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
    --module-name MemoryClip \
    --xcode-version "${XCODE_BUILD:-unknown}" \
    --platform-family macOS \
    --deployment-target 26.0 \
    --target-triple "$(uname -m)-apple-macos26.0" \
    --binary-file "$BIN" \
    --source-file-list "$SOURCE_LIST" \
    --swift-const-vals-list "$CONST_LIST" \
    --output "$APP/Contents/Resources" \
    --force --compile-time-extraction \
    > "$META_LOG" 2>&1
then
    cat "$META_LOG" >&2
    echo "error: appintentsmetadataprocessor exited nonzero" >&2
    exit 1
fi

# The processor is known to exit 0 even on halting extraction errors, and a
# target with no gathered intents only logs "skipping writing output": the
# bundle on disk is the ground truth either way.
cat "$META_LOG"
if [ ! -f "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" ]; then
    echo "error: $APP/Contents/Resources/Metadata.appintents was not produced" >&2
    exit 1
fi
echo "==> Wrote $APP/Contents/Resources/Metadata.appintents"

# Ad-hoc signature: no Developer ID, no notarisation (local/personal use).
codesign --force --sign - "$APP"

echo "OK: built $APP"
