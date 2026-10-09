#!/bin/bash
# Chase Scene installer — downloads the latest release and puts it in your Applications folder.
#
#   curl -fsSL https://raw.githubusercontent.com/mhrtly/chase-scene/main/install.sh | bash
#
# Read it first if you like; it's short. Nothing here needs sudo.
set -euo pipefail

repo="mhrtly/chase-scene"
app_name="Chase Scene.app"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Chase Scene is a Mac app (macOS 13 Ventura or later)." >&2
  exit 1
fi
if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 13 ]; then
  echo "Chase Scene needs macOS 13 Ventura or later." >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "🎷 Downloading Chase Scene…"
curl -fsSL "https://github.com/$repo/releases/latest/download/Chase-Scene.zip" -o "$tmp/Chase-Scene.zip"
ditto -x -k "$tmp/Chase-Scene.zip" "$tmp/unpacked"

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
echo "✅ Installed $dest/$app_name"

open "$dest/$app_name"
echo "Look for the ♪ in your menu bar. Connect your AI tool there, then turn on Rolling credits if you like. 🥔"
