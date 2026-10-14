#!/bin/bash
# Builds Reader.app with the Swift Package Manager (Command Line Tools are enough; Xcode isn't
# needed) and ad-hoc signs it. Usage: scripts/build-app.sh [debug|release]
#   READER_SYNC_SERVER       sync server the app signs in to (default: the deployed Worker)
#   READER_GOOGLE_CLIENT_ID  Google OAuth client id (iOS/macOS type) for "Continue with Google"
#   READER_BUNDLE_ID         default io.github.satyanvm.reader; a different id (and app name, from
#   READER_APP_NAME)         READER_APP_NAME) makes a side-by-side dev copy
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
SYNC_SERVER="${READER_SYNC_SERVER:-https://reader-sync.satyanarayanv2050.workers.dev}"
GOOGLE_CLIENT_ID="${READER_GOOGLE_CLIENT_ID:-}"
BUNDLE_ID="${READER_BUNDLE_ID:-io.github.satyanvm.reader}"
APP_NAME="${READER_APP_NAME:-Reader}"

swift build -c "$CONFIG" --product Reader
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Reader"

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Reader"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>Reader</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.books</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>ReaderSyncServer</key><string>$SYNC_SERVER</string>
    <key>GoogleClientID</key><string>$GOOGLE_CLIENT_ID</string>
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsLocalNetworking</key><true/></dict>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>PDF Document</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>EPUB Book</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>org.idpf.epub-container</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warning: ad-hoc signing failed" >&2
echo "Built $(pwd)/$APP"
