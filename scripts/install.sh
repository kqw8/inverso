#!/usr/bin/env bash
#
# One-line install:
#
#   curl -fsSL https://raw.githubusercontent.com/kqw8/Inverso/main/scripts/install.sh | bash
#
# Downloads the latest universal binary from GitHub Releases, verifies its sha256,
# removes quarantine, and installs it to /usr/local/bin.
#
# Env vars:
#   INVERSO_REPO=owner/repo
#   INVERSO_BINDIR=/some/bin
#
set -euo pipefail

REPO="${INVERSO_REPO:-kqw8/Inverso}"
NAME="inverso"
BINDIR="${INVERSO_BINDIR:-/usr/local/bin}"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "error: Inverso only supports macOS." >&2
  exit 1
fi

MACOS_VERSION="$(sw_vers -productVersion)" || {
  echo "error: couldn't determine the macOS version." >&2
  exit 1
}
MACOS_MAJOR="${MACOS_VERSION%%.*}"
case "$MACOS_MAJOR" in
  ''|*[!0-9]*)
    echo "error: couldn't determine the macOS version: $MACOS_VERSION." >&2
    exit 1
    ;;
esac
if [ "$MACOS_MAJOR" -lt 13 ]; then
  echo "error: Inverso requires macOS 13 or later (found $MACOS_VERSION)." >&2
  exit 1
fi

if [ -d "$BINDIR/$NAME" ]; then
  echo "error: install destination is a directory: $BINDIR/$NAME." >&2
  exit 1
fi

echo "Looking up latest release ..."
API="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest")" || {
  echo "error: couldn't reach GitHub. Try again later or set INVERSO_REPO=owner/repo." >&2
  exit 1
}
TAG=""
if [[ "$API" =~ \"tag_name\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
  TAG="${BASH_REMATCH[1]}"
fi
if [ -z "${TAG:-}" ]; then
  echo "error: no published release found for $REPO." >&2
  exit 1
fi

TARBALL="$NAME-$TAG-universal.tar.gz"
BASE="https://github.com/$REPO/releases/download/$TAG"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/inverso-install.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading $TAG ..."
curl -fsSL "$BASE/$TARBALL" -o "$TMP/$TARBALL"
curl -fsSL "$BASE/checksums.txt" -o "$TMP/checksums.txt"

EXPECTED="$(awk -v name="$TARBALL" '$2 == name { print $1 }' "$TMP/checksums.txt")"
if [ -z "${EXPECTED:-}" ]; then
  echo "error: no checksum entry for $TARBALL." >&2
  exit 1
fi
ACTUAL="$(shasum -a 256 "$TMP/$TARBALL" | awk '{print $1}')"
if [ "$EXPECTED" != "$ACTUAL" ]; then
  echo "error: checksum mismatch." >&2
  exit 1
fi
echo "Checksum OK"

tar -xzf "$TMP/$TARBALL" -C "$TMP"
if [ ! -f "$TMP/$NAME" ] || [ -L "$TMP/$NAME" ]; then
  echo "error: release archive does not contain a regular $NAME binary." >&2
  exit 1
fi
chmod +x "$TMP/$NAME"
xattr -dr com.apple.quarantine "$TMP/$NAME" 2>/dev/null || true

echo "Installing to $BINDIR ..."
mkdir -p "$BINDIR" 2>/dev/null || sudo mkdir -p "$BINDIR"
if [ -d "$BINDIR/$NAME" ]; then
  echo "error: install destination is a directory: $BINDIR/$NAME." >&2
  exit 1
fi
if [ -w "$BINDIR" ]; then
  mv "$TMP/$NAME" "$BINDIR/$NAME"
else
  echo "sudo needed to write to $BINDIR"
  sudo mv "$TMP/$NAME" "$BINDIR/$NAME"
fi

echo ""
echo "Installed: $BINDIR/$NAME ($TAG)"
echo ""
echo "Next:"
echo "  $NAME install      # start background service and enable start-at-login"
echo "  $NAME status       # show service and permission state"
