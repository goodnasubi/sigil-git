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
$SIGIL fmt --check git/*.sigil tests/*.sigil test_runner.sigil interop_make.sigil interop_delete.sigil interop_read.sigil interop_ops.sigil interop_history.sigil mutation_runner.sigil perf_runner.sigil

echo "=== 2. Type checking (sigil check) ==="
$SIGIL check --root . test_runner.sigil
$SIGIL check --root . interop_make.sigil
$SIGIL check --root . interop_delete.sigil
$SIGIL check --root . interop_read.sigil
$SIGIL check --root . interop_ops.sigil
$SIGIL check --root . interop_history.sigil
$SIGIL check --root . mutation_runner.sigil
$SIGIL check --root . perf_runner.sigil
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
SIGIL="$SIGIL" STAGE5_GIT="${STAGE5_GIT:-git}" STAGE5_GIT_VERSION="${STAGE5_GIT_VERSION:-}" ./interop.sh
SIGIL="$SIGIL" STAGE5_GIT="${STAGE5_GIT:-git}" STAGE5_GIT_VERSION="${STAGE5_GIT_VERSION:-}" ./interop_pack.sh
SIGIL="$SIGIL" STAGE5_GIT="${STAGE5_GIT:-git}" STAGE5_GIT_VERSION="${STAGE5_GIT_VERSION:-}" ./interop_ops.sh
SIGIL="$SIGIL" STAGE5_GIT="${STAGE5_GIT:-git}" STAGE5_GIT_VERSION="${STAGE5_GIT_VERSION:-}" ./interop_history.sh
SIGIL="$SIGIL" STAGE5_GIT="${STAGE5_GIT:-git}" STAGE5_GIT_VERSION="${STAGE5_GIT_VERSION:-}" bash tests/fault_interop.sh
grep -E '^# [0-9a-f]{64}' fixtures/v1/manifest.txt | sed 's/^# //' | (cd fixtures/v1 && sha256sum -c - >/dev/null)
echo "Fixture v1 SHA-256 checksums verified!"

echo "=== 6. Execution path equivalence (SIR evaluator vs Native binary) ==="
EXPECTED_DIGEST="ebce0bdaaee7081c671596c80c526ab634eaacb2d0dcd4c1b5b0787a69f227f6"
SIR_DIGEST="$($SIGIL run --root . tests/test_xcheck.sigil compute_trace_digest | tail -n 1 | tr -d '"')"
XCHECK_BIN="$(mktemp -t sigil_git_xcheck_XXXXXX)"
trap 'rm -f "$XCHECK_BIN"' EXIT
$SIGIL build --root . tests/test_xcheck.sigil compute_trace_digest -o "$XCHECK_BIN"
NATIVE_DIGEST="$("$XCHECK_BIN" | tail -n 1 | tr -d '"')"
rm -f "$XCHECK_BIN"
trap - EXIT

echo "SIR evaluator trace digest: $SIR_DIGEST"
echo "Native binary trace digest: $NATIVE_DIGEST"
echo "Pinned expected digest:    $EXPECTED_DIGEST"
if [ "$SIR_DIGEST" != "$NATIVE_DIGEST" ] || [ "$SIR_DIGEST" != "$EXPECTED_DIGEST" ]; then
  echo "Error: trace digest mismatch between SIR evaluator, Native binary, and Pinned digest" >&2
  exit 1
fi
echo "Execution path equivalence verified!"

echo "=== 7. Mutation testing suite ==="
if command -v python3 >/dev/null 2>&1; then
  SIGIL="$SIGIL" bash tests/mutation/run.sh
else
  echo "python3 not found; skipping mutation suite in this environment"
fi

echo "=== All tests passed successfully! ==="
