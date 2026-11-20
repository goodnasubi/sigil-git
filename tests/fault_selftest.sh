#!/usr/bin/env bash
# 障害注入器 tests/faultinject.c 自身の試験（Issue #634 のレビュー指摘の再発防止）。
# 注入器が間違うと、電源断の模擬と強制終了の試験が「通ってしまう」ので、小さな既知のプログラム（python3）で挙動を確かめる。
#   A. fsync の直前で止めたら、そのファイルは未同期のまま。直後で止めたら同期済み（出口で、成功したときだけ記録する）
#   B. fsync を EIO で失敗させたら、未同期のまま
#   C. O_CREAT だけでは既存ファイルを 0 バイトの扱いにしない（既存の長さを保つ）。O_TRUNC なら 0
#   D. 終了したプロセスのスロットを再利用し、累計 64 を超えるプロセスを起こしても追跡を続ける
#   E. writev・openat2・chmod 系もステップとして数える。/dev/null への書き込みは数えない
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/fault_lib.sh"
FL_SELFTEST=1
fl_selftest_init() {
  [ "$(uname -s)" = "Linux" ] && [ "$(uname -m)" = "x86_64" ] || fl_die "この試験は Linux x86_64 専用です（ptrace を使う）"
  command -v gcc >/dev/null 2>&1 || fl_die "gcc がありません"
  command -v python3 >/dev/null 2>&1 || fl_die "python3 がありません"
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  FW="${FAULT_WORK:-$ROOT/tmp/fault_work_selftest}"
  rm -rf "$FW"; mkdir -p "$FW"
  [ -n "${KEEP:-}" ] || trap 'rm -rf "$FW"' EXIT
  gcc -O2 -Wall -Wextra -o "$FW/faultinject" "$ROOT/tests/faultinject.c" || fl_die "faultinject.c をビルドできません"
  FI="$FW/faultinject"
  "$FI" -m count -l "$FW/probe.log" -- true || fl_die "ptrace が使えません"
}
fl_selftest_init

ok() { echo "  合格: $*"; }
bad() { echo "FAIL [selftest]: $*" >&2; exit 1; }

# python の小さなプログラムを $1 に書く
PY="$FW/prog.py"
D="$FW/data"; mkdir -p "$D"

run_fi() { # run_fi LOG DUR [fi options...] -- args
  local log="$1" dur="$2"; shift 2
  local rc=0
  "$FI" -l "$log" -d "$dur" "$@" || rc=$?
  return 0
}
step_of() { # step_of LOG NAME PATH-SUBSTRING -> ステップ番号
  awk -F'\t' -v n="$2" -v p="$3" '$2==n && index($3,p)>0 {print $1; exit}' "$1"
}
dur_len() { # dur_len DUR PATH -> 同期済みの長さ（無ければ "none"）
  awk -F'\t' -v p="$2" '$2==p {print $1; found=1} END {if (!found) print "none"}' "$1"
}

# --- A. fsync の入口・出口 ---
cat >"$PY" <<'PYEOF'
import os, sys
p = sys.argv[1]
fd = os.open(p, os.O_CREAT | os.O_WRONLY | os.O_EXCL, 0o644)
os.write(fd, b"abc")
os.fsync(fd)
os.write(fd, b"def")
os.fsync(fd)
os.close(fd)
PYEOF
F="$D/a.txt"
"$FI" -l "$FW/a.log" -d "$FW/a.dur" -- python3 -B "$PY" "$F"
S1="$(step_of "$FW/a.log" fsync "$F")"
S2="$(awk -F'\t' -v p="$F" '$2=="fsync" && index($3,p)>0 {c++; if (c==2) {print $1; exit}}' "$FW/a.log")"
[ -n "$S1" ] && [ -n "$S2" ] || bad "A: fsync のステップが数えられない"
[ "$(dur_len "$FW/a.dur" "$F")" = none ] || bad "A: 最後まで実行したのに未同期と記録された"
rm -f "$F"
"$FI" -l /dev/null -d "$FW/a1.dur" -m kill-before -n "$S1" -- python3 -B "$PY" "$F" || true
[ "$(dur_len "$FW/a1.dur" "$F")" = 0 ] || bad "A: 最初の fsync の直前で止めたのに、同期済みと記録された（入口で解除している）: $(dur_len "$FW/a1.dur" "$F")"
rm -f "$F"
"$FI" -l /dev/null -d "$FW/a2.dur" -m kill-after -n "$S1" -- python3 -B "$PY" "$F" || true
[ "$(dur_len "$FW/a2.dur" "$F")" = none ] || bad "A: 最初の fsync の直後で止めたのに、未同期と記録された"
rm -f "$F"
"$FI" -l /dev/null -d "$FW/a3.dur" -m kill-before -n "$S2" -- python3 -B "$PY" "$F" || true
[ "$(dur_len "$FW/a3.dur" "$F")" = 3 ] || bad "A: 2 回目の fsync の直前では、同期済みの長さは 3 のはず: $(dur_len "$FW/a3.dur" "$F")"
ok "A: fsync は出口で成功したときだけ同期済みになる（直前 kill=未同期、直後 kill=同期済み）"

# --- B. fsync の失敗 ---
rm -f "$F"
cat >"$PY" <<'PYEOF'
import os, sys
p = sys.argv[1]
fd = os.open(p, os.O_CREAT | os.O_WRONLY | os.O_EXCL, 0o644)
os.write(fd, b"abc")
try:
    os.fsync(fd)
    print("fsync-ok")
