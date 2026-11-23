#!/bin/bash
# Assembles and signs "build/Human in the Loop.app" (plan.md section 3.4; the names are docs/brand/brand.md's, section
# 7.1). The SwiftPM product keeps its internal name, Referee; the bundle, the executable inside it and the name Finder
# and the menu bar show are "Human in the Loop". A build/Referee.app of an earlier build is never touched, since it may
# be running: delete it by hand once it is not.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${REFEREE_VERSION:-0.1.0}"
NAME="Human in the Loop"
scripts/build.sh -c release --product Referee
BIN="$(swift build -c release --show-bin-path)/Referee"
APP="build/$NAME.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
# The icon is drawn again when it is missing or older than the script that draws it.
if [[ ! -f build/AppIcon.icns || scripts/make-icon.sh -nt build/AppIcon.icns ]]; then
  scripts/make-icon.sh || echo "bundle.sh: no icon (continuing)"
fi
[[ -f build/AppIcon.icns ]] && cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp README.md "$APP/Contents/Resources/README.md"      # Help ▸ Human in the Loop Help opens it from here
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.referee.app</string>
  <key>CFBundleName</key><string>${NAME}</string>
  <key>CFBundleDisplayName</key><string>${NAME}</string>
  <key>CFBundleExecutable</key><string>${NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>PDF Document</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
  </dict></array>
</dict></plist>
EOF
plutil -lint "$APP/Contents/Info.plist"
if strings -a "$APP/Contents/MacOS/$NAME" | grep -q "$HOME/"; then
  echo "bundle.sh: the binary contains a path under your home directory (a #filePath or #file in a release build?). Remove it before the app is shared." >&2
  exit 1
fi
codesign --force --sign "${REFEREE_SIGN_IDENTITY:--}" "$APP"
codesign --verify --verbose=1 "$APP"
echo "Built $APP"
