#!/bin/bash
# Builds "build/Chase Scene.app": a universal (Apple silicon + Intel), ad-hoc signed menu-bar app.
# Needs the Xcode command-line tools (xcode-select --install). Set ARCHS="arm64" for a faster local build.
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
app="$root/build/Chase Scene.app"
cache="$root/build/module-cache"
archs="${ARCHS:-arm64 x86_64}"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$cache"

slices=()
for arch in $archs; do
  out="$root/build/ChaseScene-$arch"
  swiftc -O -swift-version 5 -module-cache-path "$cache" -target "$arch-apple-macosx13.0" \
    -framework AppKit -framework AVFoundation -framework ServiceManagement -framework UniformTypeIdentifiers \
    "$root"/Sources/*.swift -o "$out"
  slices+=("$out")
done
lipo -create "${slices[@]}" -output "$app/Contents/MacOS/ChaseScene"

cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$root/Resources/Help.html" "$root/Resources/hot-potato-hustle.m4a" "$app/Contents/Resources/"

# App icon, generated from the 1024 px master.
iconset="$root/build/AppIcon.iconset"
rm -rf "$iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$root/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" "$root/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$app"
printf 'Built %s (%s)\n' "$app" "$archs"
