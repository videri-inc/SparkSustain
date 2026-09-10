#!/bin/zsh
# SparkSustain installer — copies the app to ~/Applications, clears the
# download quarantine flag, and launches it.
set -e

DIR="${0:a:h}"
APP_SRC="$DIR/SparkSustain.app"
# /Applications so the Control Center widget is discoverable; fall back to
# ~/Applications when this account can't write there.
if [[ -w "/Applications" ]]; then
  APP_DEST="/Applications/SparkSustain.app"
else
  APP_DEST="$HOME/Applications/SparkSustain.app"
fi

echo ""
echo "  SparkSustain installer"
echo "  -------------------"

if [[ ! -d "$APP_SRC" ]]; then
  echo "  ERROR: SparkSustain.app not found next to this installer."
  echo "  Keep the installer and SparkSustain.app in the same folder and try again."
  read -k 1 -s "?  Press any key to close..."
  exit 1
fi

# Stop a running copy so the binary can be replaced
osascript -e 'quit app "SparkSustain"' >/dev/null 2>&1 || true
sleep 1

mkdir -p "$(dirname "$APP_DEST")" 2>/dev/null || true
rm -rf "$APP_DEST"
cp -R "$APP_SRC" "$APP_DEST"

# Clear the quarantine attribute macOS adds to downloaded files
xattr -dr com.apple.quarantine "$APP_DEST" 2>/dev/null || true

# Convenience alias on the Desktop
ln -sfn "$APP_DEST" "$HOME/Desktop/SparkSustain.app" 2>/dev/null || true

echo "  Installed to $APP_DEST (alias on your Desktop)."
echo "  Launching SparkSustain — look for the sun icon in your menu bar."
echo ""
echo "  Next: follow the Setup Guide (in this folder) to pair your API key"
echo "  and pick your Sparks."
echo ""

open "$APP_DEST"
read -k 1 -s "?  Press any key to close this window..."
