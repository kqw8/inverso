#!/usr/bin/env bash
# Compile the production transform with optimization. No event posting.
set -euo pipefail
if [ "$#" -ne 0 ]; then
  echo 'Usage: bash scripts/benchmark.sh' >&2
  exit 2
fi
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCHMARK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/inverso-benchmark.XXXXXX")"
trap '/bin/rm -rf "$BENCHMARK_DIR"' EXIT

BENCHMARK_HARDWARE="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || printf 'CPU model unavailable')"
echo "Hardware: $BENCHMARK_HARDWARE ($(uname -m))"
echo "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
xcrun swiftc --version
xcrun swiftc -O -whole-module-optimization -swift-version 5 \
  -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$BENCHMARK_DIR/module-cache" \
  "$SCRIPT_DIR/../Sources/InversoKit/ScrollTransform.swift" \
  "$SCRIPT_DIR/benchmark.swift" -o "$BENCHMARK_DIR/benchmark"
"$BENCHMARK_DIR/benchmark"
