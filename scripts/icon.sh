#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/icon-png build/AppIcon.iconset
xcrun swiftc scripts/Icon.swift -framework AppKit -o build/IconMaker
build/IconMaker "$PWD/build/icon-png"
for n in 16 32 128 256 512; do
  cp "build/icon-png/$n.png" "build/AppIcon.iconset/icon_${n}x${n}.png"
  doubled=$((n * 2))
  cp "build/icon-png/$doubled.png" "build/AppIcon.iconset/icon_${n}x${n}@2x.png"
done
iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
