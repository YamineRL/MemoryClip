#!/usr/bin/env bash
set -euo pipefail

# Point Casks/memoryclip.rb at a published release: rewrite its version and
# sha256 to match the zip attached to that release.
#
# The cask lives in this repository, which doubles as the Homebrew tap:
#
#   brew tap yaminerl/memoryclip https://github.com/YamineRL/MemoryClip
#   brew install --cask memoryclip
#
# So a release whose cask still names the previous version installs the
# previous version. Scripts/publish_release.sh runs this for you; run it by
# hand only to repair a cask that drifted.
#
# The checksum is taken from the asset GitHub actually serves, never from the
# local dist/ copy — that is the file users download, and fetching it also
# proves the release exists before the cask starts pointing at it.
#
# Usage:
#   ./Scripts/update_cask.sh            # version = <bundle version>
#   ./Scripts/update_cask.sh 0.2.48     # explicit version

cd "$(dirname "$0")/.."
ROOT="$PWD"

CASK="$ROOT/Casks/memoryclip.rb"
REPO="YamineRL/MemoryClip"

die() {
    echo "error: $*" >&2
    exit 1
}

[ -f "$CASK" ] || die "$CASK not found"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$ROOT/Resources/Info.plist" 2>/dev/null || true)"
    [ -n "$VERSION" ] || die "could not read CFBundleShortVersionString from Resources/Info.plist"
fi

URL="https://github.com/$REPO/releases/download/v$VERSION/MemoryClip-$VERSION.zip"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/memoryclip-cask.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

echo "==> Fetching $URL"
curl -fsSL --retry 3 -o "$TMP/MemoryClip.zip" "$URL" \
    || die "could not download the release asset — is v$VERSION published with MemoryClip-$VERSION.zip attached?"

SHA="$(shasum -a 256 "$TMP/MemoryClip.zip" | cut -d' ' -f1)"
[ -n "$SHA" ] || die "could not checksum the downloaded asset"

# The zip must contain the app bundle the cask promises to install; a cask
# whose `app` stanza names something the archive does not hold fails at the
# very end of an install, on the user's machine.
# Listed into a variable rather than piped into `grep -q`: grep leaves on the
# first match, unzip dies of the broken pipe, and under `pipefail` a perfectly
# good archive reads as a failure.
LISTING="$(unzip -l "$TMP/MemoryClip.zip")" || die "could not read the downloaded zip"
case "$LISTING" in
    *"MemoryClip.app/"*) ;;
    *) die "the downloaded zip has no MemoryClip.app inside it" ;;
esac

echo "==> $VERSION  sha256 $SHA"

# Anchored to the two-space indent of a cask stanza, so nothing inside the
# url, the caveats or a comment can be rewritten by accident.
sed -i '' \
    -e "s|^  version \".*\"$|  version \"$VERSION\"|" \
    -e "s|^  sha256 \".*\"$|  sha256 \"$SHA\"|" \
    "$CASK"

grep -qx "  version \"$VERSION\"" "$CASK" || die "version stanza in $CASK did not update"
grep -qx "  sha256 \"$SHA\"" "$CASK" || die "sha256 stanza in $CASK did not update"

# `brew style` parses the file as Homebrew will: a cask that fails here is one
# `brew install` would choke on.
if command -v brew >/dev/null 2>&1; then
    echo "==> Linting the cask"
    brew style "$CASK" >/dev/null || die "brew style rejected $CASK"
fi

echo "OK: Casks/memoryclip.rb -> $VERSION"
