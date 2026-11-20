#!/usr/bin/env bash
# 変異試験: 意図した誤りを個別に埋め、試験が落ちることを確かめる。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${SIGIL:?SIGIL=/path/to/sigil を指定してください}"
exec python3 "$SCRIPT_DIR/tests/mutation/mutations.py" "$SCRIPT_DIR" "$SIGIL" "$@"
