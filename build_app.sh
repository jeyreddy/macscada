#!/bin/bash
set -euo pipefail

PRODUCT="IndustrialHMI"
APP_BUNDLE="${PRODUCT}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"
RELEASE_BIN=".build/release/${PRODUCT}"

echo "==> Building release binary..."
swift build -c release

echo "==> Creating app bundle structure..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS}"

echo "==> Copying binary..."
cp "${RELEASE_BIN}" "${MACOS}/${PRODUCT}"

echo "==> Writing Info.plist..."
cat > "${CONTENTS}/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Industrial HMI</string>
    <key>CFBundleDisplayName</key>
    <string>Industrial HMI</string>
    <key>CFBundleExecutable</key>
    <string>IndustrialHMI</string>
    <key>CFBundleIdentifier</key>
    <string>com.jeyreddy.industrialhmi</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026</string>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
</dict>
</plist>
EOF

echo "==> Removing quarantine attribute..."
xattr -cr "${APP_BUNDLE}" 2>/dev/null || true

echo ""
echo "✅  Build complete: ${PWD}/${APP_BUNDLE}"
echo ""
echo "To launch now:"
echo "  open ${APP_BUNDLE}"
echo ""
echo "To install in Applications folder:"
echo "  cp -r ${APP_BUNDLE} /Applications/"
echo "  open /Applications/${APP_BUNDLE}"
echo ""
