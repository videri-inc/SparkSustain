#!/bin/zsh
# Build both platforms and publish a release to GitHub:
#   - zips uploaded as release assets on tag v<VERSION>
#   - updates/manifest.json committed to main (what every install polls)
# Usage:   ./publish.sh ["release notes text"]
# Rollback: edit updates/manifest.json to point version/url at any earlier
# release's assets, commit, push — every active install follows within ~4h.
set -euo pipefail

PROJECT="${0:a:h}"
REPO="videri-inc/SparkSustain"
NOTES="${1:-}"
VERSION=$(grep -m1 -A0 'CFBundleShortVersionString' "$PROJECT/build.sh" | grep -oE '[0-9]+\.[0-9]+' | head -1)
echo "Publishing SparkSustain v$VERSION to github.com/$REPO"

# gh is optional: with it, the release is cut automatically; without it, the
# zips and manifest are still produced and the manifest is pushed, and you
# upload the two zips on the release page (URL printed at the end).
HAVE_GH=0
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then HAVE_GH=1; fi

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
if (( HAVE_GH )); then
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
fi

# --- Manifest on main (the update feed) --------------------------------------
# Build the manifest with a real JSON encoder — shell quoting cannot be
# trusted with free-text release notes.
mkdir -p "$PROJECT/updates"
VERSION="$VERSION" NOTES="$NOTES" BASE="$BASE" MAC_SHA="$MAC_SHA" WIN_SHA="$WIN_SHA" \
python3 - > "$PROJECT/updates/manifest.json" <<'PY'
import json, os, datetime
v, base = os.environ["VERSION"], os.environ["BASE"]
print(json.dumps({
    "version":   v,
    "published": datetime.date.today().isoformat(),
    "notes":     os.environ.get("NOTES", ""),
    "mac":     {"url": f"{base}/SparkSustain-Mac-{v}.zip",     "sha256": os.environ["MAC_SHA"]},
    "windows": {"url": f"{base}/SparkSustain-Windows-{v}.zip", "sha256": os.environ["WIN_SHA"]},
}, indent=2))
PY
python3 -c "import json,sys; json.load(open('$PROJECT/updates/manifest.json'))" \
  || { echo "ERROR: generated manifest is not valid JSON"; exit 1; }
cd "$PROJECT"
git add updates/manifest.json
git commit -m "Release v$VERSION" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" >/dev/null || true
git push origin main

echo ""
if (( HAVE_GH )); then
  echo "Published v$VERSION"
  echo "  release: https://github.com/$REPO/releases/tag/v$VERSION"
else
  echo "Manifest pushed. ONE STEP LEFT — upload these two files as release assets:"
  echo "  $STAGE/SparkSustain-Mac-$VERSION.zip"
  echo "  $STAGE/SparkSustain-Windows-$VERSION.zip"
  echo "  at: https://github.com/$REPO/releases/new?tag=v$VERSION"
  echo "  (install gh + 'gh auth login' to skip this step next time)"
fi
echo "  mac     $MAC_SHA"
echo "  windows $WIN_SHA"
echo "Every install picks this up within ~4 hours (or via Check for Updates Now)."
