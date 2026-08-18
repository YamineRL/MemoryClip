#!/usr/bin/env bash
set -euo pipefail

# Set the version MemoryClip ships as.
#
# Everything downstream reads the version out of Resources/Info.plist —
# make_app.sh copies it into the bundle, make_dmg.sh and publish_release.sh
# name their artefacts after it, update_cask.sh points the Homebrew cask at
# it. Until this script existed, the one file they all read was the one file
# nothing wrote, so a release began by hand-editing XML that AGENTS.md says
# not to hand-edit.
#
# CFBundleVersion moves with it, always. macOS uses the build number, not the
# marketing version, to decide whether a bundle it has seen before has
# changed; two releases sharing a build number are two releases Launch
# Services and the update machinery are entitled to confuse.
#
# Nothing is committed or tagged here. publish_release.sh refuses a dirty tree
# anyway, so the commit is the caller's, deliberately.
#
# Usage:
#   ./Scripts/bump_version.sh 0.4.0

cd "$(dirname "$0")/.."
PLIST="$PWD/Resources/Info.plist"

die() {
    echo "error: $*" >&2
    exit 1
}

VERSION="${1:-}"
[ -n "$VERSION" ] || die "usage: $0 <version>   (e.g. 0.4.0)"
# Three dot-separated numbers, nothing else: the tag, the DMG name, the zip
# name and the cask's URL are all built from this, and every one of them is
# public the moment the release is created.
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || die "'$VERSION' is not a X.Y.Z version"
[ -f "$PLIST" ] || die "$PLIST not found"

OLD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" \
    || die "could not read CFBundleShortVersionString from $PLIST"
OLD_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")" \
    || die "could not read CFBundleVersion from $PLIST"

echo "$OLD_BUILD" | grep -Eq '^[0-9]+$' \
    || die "CFBundleVersion is '$OLD_BUILD', which cannot be incremented"
NEW_BUILD=$((OLD_BUILD + 1))

[ "$VERSION" != "$OLD_VERSION" ] || die "Info.plist already says $VERSION"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"

echo "OK: $OLD_VERSION (build $OLD_BUILD) -> $VERSION (build $NEW_BUILD)"
echo "    commit Resources/Info.plist, then: ./Scripts/publish_release.sh"
