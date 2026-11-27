#!/usr/bin/env bash
# Runs the tests with code coverage and writes coverage.lcov (for Codecov).
#
#   scripts/coverage.sh
#
# Covers the StorageCore logic. The SwiftUI app target isn't compiled into the tests,
# so it isn't part of the numbers.
set -euo pipefail
cd "$(dirname "$0")/.."

swift test --enable-code-coverage

PROFDATA="$(dirname "$(swift test --show-codecov-path)")/default.profdata"
BIN_DIR="$(swift build --show-bin-path)"
XCTEST="$(find "$BIN_DIR" -maxdepth 1 -name '*.xctest' | head -1)"
EXE="$XCTEST/Contents/MacOS/$(basename "$XCTEST" .xctest)"

xcrun llvm-cov export -format=lcov \
    -instr-profile "$PROFDATA" "$EXE" \
    -ignore-filename-regex='(\.build|Tests)/' > coverage.lcov

# Make paths repo-relative so Codecov can match them to the source files.
sed -i '' "s|^SF:$(pwd)/|SF:|" coverage.lcov

awk -F: '/^LF:/{t+=$2} /^LH:/{h+=$2} END { printf "Line coverage: %.1f%% (%d of %d lines)\n", 100*h/t, h, t }' coverage.lcov
