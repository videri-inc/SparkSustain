#!/bin/zsh
# Builds SparkSustain.app and installs it (Desktop alias included).
set -euo pipefail

PROJECT_DIR="${0:a:h}"
APP_NAME="SparkSustain"
# Build outside OneDrive: its sync metadata (resource forks/xattrs) breaks codesign.
BUILD_DIR="/tmp/sparksustain-build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

# OneDrive keeps eating project files — keep a durable backup outside it.
BACKUP="$HOME/Library/Application Support/SparkSustain/source-backup"
mkdir -p "$BACKUP"
cp -R "$PROJECT_DIR/Sources" "$BACKUP/" 2>/dev/null || true
cp "$PROJECT_DIR/build.sh" "$PROJECT_DIR/Manual.html" "$PROJECT_DIR/AppIcon.icns" "$BACKUP/" 2>/dev/null || true
[[ -d "$PROJECT_DIR/windows" ]] && { rm -rf "$BACKUP/windows"; cp -R "$PROJECT_DIR/windows" "$BACKUP/windows"; } || true

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$PROJECT_DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/Manual.html" "$APP_DIR/Contents/Resources/Manual.html"

# Pin the deployment target: without -target, swiftc infers a floor from the
# build machine's OS, which can land ABOVE the OS you're shipping to and makes
# LaunchServices refuse the app with -10825. Must match LSMinimumSystemVersion.
swiftc -O \
  -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit \
  -framework Carbon \
  -framework IOKit \
  -framework Network \
  -framework ServiceManagement \
  -o "$APP_DIR/Contents/MacOS/$APP_NAME" \
  "$PROJECT_DIR/Sources/main.swift"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>SparkSustain</string>
    <key>CFBundleDisplayName</key><string>SparkSustain</string>
    <key>CFBundleIdentifier</key><string>com.videri.jay.sparksustain</string>
    <key>CFBundleVersion</key><string>1.10</string>
    <key>CFBundleShortVersionString</key><string>1.10</string>
    <key>CFBundleExecutable</key><string>SparkSustain</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
    <key>DTPlatformName</key><string>macosx</string>
    <key>DTSDKName</key><string>macosx26.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# --- Control Center widget extension (requires full Xcode) ----------------
XCODE_DEV="/Applications/Xcode.app/Contents/Developer"
if [[ -d "$XCODE_DEV" ]]; then
  echo "Building Control Center widget extension..."
  APPEX="$APP_DIR/Contents/Extensions/SparkSustainControl.appex"
  mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"

  CONSTVALS="$BUILD_DIR/ControlWidget.swiftconstvalues"
  # swiftc wants a flat JSON array of protocol names; Xcode ships a wrapped format
  PROTOCOLS="$BUILD_DIR/appintents-protocols.json"
  python3 -c "import json,sys; d=json.load(open('$XCODE_DEV/Toolchains/XcodeDefault.xctoolchain/usr/share/swift/SwiftConstantValues/AppIntents.json')); json.dump(d.get('constValueProtocols', d), open('$PROTOCOLS','w'))"
  if ! DEVELOPER_DIR="$XCODE_DEV" xcrun swiftc -O -parse-as-library \
    -target "$(uname -m)-apple-macos26.0" \
    -framework WidgetKit -framework SwiftUI -framework AppIntents \
    -Xfrontend -emit-const-values-path -Xfrontend "$CONSTVALS" \
    -Xfrontend -const-gather-protocols-file -Xfrontend "$PROTOCOLS" \
    -o "$APPEX/Contents/MacOS/SparkSustainControl" \
    "$PROJECT_DIR/Sources/ControlWidget.swift"; then
    echo "WARNING: widget extension build failed (Xcode license not accepted?) — continuing without it"
    rm -rf "$APP_DIR/Contents/Extensions"
  else

  cat > "$APPEX/Contents/Info.plist" <<'EXTPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>SparkSustainControl</string>
    <key>CFBundleDisplayName</key><string>Spark Screens</string>
    <key>CFBundleIdentifier</key><string>com.videri.jay.sparksustain.control</string>
    <key>CFBundleVersion</key><string>1.10</string>
    <key>CFBundleShortVersionString</key><string>1.10</string>
    <key>CFBundleExecutable</key><string>SparkSustainControl</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
    <key>DTPlatformName</key><string>macosx</string>
    <key>DTSDKName</key><string>macosx26.0</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>EXAppExtensionAttributes</key>
    <dict>
        <key>EXExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
    </dict>
</dict>
</plist>
EXTPLIST

  echo "$PROJECT_DIR/Sources/ControlWidget.swift" > "$BUILD_DIR/sources.txt"
  echo "$CONSTVALS" > "$BUILD_DIR/constvals.txt"
  DEVELOPER_DIR="$XCODE_DEV" xcrun appintentsmetadataprocessor \
    --binary-file "$APPEX/Contents/MacOS/SparkSustainControl" \
    --module-name SparkSustainControl \
    --source-file-list "$BUILD_DIR/sources.txt" \
    --swift-const-vals-list "$BUILD_DIR/constvals.txt" \
    --output "$APPEX/Contents/Resources" \
    --sdk-root "$(DEVELOPER_DIR="$XCODE_DEV" xcrun --sdk macosx --show-sdk-path)" \
    --toolchain-dir "$XCODE_DEV/Toolchains/XcodeDefault.xctoolchain" \
    --xcode-version "$(DEVELOPER_DIR="$XCODE_DEV" xcodebuild -version | awk 'NR==1{print $2}')" \
    --deployment-target 26.0 \
    --platform-family macOS \
    --target-triple "$(uname -m)-apple-macos26.0" \
    --compile-time-extraction \
    || echo "WARNING: AppIntents metadata extraction failed — control may not appear"

  # WidgetKit only registers sandboxed extensions; the app group is the
  # shared folder the control and the app talk through.
  cat > "$BUILD_DIR/appex.entitlements" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.application-groups</key>
    <array><string>group.com.videri.jay.sparksustain</string></array>
</dict>
</plist>
ENT
  xattr -cr "$APPEX"
  codesign --force --sign - --entitlements "$BUILD_DIR/appex.entitlements" "$APPEX"
  echo "Widget extension built and embedded."
  fi
else
  echo "Xcode not found — skipping Control Center widget extension."
fi

cat > "$BUILD_DIR/app.entitlements" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.application-groups</key>
    <array><string>group.com.videri.jay.sparksustain</string></array>
</dict>
</plist>
ENT
xattr -cr "$APP_DIR"
# Sign the outer app without --deep so the appex keeps its own entitlements.
codesign --force --sign - --entitlements "$BUILD_DIR/app.entitlements" "$APP_DIR"

# /Applications so the Control Center widget is discoverable; fall back to
# ~/Applications when the user can't write there.
INSTALL_DIR="/Applications"
if ! rm -rf "$INSTALL_DIR/$APP_NAME.app" 2>/dev/null || ! cp -R "$APP_DIR" "$INSTALL_DIR/$APP_NAME.app" 2>/dev/null; then
  INSTALL_DIR="$HOME/Applications"
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALL_DIR/$APP_NAME.app"
  cp -R "$APP_DIR" "$INSTALL_DIR/$APP_NAME.app"
fi

# Desktop alias for easy access
ln -sfn "$INSTALL_DIR/$APP_NAME.app" "$HOME/Desktop/$APP_NAME.app" 2>/dev/null || true

echo "Built and installed: $INSTALL_DIR/$APP_NAME.app (alias on Desktop)"
echo "Launch it with: open \"$INSTALL_DIR/$APP_NAME.app\""
