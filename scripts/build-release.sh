#!/usr/bin/env bash
#
# Build a universal binary (arm64 + x86_64) for GitHub Releases.
#
# Usage:
#   scripts/build-release.sh v0.3.2
#
# Artifacts go to release/<version>/. Other versions are kept: one of them may
# be the rollback copy of the installed binary.
#
# To cut a release:
#   scripts/build-release.sh v0.3.2
#   gh release create v0.3.2 release/v0.3.2/inverso-v0.3.2-universal.tar.gz release/v0.3.2/checksums.txt \
#     --title "Inverso v0.3.2" --notes "..."
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-dev}"
# The version names the directory replaced below, so it must never be a path.
case "$VERSION" in
  .*|*[!A-Za-z0-9._-]*)
    echo "error: version must be a plain name such as v0.3.2: $VERSION" >&2
    exit 2
    ;;
esac
NAME="inverso"
DEPLOY="13.0"
OUT="release/$VERSION"

build_arch() {
  local arch="$1"
  local scratch=".build-$arch"
  local triple="$arch-apple-macosx$DEPLOY"
  rm -rf "$scratch"
  swift build -c release --scratch-path "$scratch" --triple "$triple" >/dev/null
  swift build -c release --scratch-path "$scratch" --triple "$triple" --show-bin-path
}

echo "Building arm64 ..."
ARM64_DIR="$(build_arch arm64)" || exit 1
echo "Building x86_64 ..."
X86_DIR="$(build_arch x86_64)" || exit 1

rm -rf "$OUT"
mkdir -p "$OUT"
echo "Merging universal binary ..."
lipo -create -output "$OUT/$NAME" "$ARM64_DIR/$NAME" "$X86_DIR/$NAME"
codesign --force --sign - "$OUT/$NAME"

echo "Architectures: $(lipo -archs "$OUT/$NAME")"
TARBALL="$NAME-$VERSION-universal.tar.gz"
tar -czf "$OUT/$TARBALL" -C "$OUT" "$NAME"
( cd "$OUT" && shasum -a 256 "$NAME" "$TARBALL" > checksums.txt )

echo "Done. Artifacts in $OUT/:"
ls -1 "$OUT"
echo ""
echo "Checksums:"
cat "$OUT/checksums.txt"