except OSError as e:
    print("fsync-failed", e.errno)
os.close(fd)
PYEOF
"$FI" -l "$FW/b.log" -d /dev/null -- python3 -B "$PY" "$F" >/dev/null
rm -f "$F"
SB="$(step_of "$FW/b.log" fsync "$F")"
OUT="$("$FI" -l /dev/null -d "$FW/b.dur" -m error -n "$SB" -e EIO -- python3 -B "$PY" "$F")"
echo "$OUT" | grep -q 'fsync-failed 5' || bad "B: fsync に EIO が返らない: $OUT"
[ "$(dur_len "$FW/b.dur" "$F")" = 0 ] || bad "B: 失敗した fsync でデータが同期済みと記録された"
ok "B: 失敗した fsync ではデータは未同期のまま"

# --- C. O_CREAT だけの open は既存の長さを保つ。O_TRUNC なら 0 ---
cat >"$PY" <<'PYEOF'
import os, sys
p, mode = sys.argv[1], sys.argv[2]
flags = os.O_WRONLY | os.O_CREAT
if mode == "trunc":
    flags |= os.O_TRUNC
fd = os.open(p, flags, 0o644)
os.pwrite(fd, b"Z", 0)
os.close(fd)
PYEOF
printf 'keep' >"$F.c"
"$FI" -l /dev/null -d "$FW/c1.dur" -- python3 -B "$PY" "$F.c" nocreate
[ "$(dur_len "$FW/c1.dur" "$F.c")" = 4 ] || bad "C: O_CREAT だけで既存ファイル（4 byte）の同期済みの長さが変わった: $(dur_len "$FW/c1.dur" "$F.c")"
printf 'keep' >"$F.t"
"$FI" -l /dev/null -d "$FW/c2.dur" -- python3 -B "$PY" "$F.t" trunc
[ "$(dur_len "$FW/c2.dur" "$F.t")" = 0 ] || bad "C: O_TRUNC なのに同期済みの長さが 0 でない"
rm -f "$F.n"
"$FI" -l /dev/null -d "$FW/c3.dur" -- python3 -B "$PY" "$F.n" nocreate
[ "$(dur_len "$FW/c3.dur" "$F.n")" = 0 ] || bad "C: 新しく作ったファイルの同期済みの長さが 0 でない"
ok "C: 既存ファイルへの O_CREAT は長さを保ち、O_TRUNC と新規作成は 0"

# --- D. 終了したプロセスのスロットの再利用 ---
cat >"$PY" <<'PYEOF'
import os, subprocess, sys
for _ in range(100):
    subprocess.run(["true"], check=True)
code = "import os,sys; fd=os.open(sys.argv[1], os.O_CREAT|os.O_WRONLY|os.O_EXCL, 0o644); os.write(fd,b'x'); os.fsync(fd)"
subprocess.run([sys.executable, "-B", "-c", code, sys.argv[1]], check=True)
PYEOF
rm -f "$F.d"
"$FI" -l "$FW/d.log" -d /dev/null -- python3 -B "$PY" "$F.d"
grep -q "$(printf 'write\t')\|write" "$FW/d.log" && [ "$(awk -F'\t' -v p="$F.d" '$2=="write" && index($3,p)>0' "$FW/d.log" | wc -l)" = 1 ] || bad "D: 100 個のプロセスのあとに起こしたプロセスの write が数えられない"
[ "$(awk -F'\t' -v p="$F.d" '$2=="fsync" && index($3,p)>0' "$FW/d.log" | wc -l)" = 1 ] || bad "D: 100 個のプロセスのあとに起こしたプロセスの fsync が数えられない"
ok "D: 100 個のプロセスを起こしたあとでも、新しいプロセスの syscall を数える"

# --- E. writev・openat2・chmod 系・/dev/null ---
cat >"$PY" <<'PYEOF'
import ctypes, os, struct, sys
p = sys.argv[1]
fd = os.open(p, os.O_CREAT | os.O_WRONLY | os.O_EXCL, 0o644)
os.writev(fd, [b"a", b"b"])
os.close(fd)
os.chmod(p, 0o600)
null = os.open("/dev/null", os.O_WRONLY)
os.write(null, b"ignored")
os.close(null)
libc = ctypes.CDLL(None, use_errno=True)
how = struct.pack("QQQ", os.O_WRONLY | os.O_CREAT, 0o644, 0)
buf = ctypes.create_string_buffer(how, len(how))
r = libc.syscall(437, -100, (p + ".o2").encode(), buf, len(how))
if r >= 0:
    os.close(r)
PYEOF
rm -f "$F.e" "$F.e.o2"
"$FI" -l "$FW/e.log" -d "$FW/e.dur" -- python3 -B "$PY" "$F.e"
grep -q "writev" "$FW/e.log" || bad "E: writev が数えられない"
grep -q "fchmod" "$FW/e.log" || bad "E: chmod 系が数えられない"
if grep -q '/dev/null' "$FW/e.log"; then bad "E: /dev/null への書き込みが数えられた"; fi
if [ -e "$F.e.o2" ]; then
  grep -q "$F.e.o2" "$FW/e.log" || bad "E: openat2 が数えられない"
  ok "E: writev・chmod 系・openat2 を数え、/dev/null は数えない"
else
  ok "E: writev・chmod 系を数え、/dev/null は数えない（openat2 はこのカーネルでは使えず省略）"
fi

echo "=== 障害注入器の自己試験: 全ケース合格 ==="
