#!/usr/bin/env zsh
# release.sh — Build, verify, package, and publish a Barkeep release.
#
# Usage: ./release.sh <version>
#   e.g. ./release.sh 1.0
#
# Requires: xcodebuild, hdiutil, gh (GitHub CLI), git

set -euo pipefail

REPO="sevmorris/Barkeep"

# ── Args ──────────────────────────────────────────────────────────────────────
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <version>"
    echo "  e.g. $0 1.0"
    exit 1
fi

VERSION="$1"
TAG="v${VERSION}"
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="$SCRIPT_DIR"
PROJECT="$PROJECT_DIR/Barkeep.xcodeproj"
SCHEME="Barkeep"
DERIVED_DATA="/tmp/barkeep_build_${VERSION}"
APP_PATH="$DERIVED_DATA/Build/Products/Release/Barkeep.app"
STAGING="/tmp/barkeep_dmg_${VERSION}"
DMG="/tmp/Barkeep-${TAG}.dmg"
MOUNT="/tmp/barkeep_verify_${VERSION}"

# ── Helpers ───────────────────────────────────────────────────────────────────
step()  { echo "\n▶ $*"; }
ok()    { echo "  ✓ $*"; }
fail()  { echo "\n  ✗ $*" >&2; exit 1; }
warn()  { echo "  ! $*" >&2; }

cleanup() {
    rm -rf "$STAGING" "$MOUNT" "$DERIVED_DATA"
    rm -f "$DMG"
}

# ── Preflight ─────────────────────────────────────────────────────────────────
step "Preflight checks"
for cmd in xcodebuild hdiutil gh git; do
    command -v $cmd &>/dev/null || fail "'$cmd' not found in PATH"
done
ok "Tools present"

cd "$PROJECT_DIR"

if [[ -n "$(git status --porcelain)" ]]; then
    fail "Working tree is dirty — commit or stash changes before releasing"
fi
ok "Working tree clean"

if git tag | grep -q "^${TAG}$"; then
    fail "Tag $TAG already exists — has this version been released?"
fi
ok "Tag $TAG is available"

# ── Version ordering ────────────────────────────────────────────────────────────────────────
# Nothing here stopped a release going backwards. On 2026-09-03 Magic Backup
# Machine published v1.3.9 on top of v1.4.2 — two sessions releasing from one
# clone, neither aware of the other. GitHub served the older build as "latest"
# from that moment, and because the update checker compares numerically, every
# client already on 1.4.2 read 1.3.9 as older and reported itself up to date.
# The release could not reach anyone.
#
# Tags are the record of what is actually published, and what "latest" keys on,
# so they are what this compares against. Set ALLOW_DOWNGRADE=1 to override.
step "Checking version ordering"
version_core() { printf '%s' "${1%%[-+]*}"; }
HIGHEST_TAG=$(git tag --sort=-v:refname | head -1 | sed 's/^v//')
if [[ -n "$HIGHEST_TAG" ]]; then
    NEW_CORE=$(version_core "$VERSION")
    REF_CORE=$(version_core "$HIGHEST_TAG")
    # Numeric cores only: `sort -V` places 1.7.0 ahead of 1.7.0-rc.1, backwards
    # from semver, and comparing raw strings would block any release that
    # follows its own release candidate.
    if [[ "$NEW_CORE" != "$REF_CORE" ]] \
       && [[ "$(printf '%s\n%s\n' "$NEW_CORE" "$REF_CORE" | sort -V | head -1)" == "$NEW_CORE" ]]; then
        if [[ "${ALLOW_DOWNGRADE:-0}" != "0" ]]; then
            warn "$VERSION sorts below tag v$HIGHEST_TAG — continuing, ALLOW_DOWNGRADE is set"
        else
            fail "$VERSION sorts below the highest tag v$HIGHEST_TAG. Publishing it would leave GitHub serving an older build as 'latest', and clients on $HIGHEST_TAG would be told they are up to date. Set ALLOW_DOWNGRADE=1 to override."
        fi
    fi
fi
ok "Version $VERSION does not go backwards"


# ── Version bump ──────────────────────────────────────────────────────────────
step "Bumping version to $VERSION"
PLIST="$PROJECT_DIR/Barkeep/Info.plist"
CURRENT=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PLIST" 2>/dev/null || echo "")
if [[ "$CURRENT" == "$VERSION" ]]; then
    ok "Already at $VERSION — skipping bump"
else
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST"
    ok "Bumped $CURRENT → $VERSION"
    git add "$PLIST"
    git commit -m "Bump version to $VERSION"
    ok "Committed version bump"
fi

# ── Build ─────────────────────────────────────────────────────────────────────
step "Building (clean, Release)"
rm -rf "$DERIVED_DATA"
rm -rf ~/Library/Caches/com.apple.dt.Xcode/ 2>/dev/null || true
rm -rf ~/Library/Developer/Xcode/DerivedData/ModuleCache* 2>/dev/null || true
ok "Xcode caches cleared"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -quiet
[[ -d "$APP_PATH" ]] || fail "Build did not produce $APP_PATH"
ok "Build complete"

# ── Sign ──────────────────────────────────────────────────────────────────────
step "Codesigning app"
IDENTITY="Developer ID Application: Seven Morris (T9RLNAXPWU)"
ENTITLEMENTS="$PROJECT_DIR/Barkeep/Barkeep.entitlements"

# Sign the app bundle with Hardened Runtime
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 | tail -3
ok "Codesigning complete"

