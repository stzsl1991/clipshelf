#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
app="$PWD/build/拾贴.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" build/module-cache
xcrun swiftc -O -target arm64-apple-macos13.0 -module-cache-path "$PWD/build/module-cache" \
  Sources/Model.swift Sources/Clipboard.swift Sources/HistoryWindow.swift Sources/SettingsWindow.swift Sources/App.swift Sources/main.swift \
  -framework AppKit -framework Carbon -framework ApplicationServices -framework CryptoKit -framework Security -framework ServiceManagement \
  -o "$app/Contents/MacOS/ClipShelf"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$app/Contents/Resources/"; fi
scripts/signing.sh "$app"
codesign --verify --strict "$app"
plutil -lint "$app/Contents/Info.plist"
printf 'Built: %s\n' "$app"
