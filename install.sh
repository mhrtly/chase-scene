#!/bin/bash
# Benny Hill Climber installer — downloads the latest release and puts it in your Applications folder.
#
#   curl -fsSL https://raw.githubusercontent.com/mhrtly/chase-scene/main/install.sh | bash
#
# Read it first if you like; it's short. Nothing here needs sudo.
set -euo pipefail

repo="mhrtly/chase-scene"
app_name="Benny Hill Climber.app"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Benny Hill Climber is a Mac app (macOS 13 Ventura or later)." >&2
  exit 1
fi
if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 13 ]; then
  echo "Benny Hill Climber needs macOS 13 Ventura or later." >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "🎷 Downloading Benny Hill Climber…"
curl -fsSL "https://github.com/$repo/releases/latest/download/Benny-Hill-Climber.zip" -o "$tmp/Benny-Hill-Climber.zip"
ditto -x -k "$tmp/Benny-Hill-Climber.zip" "$tmp/unpacked"
codesign --verify --deep --strict "$tmp/unpacked/$app_name"

dest="/Applications"
if [ ! -w "$dest" ]; then
  dest="$HOME/Applications"
  mkdir -p "$dest"
fi

# Upgrading? Close the running copy first.
if pgrep -xq ChaseScene; then
  pkill -x ChaseScene >/dev/null 2>&1 || true
  sleep 1
fi

rm -rf "${dest:?}/$app_name"
mv "$tmp/unpacked/$app_name" "$dest/"

# Keep older direct hook/MCP paths working through the rename. Normal connections
# use the stable launcher in Application Support, which the new app refreshes.
legacy="$dest/Chase Scene.app"
if [ -e "$legacy" ]; then
  legacy_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$legacy/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$legacy_id" = "io.github.mhrtly.ChaseScene" ]; then
    mv "$legacy" "$tmp/previous-name.app"
    ln -s "$app_name" "$legacy"
    chflags -h hidden "$legacy"
  fi
fi
echo "✅ Installed $dest/$app_name"

open "$dest/$app_name"
echo "Look for the ♪ in your menu bar. Connect your AI tool there, then turn on Rolling credits if you like. 🥔"
