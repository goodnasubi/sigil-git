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
$SIGIL fmt --check git/*.sigil tests/*.sigil test_runner.sigil interop_make.sigil interop_delete.sigil interop_read.sigil interop_ops.sigil interop_history.sigil interop_transfer.sigil upload_server.sigil mutation_runner.sigil perf_runner.sigil

echo "=== 2. Type checking (sigil check) ==="
$SIGIL check --root . test_runner.sigil
$SIGIL check --root . interop_make.sigil
$SIGIL check --root . interop_delete.sigil
$SIGIL check --root . interop_read.sigil
$SIGIL check --root . interop_ops.sigil
$SIGIL check --root . interop_history.sigil
$SIGIL check --root . interop_transfer.sigil
$SIGIL check --root . upload_server.sigil
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
SIGIL="$SIGIL" STAGE5_GIT="${STAGE5_GIT:-git}" STAGE5_GIT_VERSION="${STAGE5_GIT_VERSION:-}" ./interop_transfer.sh
SIGIL="$SIGIL" STAGE5_GIT="${STAGE5_GIT:-git}" STAGE5_GIT_VERSION="${STAGE5_GIT_VERSION:-}" ./interop_upload.sh
SIGIL="$SIGIL" STAGE5_GIT="${STAGE5_GIT:-git}" STAGE5_GIT_VERSION="${STAGE5_GIT_VERSION:-}" ./interop_receive.sh
SIGIL="$SIGIL" STAGE5_GIT="${STAGE5_GIT:-git}" STAGE5_GIT_VERSION="${STAGE5_GIT_VERSION:-}" ./interop_meta.sh
SIGIL="$SIGIL" STAGE5_GIT="${STAGE5_GIT:-git}" STAGE5_GIT_VERSION="${STAGE5_GIT_VERSION:-}" bash tests/fault_interop.sh
# Issue #634: ステップ単位の強制終了・電源断の模擬、カーネル障害注入（Linux x86_64 の ptrace。他の環境では明示的に失敗する）
# tmpfs の本物の ENOSPC には root か sudo -n が要る。権限が無い手元の環境では、警告を出してその部分だけを省く。
# CI（CI が設定されている環境）では省かず、権限が無ければ失敗させる。
if [ "$(id -u)" != 0 ] && ! sudo -n true 2>/dev/null && [ -z "${CI:-}" ]; then
  echo "警告: root でも sudo -n でも無いため、tmpfs の本物の ENOSPC の試験を省きます（FAULT_ALLOW_NO_MOUNT=1）" >&2
  export FAULT_ALLOW_NO_MOUNT=1
fi
bash tests/fault_selftest.sh
SIGIL="$SIGIL" STAGE5_GIT="${STAGE5_GIT:-git}" bash tests/fault_crash.sh
SIGIL="$SIGIL" STAGE5_GIT="${STAGE5_GIT:-git}" bash tests/fault_kernel.sh
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

echo "=== 6b. Transfer codec and wire pack: SIR evaluator vs Native binary (ADR 0048) ==="
EXPECTED_XFER_DIGEST="3fde4e5e7373be2532669ea69809c0da971f72d25ca5e95bdfe7da409a893485"
SIR_XFER="$($SIGIL run --root . tests/test_xcheck_transfer.sigil compute_transfer_digest | tail -n 1 | tr -d '"')"
XFER_BIN="$(mktemp -t sigil_git_xfer_XXXXXX)"
trap 'rm -f "$XFER_BIN"' EXIT
$SIGIL build --root . tests/test_xcheck_transfer.sigil compute_transfer_digest -o "$XFER_BIN"
NATIVE_XFER="$("$XFER_BIN" | tail -n 1 | tr -d '"')"
rm -f "$XFER_BIN"
trap - EXIT
echo "SIR evaluator transfer digest: $SIR_XFER"
echo "Native binary transfer digest: $NATIVE_XFER"
echo "Pinned expected digest:        $EXPECTED_XFER_DIGEST"
if [ "$SIR_XFER" != "$NATIVE_XFER" ] || [ "$SIR_XFER" != "$EXPECTED_XFER_DIGEST" ]; then
  echo "Error: transfer digest mismatch between SIR evaluator, Native binary, and Pinned digest" >&2
  exit 1
fi
echo "Transfer execution path equivalence verified!"

echo "=== 7. Mutation testing suite ==="
if command -v python3 >/dev/null 2>&1; then
  SIGIL="$SIGIL" bash tests/mutation/run.sh
else
  echo "python3 not found; skipping mutation suite in this environment"
fi

echo "=== All tests passed successfully! ==="
