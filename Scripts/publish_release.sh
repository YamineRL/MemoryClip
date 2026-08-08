#!/usr/bin/env bash
set -euo pipefail

# Publish a MemoryClip release to GitHub: tag the commit, create the release,
# and attach the DMG as a downloadable asset.
#
# The repository holds source only — dist/ is gitignored, and the DMG is never
# committed. It reaches users as a release attachment, which is what this does.
#
# Usage:
#   ./Scripts/publish_release.sh            # tag = v<bundle version>
#   ./Scripts/publish_release.sh v0.2.0     # explicit tag
#   DRAFT=1 ./Scripts/publish_release.sh    # draft, so you can eyeball it first
#
# Requires the GitHub CLI, authenticated: `gh auth login`.

cd "$(dirname "$0")/.."
ROOT="$PWD"

die() {
    echo "error: $*" >&2
    exit 1
}

command -v gh >/dev/null 2>&1 || die "the GitHub CLI (gh) is required: brew install gh"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run: gh auth login"

# --- 1. Refuse to publish anything but a clean, pushed tree. ------------------
# A release asset that does not correspond to a commit anyone else can fetch is
# unreproducible, so this is a hard stop rather than a warning.
[ -z "$(git status --porcelain)" ] || die "working tree is dirty — commit or stash first"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git fetch --quiet origin "$BRANCH" 2>/dev/null || die "could not fetch origin/$BRANCH"
[ "$(git rev-parse HEAD)" = "$(git rev-parse "origin/$BRANCH")" ] \
    || die "HEAD differs from origin/$BRANCH — push the source before publishing a binary built from it"

# --- 2. Build the DMG; the version comes from the bundle, never hardcoded. ----
echo "==> Building disk image"
"$ROOT/Scripts/make_dmg.sh"

APP="$ROOT/dist/MemoryClip.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP/Contents/Info.plist" 2>/dev/null || true)"
[ -n "$VERSION" ] || die "could not read CFBundleShortVersionString from $APP/Contents/Info.plist"

DMG="$ROOT/dist/MemoryClip-$VERSION.dmg"
[ -f "$DMG" ] || die "$DMG was not produced by Scripts/make_dmg.sh"

TAG="${1:-v$VERSION}"
CHECKSUM="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "==> $TAG  $(basename "$DMG")  sha256 $CHECKSUM"

# --- 3. Create or update the release. ----------------------------------------
NOTES_FILE="$(mktemp)"
trap 'rm -f "$NOTES_FILE"' EXIT
cat > "$NOTES_FILE" <<NOTES
MemoryClip $VERSION for macOS 26 (Apple silicon).

**Install**: open the DMG and drag MemoryClip to Applications. The app is
**ad-hoc signed only** — no Developer ID, no notarisation — so Gatekeeper will
block the first launch on any Mac that did not build it. Right-click the app →
**Open** and confirm, or run:

\`\`\`sh
xattr -dr com.apple.quarantine /Applications/MemoryClip.app
\`\`\`

MemoryClip is a menu-bar agent with no Dock icon: look for the clipboard glyph
in the menu bar, or press ⇧⌘V.

\`sha256\` of \`$(basename "$DMG")\`:

\`\`\`
$CHECKSUM
\`\`\`
NOTES

if gh release view "$TAG" >/dev/null 2>&1; then
    echo "==> Updating existing release $TAG"
    gh release upload "$TAG" "$DMG" --clobber
else
    echo "==> Creating release $TAG"
    args=(--title "MemoryClip $VERSION" --notes-file "$NOTES_FILE" --prerelease)
    [ "${DRAFT:-0}" = "1" ] && args+=(--draft)
    gh release create "$TAG" "$DMG" "${args[@]}"
fi

echo "OK: $(gh release view "$TAG" --json url --jq .url)"
