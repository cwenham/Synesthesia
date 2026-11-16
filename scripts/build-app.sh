#!/bin/zsh
# Builds Synesthesia as a Mac app bundle at .build/Synesthesia.app.
# Usage: scripts/build-app.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."

config=${1:-release}
swift build -c "$config" --product SynesthesiaMac
swift build -c "$config" --product synesthesia-mcp
bin_path=$(swift build -c "$config" --show-bin-path)

app=.build/Synesthesia.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_path/SynesthesiaMac" "$app/Contents/MacOS/Synesthesia"
# The MCP bridge, for clients such as Claude Code that start a server as a program (design, section 8).
cp "$bin_path/synesthesia-mcp" "$app/Contents/MacOS/synesthesia-mcp"
# Resource bundles SwiftPM made for the targets, if any.
for bundle in "$bin_path"/*.bundle(N); do
    ditto "$bundle" "$app/Contents/Resources/$(basename "$bundle")"
done

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Synesthesia</string>
    <key>CFBundleDisplayName</key>
    <string>Synesthesia</string>
    <key>CFBundleIdentifier</key>
    <string>com.synesthesia.mac</string>
    <key>CFBundleExecutable</key>
    <string>Synesthesia</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# Signed to run on this Mac, outside the sandbox (Q10): it opens the daemon's socket in ~/.meep, and will start
# meep lsp and ssh. A Developer ID signature and notarisation come when it's shared.
codesign --force --sign - --identifier com.synesthesia.mcp "$app/Contents/MacOS/synesthesia-mcp" >/dev/null
codesign --force --sign - --identifier com.synesthesia.mac "$app" >/dev/null
echo "Built $app"
