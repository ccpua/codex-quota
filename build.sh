#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p 'Codex Quota.app/Contents/MacOS' build-cache
swiftc main.swift Preferences.swift QuotaView.swift HoverSurface.swift HoverGeometry.swift Updater.swift Preview.swift -o 'Codex Quota.app/Contents/MacOS/CodexQuota' -framework AppKit -module-cache-path build-cache -O
if [[ -e 'Codex Quota.app/Contents/MacOS/CodexQuotaWatcher' ]]; then
  unlink 'Codex Quota.app/Contents/MacOS/CodexQuotaWatcher'
fi
mkdir -p 'Codex Quota.app/Contents/Resources'
swiftc IconRenderer.swift -o /private/tmp/codex-quota-icon-renderer -framework AppKit -module-cache-path build-cache -O
/private/tmp/codex-quota-icon-renderer icon.svg 'Codex Quota.app/Contents/Resources/AppIcon.png'
cp Info.plist 'Codex Quota.app/Contents/Info.plist'
codesign --force --sign - 'Codex Quota.app'
