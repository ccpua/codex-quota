#!/bin/zsh
set -euo pipefail

cd "${0:A:h}"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 "Invalid app version: $version"
  exit 1
fi

zsh build.sh
mkdir -p dist
stage_dir=$(mktemp -d /private/tmp/codex-quota-dmg.XXXXXX)
trap 'rm -rf "$stage_dir"' EXIT
ditto 'Codex Quota.app' "$stage_dir/Codex Quota.app"
ln -s /Applications "$stage_dir/Applications"
output="dist/Codex-Quota-${version}-arm64.dmg"
hdiutil create -volname 'Codex Quota' -srcfolder "$stage_dir" -ov -format UDZO "$output"
hdiutil verify "$output"
shasum -a 256 "$output"
