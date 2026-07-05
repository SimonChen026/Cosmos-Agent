#!/bin/zsh
# Builds dist/Cosmos.app from the release binary. Pass --install to also
# copy it to ~/Applications/Cosmos.app. Local only — nothing is uploaded.
set -euo pipefail
cd "$(dirname "$0")/.."

# Only the Cosmos product: the forge-tests target needs @testable and is
# debug-only.
swift build -c release --product Cosmos

APP=dist/Cosmos.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Cosmos "$APP/Contents/MacOS/Cosmos"

# Strip local symbols + debug stabs. SwiftPM otherwise embeds absolute
# build paths (…/.build/…/*.swift.o) in the symbol table, which would
# leak the builder's home directory in any distributed binary.
strip -S -x "$APP/Contents/MacOS/Cosmos"

if [[ ! -f scripts/AppIcon.icns ]]; then
    ./scripts/make_icon.sh
fi
cp scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.local.cosmos</string>
    <key>CFBundleName</key>
    <string>Cosmos</string>
    <key>CFBundleDisplayName</key>
    <string>Cosmos</string>
    <key>CFBundleExecutable</key>
    <string>Cosmos</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.3.0</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHumanReadableCopyright</key>
    <string>Local only.</string>
</dict>
</plist>
PLIST

codesign --force --sign "Cosmos Local Dev" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/Cosmos.app"
    ditto "$APP" "$HOME/Applications/Cosmos.app"
    echo "Installed to $HOME/Applications/Cosmos.app"
fi