# ── Verify app version ────────────────────────────────────────────────────────
step "Verifying built app version"
BUILT_VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)
[[ "$BUILT_VERSION" == "$VERSION" ]] || \
    fail "App version mismatch: expected $VERSION, got $BUILT_VERSION"
ok "App reports $BUILT_VERSION"

# ── Stage DMG contents ────────────────────────────────────────────────────────
step "Staging DMG contents"
rm -rf "$STAGING"
mkdir "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
ok "App, Applications alias"

# ── Create DMG ────────────────────────────────────────────────────────────────
step "Creating DMG"
rm -f "$DMG"
hdiutil create \
    -volname "Barkeep $TAG" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    -o "$DMG" \
    -quiet
ok "Created $(du -sh $DMG | cut -f1) DMG"

# ── Notarize ──────────────────────────────────────────────────────────────────
step "Notarizing DMG"
# Reusing 'WoWoNotary' profile
xcrun notarytool submit "$DMG" --wait --keychain-profile "WoWoNotary"
xcrun stapler staple "$DMG"
ok "Notarization complete"

# ── Verify DMG ────────────────────────────────────────────────────────────────
step "Verifying DMG contents"
rm -rf "$MOUNT"
mkdir "$MOUNT"
hdiutil attach "$DMG" -mountpoint "$MOUNT" -quiet -nobrowse
DMG_VERSION=$(defaults read "$MOUNT/Barkeep.app/Contents/Info.plist" CFBundleShortVersionString)
hdiutil detach "$MOUNT" -quiet
[[ "$DMG_VERSION" == "$VERSION" ]] || \
    fail "DMG version mismatch: expected $VERSION, got $DMG_VERSION"
ok "DMG contains $DMG_VERSION"

# ── Update docs (README) ─────────────────────────────────────────────────────
step "Updating README to ${TAG}"
sed -i '' "s|Barkeep-v[0-9][0-9.]*\.dmg|Barkeep-${TAG}.dmg|g" README.md
sed -i '' "s|Download v[0-9][0-9.]*|Download ${TAG}|g" README.md

if [[ -n "$(git status --porcelain README.md)" ]]; then
    git add README.md
    git commit -m "docs: update download link to ${TAG}"
    ok "README updated to ${TAG}"
else
    ok "README already up to date"
fi

# ── Tag and push ──────────────────────────────────────────────────────────────
step "Tagging and pushing"
git tag "$TAG"
# Resolve the tracked remote/branch so this works from any branch (e.g. a
# worktree branch whose name differs from its upstream). Fall back to
# `origin` + current branch when no upstream is configured; `-u` sets it
# on first push so subsequent runs resolve cleanly.
if UPSTREAM=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null); then
    REMOTE="${UPSTREAM%%/*}"
    BRANCH="${UPSTREAM#*/}"
else
    REMOTE="origin"
    BRANCH=$(git branch --show-current)
fi
git push -u "$REMOTE" "HEAD:$BRANCH"
git push "$REMOTE" "$TAG"
ok "Pushed $TAG to $REMOTE/$BRANCH"

# ── GitHub release ────────────────────────────────────────────────────────────
step "Creating GitHub release"
PREV_TAG=$(git tag --sort=-creatordate | grep -v "^${TAG}$" | head -1 || true)
if [[ -n "$PREV_TAG" ]]; then
    CHANGES=$(git log "${PREV_TAG}..HEAD" --pretty=format:"- %s" \
        | grep -v "^- Bump version" \
        | grep -v "^- docs: update download link" || true)
else
    CHANGES=$(git log --pretty=format:"- %s" \
        | grep -v "^- Bump version" \
        | grep -v "^- docs: update download link" || true)
fi
[[ -n "$CHANGES" ]] || CHANGES="- Initial release"
RELEASE_NOTES="### Changes
${CHANGES}"
gh release create "$TAG" "$DMG" \
    --repo "$REPO" \
    --title "Barkeep $TAG" \
    --notes "$RELEASE_NOTES"
ok "Release published"

# ── Remove old releases (keep the ${KEEP_RELEASES} most recent) ───────────────
KEEP_RELEASES=5
step "Removing old releases (keeping ${KEEP_RELEASES} most recent)"
# Filtered to v* so non-release tags (build-dependency releases, checkpoints)
# are never in scope for pruning by date alone.
OLD_TAGS=$(gh release list --repo "$REPO" --limit 100 --json tagName \
    --jq '.[].tagName' | grep -E '^v[0-9]' | tail -n +$((KEEP_RELEASES + 1)) || true)
if [[ -z "$OLD_TAGS" ]]; then
    ok "No old releases to remove"
else
    while IFS= read -r old_tag; do
        # Prunes the release page and its asset, NOT the git tag. The tag is the
        # only durable pointer to what shipped: without it a version is
        # unbuildable from a clean clone and unreachable from its own history.
        # A release page is a convenience; a tag is the record.
        gh release delete "$old_tag" --repo "$REPO" --yes 2>/dev/null || true
        ok "Pruned release page for $old_tag (tag kept)"
    done <<< "$OLD_TAGS"
fi

# ── Clean up temp files ───────────────────────────────────────────────────────
step "Cleaning up"
rm -rf "$STAGING" "$MOUNT" "$DERIVED_DATA"
rm -f "$DMG"
ok "Temp files removed"

# ── Open release page ─────────────────────────────────────────────────────────
RELEASE_URL="https://github.com/${REPO}/releases/tag/${TAG}"
echo "\n✓ Barkeep $TAG released successfully."
echo "  $RELEASE_URL"
open "$RELEASE_URL"
