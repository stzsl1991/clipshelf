#!/bin/zsh
# Package an existing verified build; never collect data from the installed app.
set -euo pipefail
cd "${0:A:h:h}"
app="$PWD/build/拾贴.app"
if [[ ! -d "$app" ]]; then printf 'Run scripts/build.sh first.\n' >&2; exit 1; fi
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
expected=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
if [[ "$version" != "$expected" ]]; then printf 'Build version does not match source. Rebuild first.\n' >&2; exit 1; fi
if [[ "$(lipo -archs "$app/Contents/MacOS/ClipShelf")" != arm64 ]]; then printf 'Expected an arm64 build.\n' >&2; exit 1; fi
codesign --verify --strict "$app"
source_commit=$(git rev-parse HEAD)
output="$PWD/build/releases/v$version"
mkdir -p "$output"
temporary=$(mktemp -d "$PWD/build/package-XXXXXX")
mounted=0
cleanup() {
  if (( mounted )); then hdiutil detach "$temporary/mount" -quiet || true; fi
  rm -rf "$temporary"
}
trap cleanup EXIT
mkdir -p "$temporary/payload" "$temporary/mount"
ditto "$app" "$temporary/payload/拾贴.app"
ln -s /Applications "$temporary/payload/Applications"
python3 - "$temporary/payload" "$version" "$source_commit" <<'PY'
import hashlib, json, pathlib, sys
root, version, commit = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
app = root / '拾贴.app'
allowed = {'Contents/Info.plist', 'Contents/MacOS/ClipShelf',
           'Contents/Resources/AppIcon.icns', 'Contents/_CodeSignature/CodeResources'}
files = {str(p.relative_to(app)) for p in app.rglob('*') if p.is_file()}
assert files == allowed, 'Unexpected app bundle files; review before distribution'
metadata = {'application': '拾贴 / ClipShelf', 'version': version,
            'architecture': 'arm64', 'minimum_macos': '13.0', 'source_commit': commit,
            'apple_notarized': False,
            'executable_sha256': hashlib.sha256((app/'Contents/MacOS/ClipShelf').read_bytes()).hexdigest()}
(root/'version-info.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
(root/'安装说明.txt').write_text('''拾贴 · ClipShelf

安装
1. 将「拾贴.app」拖到旁边的「Applications」文件夹。
2. 更新前请先退出正在运行的拾贴。
3. 从「应用程序」打开拾贴。

使用
⌘C 正常复制并自动记录；⌘V 直接粘贴当前剪贴板。
首次默认 ⌃⌥V 打开底部卡片，可在设置中修改。
左右滑动浏览，单击选择，双击或回车粘贴，空格查看全文。
管理历史、暂停和设置位于菜单栏右键菜单。

系统权限
自动粘贴需要在「系统设置 → 隐私与安全性 → 辅助功能」允许拾贴。
首次读取历史可能出现钥匙串确认，请在系统弹窗内完成。

构建说明
适用于 Apple Silicon（M1/M2/M3/M4 及后续 arm64 芯片），macOS 13 或以上。
本包为项目本地签名，未经 Apple Developer ID 签名或 Apple 公证。
首次打开时，macOS 可能要求在「隐私与安全性」确认打开。
请通过系统提供的界面完成确认，无需关闭系统安全保护。

下载与源码
https://github.com/stzsl1991/clipshelf
源码仓库与安装包已公开，可直接访问和下载。
''', encoding='utf-8')
PY
dmg="$output/ClipShelf-$version-macOS-arm64.dmg"
hdiutil create -quiet -volname "拾贴 $version" -srcfolder "$temporary/payload" -format UDZO -fs HFS+ -ov "$dmg"
hdiutil verify -quiet "$dmg"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$temporary/mount" "$dmg"
mounted=1
codesign --verify --strict "$temporary/mount/拾贴.app"
cmp "$app/Contents/MacOS/ClipShelf" "$temporary/mount/拾贴.app/Contents/MacOS/ClipShelf"
cmp "$app/Contents/Info.plist" "$temporary/mount/拾贴.app/Contents/Info.plist"
if [[ "$(readlink "$temporary/mount/Applications")" != /Applications ]]; then printf 'Invalid Applications shortcut.\n' >&2; exit 1; fi
cmp "$temporary/payload/version-info.json" "$temporary/mount/version-info.json"
hdiutil detach -quiet "$temporary/mount"
mounted=0
(cd "$output" && shasum -a 256 "${dmg:t}" > SHA256SUMS.txt)
printf 'Verified installer: %s\n' "$dmg"
printf 'Checksum file: %s/SHA256SUMS.txt\n' "$output"
