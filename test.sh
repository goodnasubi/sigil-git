#!/usr/bin/env bash
set -euo pipefail

# Sigil binary resolution
if [ -z "${SIGIL:-}" ]; then
  if command -v sigil >/dev/null 2>&1; then
    SIGIL="sigil"
  elif [ -x "$HOME/bin/sigil" ]; then
    SIGIL="$HOME/bin/sigil"
  else
    echo "Error: sigil binary not found on PATH or in $HOME/bin. Set SIGIL=/path/to/sigil or install it to PATH." >&2
    exit 1
  fi
fi

echo "Using Sigil compiler: $SIGIL"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== 1. Checking format (sigil fmt --check) ==="
$SIGIL fmt --check git/*.sigil tests/*.sigil test_runner.sigil interop_make.sigil interop_delete.sigil interop_read.sigil

echo "=== 2. Type checking (sigil check) ==="
$SIGIL check --root . test_runner.sigil
$SIGIL check --root . interop_make.sigil
$SIGIL check --root . interop_delete.sigil
$SIGIL check --root . interop_read.sigil
for f in git/*.sigil tests/*.sigil; do
  $SIGIL check --root . "$f"
done

mkdir -p tmp
echo "=== 3. Running tests via SIR evaluator (sigil run) ==="
RUN_OUTPUT="$($SIGIL run --root . test_runner.sigil main)"
echo "$RUN_OUTPUT"
if [ "$(printf '%s\n' "$RUN_OUTPUT" | tail -n 1)" != "0" ]; then
  echo "Test failure in SIR evaluator: expected last line 0" >&2
  exit 1
fi
echo "SIR evaluator tests passed (result = 0)"

echo "=== 4. Building and running native binary (sigil build) ==="
TMP_BIN="$(mktemp -t sigil_git_test_XXXXXX)"
trap 'rm -f "$TMP_BIN"' EXIT
$SIGIL build --root . test_runner.sigil main -o "$TMP_BIN"
BUILD_OUTPUT="$("$TMP_BIN")"
echo "$BUILD_OUTPUT"
if [ "$(printf '%s\n' "$BUILD_OUTPUT" | tail -n 1)" != "0" ]; then
  echo "Test failure in native binary: expected last line 0" >&2
  exit 1
fi
rm -f "$TMP_BIN"
trap - EXIT
echo "Native binary tests passed (result = 0)"

echo "=== 5. Interop with real Git (SHA-256) ==="
SIGIL="$SIGIL" ./interop.sh
SIGIL="$SIGIL" ./interop_pack.sh

echo "=== All tests passed successfully! ==="
