#!/usr/bin/env bash
# Offline installer regression tests. No downloaded content is executed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_INSTALL_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/inverso-install-test.XXXXXX")"
TEST_INSTALL_ROOT="$(cd "$TEST_INSTALL_ROOT" && pwd -P)"
export TEST_INSTALL_ROOT
trap '/bin/chmod -R u+w "$TEST_INSTALL_ROOT"; /bin/rm -rf "$TEST_INSTALL_ROOT"' EXIT
mkdir -p "$TEST_INSTALL_ROOT/mock-bin" "$TEST_INSTALL_ROOT/archive" "$TEST_INSTALL_ROOT/tmp"

# A payload that must only be copied, never launched by the installer.
printf '#!/bin/sh\necho "installer must not execute this file" >&2\nexit 97\n' > "$TEST_INSTALL_ROOT/archive/inverso"
tar -czf "$TEST_INSTALL_ROOT/inverso-v-test-universal.tar.gz" -C "$TEST_INSTALL_ROOT/archive" inverso
TEST_INSTALL_HASH="$(shasum -a 256 "$TEST_INSTALL_ROOT/inverso-v-test-universal.tar.gz" | awk '{ print $1 }')"
export TEST_INSTALL_HASH

cat > "$TEST_INSTALL_ROOT/mock-bin/uname" <<'MOCK'
#!/bin/bash
printf '%s\n' "${TEST_INSTALL_OS:-Darwin}"
MOCK
cat > "$TEST_INSTALL_ROOT/mock-bin/sw_vers" <<'MOCK'
#!/bin/bash
printf '%s\n' "${TEST_INSTALL_VERSION:-13.0}"
MOCK
cat > "$TEST_INSTALL_ROOT/mock-bin/curl" <<'MOCK'
#!/bin/bash
set -eu
printf '%s\n' "$*" >> "$TEST_INSTALL_CASE/network.log"
case "$2" in
  https://api.github.com/repos/*/releases/latest)
    if [ "$TEST_INSTALL_MODE" = no-tag ]; then
      printf '{"message":"No releases"}\n'
    else
      printf '{"id":123,"tag_name":"v-test","name":"Test release"}\n'
    fi
    ;;
  https://github.com/*/releases/download/v-test/inverso-v-test-universal.tar.gz)
    /bin/cp "$TEST_INSTALL_ROOT/inverso-v-test-universal.tar.gz" "$4"
    ;;
  https://github.com/*/releases/download/v-test/checksums.txt)
    case "$TEST_INSTALL_MODE" in
      missing-checksum) printf '%s  unrelated.tar.gz\n' "$TEST_INSTALL_HASH" > "$4" ;;
      wrong-checksum) printf '%064d  inverso-v-test-universal.tar.gz\n' 0 > "$4" ;;
      *) printf '%s  inverso-v-test-universal.tar.gz\n' "$TEST_INSTALL_HASH" > "$4" ;;
    esac
    ;;
  *) echo "unexpected download URL: $2" >&2; exit 90 ;;
esac
MOCK
cat > "$TEST_INSTALL_ROOT/mock-bin/sudo" <<'MOCK'
#!/bin/bash
set -eu
printf '%s\n' "$*" >> "$TEST_INSTALL_CASE/sudo.log"
# No real sudo is called; restrict all writes to this test's temporary tree.
if [ "$1" != mv ] || [[ "$2" != "$TEST_INSTALL_ROOT/"* ]] || [[ "$3" != "$TEST_INSTALL_ROOT/"* ]]; then
  echo "unexpected sudo invocation: $*" >&2
  exit 91
fi
/bin/chmod u+w "$TEST_INSTALL_CASE/bin"
/bin/mv "$2" "$3"
MOCK
cat > "$TEST_INSTALL_ROOT/mock-bin/xattr" <<'MOCK'
#!/bin/bash
exit 0
MOCK
chmod +x "$TEST_INSTALL_ROOT/mock-bin/"*
export PATH="$TEST_INSTALL_ROOT/mock-bin:$PATH"
export TMPDIR="$TEST_INSTALL_ROOT/tmp"

