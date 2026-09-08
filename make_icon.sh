#!/bin/zsh
set -eu
cd "${0:A:h}"
iconset="Codex Quota.iconset"
rm -rf "$iconset"
mkdir -p "$iconset"
# Render the vector through AppKit once, then let sips produce all iconset sizes
# with consistent filtering. AppKit keeps the alpha channel outside the tile.
rendered="/private/tmp/codex-quota-icon.png"
swiftc IconRenderer.swift -o /private/tmp/codex-quota-icon-renderer -framework AppKit -module-cache-path build-cache
/private/tmp/codex-quota-icon-renderer icon.svg "$rendered"
for spec in '16 1' '16 2' '32 1' '32 2' '64 1' '64 2' '128 1' '128 2' '256 1' '256 2' '512 1' '512 2'; do
  size=${spec%% *}; scale=${spec##* }
  pixels=$((size * scale))
  suffix=""
  [[ "$scale" == "2" ]] && suffix="@2x"
  sips -z "$pixels" "$pixels" "$rendered" --out "$iconset/icon_${size}x${size}${suffix}.png" >/dev/null
done
if iconutil -c icns "$iconset" -o 'Codex Quota.icns' 2>/dev/null; then
  echo "Created Codex Quota.icns, $iconset/ and AppIcon.png"
else
  # Some macOS SDK/toolchain combinations reject otherwise valid iconsets.
  # The app itself uses AppIcon.png and remains fully functional.
  echo "Created $iconset/ and AppIcon.png (icns conversion unavailable on this toolchain)"
fi
cp "$rendered" 'AppIcon.png'
