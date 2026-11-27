#!/bin/bash
# Installs the latest Doomore release into /Applications (or ~/Applications).
#   curl -fsSL https://raw.githubusercontent.com/AhmedNavaz/doomore/main/scripts/install.sh | bash
set -euo pipefail

REPO="AhmedNavaz/doomore"

[ "$(uname -s)" = "Darwin" ] || { echo "Doomore is a macOS app." >&2; exit 1; }
[ "$(uname -m)" = "arm64" ] || { echo "Doomore needs an Apple silicon Mac." >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Finding the latest release..."
url="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')"
[ -n "$url" ] || { echo "Could not find a download. See https://github.com/$REPO/releases" >&2; exit 1; }

echo "Downloading $url"
curl -fsSL "$url" -o "$tmp/app.zip"
mkdir "$tmp/out"
unzip -q "$tmp/app.zip" -d "$tmp/out"
app="$(find "$tmp/out" -maxdepth 2 -name '*.app' -type d | head -1)"
[ -n "$app" ] || { echo "No app found in the download." >&2; exit 1; }

dest="/Applications"
[ -w "$dest" ] || { dest="$HOME/Applications"; mkdir -p "$dest"; }
name="$(basename "$app")"

# Quit a running copy, then replace it.
pkill -x "${name%.app}" 2>/dev/null || true
rm -rf "$dest/$name"
mv "$app" "$dest/$name"
# The app is ad-hoc signed and not notarized; clear the download flag so it opens directly.
xattr -dr com.apple.quarantine "$dest/$name" 2>/dev/null || true

echo "Installed $dest/$name"
open "$dest/$name"
echo "Look for the Doomore icon in your menu bar and choose Start monitoring."