fail() {
  echo "FAIL: $1" >&2
  if [ -f "$TEST_INSTALL_CASE/output" ]; then cat "$TEST_INSTALL_CASE/output" >&2; fi
  exit 1
}

prepare_case() {
  TEST_INSTALL_CASE="$TEST_INSTALL_ROOT/$1"
  TEST_INSTALL_MODE="$1"
  TEST_INSTALL_VERSION=13.0
  TEST_INSTALL_OS=Darwin
  export TEST_INSTALL_CASE TEST_INSTALL_MODE TEST_INSTALL_VERSION TEST_INSTALL_OS
  mkdir -p "$TEST_INSTALL_CASE/bin"
}

run_installer() {
  local status=0
  INVERSO_BINDIR="$TEST_INSTALL_CASE/bin" /bin/bash "$SCRIPT_DIR/install.sh" > "$TEST_INSTALL_CASE/output" 2>&1 || status=$?
  if [ "$1" = success ]; then
    [ "$status" -eq 0 ] || fail "expected successful installation"
  else
    [ "$status" -ne 0 ] || fail "expected installation to fail"
    if grep -Fq 'Installed:' "$TEST_INSTALL_CASE/output"; then fail "failure reported success"; fi
  fi
  grep -Fq "$2" "$TEST_INSTALL_CASE/output" || fail "missing diagnostic: $2"
}

prepare_case normal
run_installer success 'Installed:'
cmp "$TEST_INSTALL_ROOT/archive/inverso" "$TEST_INSTALL_CASE/bin/inverso" || fail "wrong installed payload"
[ -x "$TEST_INSTALL_CASE/bin/inverso" ] || fail "installed payload is not executable"

prepare_case missing-checksum
run_installer failure 'error: no checksum entry for inverso-v-test-universal.tar.gz.'
[ ! -e "$TEST_INSTALL_CASE/bin/inverso" ] || fail "installed an unverified payload"

prepare_case wrong-checksum
printf 'previous installation\n' > "$TEST_INSTALL_CASE/bin/inverso"
run_installer failure 'error: checksum mismatch.'
grep -Fxq 'previous installation' "$TEST_INSTALL_CASE/bin/inverso" || fail "damaged previous installation"

prepare_case no-tag
run_installer failure 'error: no published release found'
[ ! -e "$TEST_INSTALL_CASE/bin/inverso" ] || fail "installed without a release tag"
[ "$(wc -l < "$TEST_INSTALL_CASE/network.log" | tr -d ' ')" = 1 ] || fail "downloaded assets without a tag"

prepare_case destination-directory
mkdir "$TEST_INSTALL_CASE/bin/inverso"
run_installer failure 'error: install destination is a directory:'
[ ! -e "$TEST_INSTALL_CASE/bin/inverso/inverso" ] || fail "nested payload inside destination directory"
[ ! -e "$TEST_INSTALL_CASE/network.log" ] || fail "downloaded before validating destination"

prepare_case old-macos
TEST_INSTALL_VERSION=12.7.6
run_installer failure 'error: Inverso requires macOS 13 or later (found 12.7.6).'
[ ! -e "$TEST_INSTALL_CASE/network.log" ] || fail "downloaded for an unsupported system"

prepare_case non-macos
TEST_INSTALL_OS=Linux
run_installer failure 'error: Inverso only supports macOS.'
[ ! -e "$TEST_INSTALL_CASE/network.log" ] || fail "downloaded on an unsupported OS"

prepare_case sudo-install
chmod a-w "$TEST_INSTALL_CASE/bin"
if [ -w "$TEST_INSTALL_CASE/bin" ]; then
  fail "run this test as an unprivileged user to exercise the mocked sudo path"
fi
run_installer success 'Installed:'
grep -Fq 'mv ' "$TEST_INSTALL_CASE/sudo.log" || fail "did not exercise sudo installation"
cmp "$TEST_INSTALL_ROOT/archive/inverso" "$TEST_INSTALL_CASE/bin/inverso" || fail "wrong payload after mocked sudo"

echo 'Passed 8 offline installer scenarios.'
