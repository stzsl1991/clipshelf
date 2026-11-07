#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
app="$PWD/build/拾贴验收.app"
mkdir -p "$app/Contents/MacOS"
xcrun swiftc -target arm64-apple-macos13.0 -module-cache-path "$PWD/build/module-cache" Tests/PasteProbe.swift -framework AppKit -o "$app/Contents/MacOS/PasteProbe"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>PasteProbe</string><key>CFBundleIdentifier</key><string>com.shulin.ClipShelf.Probe</string><key>CFBundleName</key><string>拾贴验收</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
codesign --force --sign - "$app"
printf 'Built verification target: %s\n' "$app"
