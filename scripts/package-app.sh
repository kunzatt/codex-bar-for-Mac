#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
bundle_path="$project_dir/dist/CodexBar.app"

cd "$project_dir"
swift build -c release

mkdir -p "$bundle_path/Contents/MacOS" "$bundle_path/Contents/Resources"
cp Resources/Info.plist "$bundle_path/Contents/Info.plist"
cp Resources/CodexBar.icns "$bundle_path/Contents/Resources/CodexBar.icns"
plutil -replace CFBundleExecutable -string CodexBar "$bundle_path/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string com.local.CodexBar "$bundle_path/Contents/Info.plist"
plutil -replace CFBundleName -string CodexBar "$bundle_path/Contents/Info.plist"
plutil -replace CFBundleDevelopmentRegion -string en "$bundle_path/Contents/Info.plist"
cp .build/release/CodexBar "$bundle_path/Contents/MacOS/CodexBar"
chmod 755 "$bundle_path/Contents/MacOS/CodexBar"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$bundle_path"
fi

plutil -lint "$bundle_path/Contents/Info.plist"
printf 'Created %s\n' "$bundle_path"
