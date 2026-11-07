#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
preview_app="$PWD/build/拾贴预览.app"
ditto "$PWD/build/拾贴.app" "$preview_app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.shulin.ClipShelf.Preview' "$preview_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName 拾贴预览' "$preview_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName 拾贴预览' "$preview_app/Contents/Info.plist"
scripts/signing.sh "$preview_app" com.shulin.ClipShelf.Preview
printf 'Preview: %s\n' "$preview_app"
