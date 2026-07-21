#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
if command -v xcodebuild >/dev/null 2>&1 && xcodebuild -version >/dev/null 2>&1; then
  xcodebuild \
    -project "$project_dir/CodexBar.xcodeproj" \
    -scheme CodexBar \
    -configuration Debug \
    -derivedDataPath /private/tmp/CodexBarDerivedData \
    CODE_SIGNING_ALLOWED=NO \
    build
else
  cd "$project_dir"
  swift build
fi
