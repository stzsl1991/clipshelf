#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source_app="$PWD/build/拾贴.app"
destination="/Applications/拾贴.app"
if [[ ! -w /Applications ]]; then destination="$HOME/Applications/拾贴.app"; mkdir -p "$HOME/Applications"; fi
if [[ -e "$destination" ]]; then
  bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")
  if [[ "$bundle_id" != com.shulin.ClipShelf ]]; then
    printf 'Refusing to replace an unrelated app: %s\n' "$destination" >&2; exit 1
  fi
  if pgrep -x ClipShelf >/dev/null; then
    printf 'Quit 拾贴 before replacing the installed app.\n' >&2; exit 1
  fi
fi
codesign --verify --strict "$source_app"
ditto "$source_app" "$destination"
codesign --verify --strict "$destination"
printf 'Installed: %s\n' "$destination"
