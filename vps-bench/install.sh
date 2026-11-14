#!/bin/sh
# install.sh — install the bundled single-file blackhole-vps-bench
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/victoryvpsvn-star/blackhole-discord-terminal/main/vps-bench/install.sh | sh
# or: ./install.sh [prefix]
set -eu

REPO="victoryvpsvn-star/blackhole-discord-terminal"
BRANCH="${BH_BRANCH:-main}"
PREFIX="${1:-${BH_PREFIX:-/usr/local}}"
DEST="$PREFIX/bin/blackhole-vps-bench"
URL="https://raw.githubusercontent.com/$REPO/$BRANCH/vps-bench/dist/blackhole-vps-bench"

mkdir -p "$PREFIX/bin"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$URL" -o "$DEST"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$DEST" "$URL"
else
  echo "ERROR: need curl or wget" >&2
  exit 1
fi
chmod +x "$DEST"

echo "installed: $DEST"
"$DEST" --version
echo
echo "quick start:"
echo "  $DEST detect                 # KVM? Docker? OpenVZ? LXC? Xen? bare metal?"
echo "  $DEST all --fast             # detect + benchmark nhanh"
echo "  $DEST all --webhook 'https://discord.com/api/webhooks/ID/TOKEN'  # bench + gui Discord"
