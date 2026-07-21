#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
bundle_path="$project_dir/dist/CodexBar.app"

"$project_dir/scripts/package-app.sh"

version=$(plutil -extract CFBundleShortVersionString raw "$bundle_path/Contents/Info.plist")
if [[ -z "$version" ]]; then
  print -u2 "Could not read CFBundleShortVersionString from $bundle_path"
  exit 1
fi

archive_path="$project_dir/dist/CodexBar-${version}-arm64.zip"
if [[ -e "$archive_path" ]]; then
  print -u2 "Release archive already exists: $archive_path"
  print -u2 "Bump the app version before creating a new release archive."
  exit 1
fi

ditto -c -k --sequesterRsrc --keepParent "$bundle_path" "$archive_path"
archive_sha=$(shasum -a 256 "$archive_path" | awk '{print $1}')

print "Created $archive_path"
print "SHA256: $archive_sha"
print "Upload this archive to the GitHub release tag v$version."
