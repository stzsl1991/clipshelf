#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/module-cache
xcrun swiftc -target arm64-apple-macos13.0 -module-cache-path "$PWD/build/module-cache" \
 Sources/Model.swift Sources/Clipboard.swift Tests/main.swift \
 -framework AppKit -framework Carbon -framework ApplicationServices -framework CryptoKit -framework Security \
 -o build/ClipShelfTests
build/ClipShelfTests
