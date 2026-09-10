#!/bin/zsh
# Build both platforms and publish a release to GitHub:
#   - zips uploaded as release assets on tag v<VERSION>
#   - updates/manifest.json committed to main (what every install polls)
# Usage:   ./publish.sh ["release notes text"]
# Rollback: edit updates/manifest.json to point version/url at any earlier
# release's assets, commit, push — every active install follows within ~4h.
set -euo pipefail

PROJECT="${0:a:h}"
REPO="leedyboy-26/SparkSustain"
NOTES="${1:-}"
VERSION=$(grep -m1 -A0 'CFBundleShortVersionString' "$PROJECT/build.sh" | grep -oE '[0-9]+\.[0-9]+' | head -1)
echo "Publishing SparkSustain v$VERSION to github.com/$REPO"

command -v gh >/dev/null || { echo "ERROR: gh CLI not installed (brew install gh, then gh auth login)"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated — run: gh auth login"; exit 1; }

"$PROJECT/build.sh" >/dev/null

STAGE=/tmp/ss-publish
rm -rf "$STAGE" && mkdir -p "$STAGE"

# --- Mac zip ---------------------------------------------------------------
rm -rf /tmp/ss-mac && mkdir -p /tmp/ss-mac
cp -R "$PROJECT/dist/SparkSustain-Installer" /tmp/ss-mac/SparkSustain-Mac
rm -rf /tmp/ss-mac/SparkSustain-Mac/SparkSustain.app
cp -R /tmp/sparksustain-build/SparkSustain.app /tmp/ss-mac/SparkSustain-Mac/SparkSustain.app
cp "$PROJECT/Manual.html" /tmp/ss-mac/SparkSustain-Mac/Manual.html
find /tmp/ss-mac \( -name "._*" -o -name ".DS_Store" \) -delete
( cd /tmp/ss-mac && COPYFILE_DISABLE=1 zip -rXq "$STAGE/SparkSustain-Mac-$VERSION.zip" SparkSustain-Mac )

# --- Windows zip -----------------------------------------------------------
rm -rf /tmp/ss-win && mkdir -p /tmp/ss-win
cp -R "$PROJECT/windows" /tmp/ss-win/SparkSustain-Windows
find /tmp/ss-win \( -name "._*" -o -name ".DS_Store" \) -delete
( cd /tmp/ss-win && COPYFILE_DISABLE=1 zip -rXq "$STAGE/SparkSustain-Windows-$VERSION.zip" SparkSustain-Windows )

MAC_SHA=$(shasum -a 256 "$STAGE/SparkSustain-Mac-$VERSION.zip" | awk '{print $1}')
WIN_SHA=$(shasum -a 256 "$STAGE/SparkSustain-Windows-$VERSION.zip" | awk '{print $1}')
BASE="https://github.com/$REPO/releases/download/v$VERSION"

# --- GitHub release ----------------------------------------------------------
if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release v$VERSION exists — replacing assets"
  gh release upload "v$VERSION" --repo "$REPO" --clobber \
    "$STAGE/SparkSustain-Mac-$VERSION.zip" "$STAGE/SparkSustain-Windows-$VERSION.zip"
else
  gh release create "v$VERSION" --repo "$REPO" \
    --title "SparkSustain v$VERSION" \
    --notes "${NOTES:-SparkSustain v$VERSION}" \
    "$STAGE/SparkSustain-Mac-$VERSION.zip" "$STAGE/SparkSustain-Windows-$VERSION.zip"
fi

# --- Manifest on main (the update feed) --------------------------------------
mkdir -p "$PROJECT/updates"
cat > "$PROJECT/updates/manifest.json" <<EOF
{
  "version": "$VERSION",
  "published": "$(date +%Y-%m-%d)",
  "notes": "${NOTES//\"/\\\"}",
  "mac": { "url": "$BASE/SparkSustain-Mac-$VERSION.zip", "sha256": "$MAC_SHA" },
  "windows": { "url": "$BASE/SparkSustain-Windows-$VERSION.zip", "sha256": "$WIN_SHA" }
}
EOF
cd "$PROJECT"
git add updates/manifest.json
git commit -m "Release v$VERSION" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" >/dev/null || true
git push origin main

echo ""
echo "Published v$VERSION"
echo "  release: https://github.com/$REPO/releases/tag/v$VERSION"
echo "  mac     $MAC_SHA"
echo "  windows $WIN_SHA"
echo "Every install picks this up within ~4 hours (or via Check for Updates Now)."
