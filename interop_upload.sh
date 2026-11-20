#!/usr/bin/env bash
# 実際の Git（SHA-256 形式）との相互運用テスト（ADR 0048 第 2 段、Issue #11）。upload-pack（スマート HTTP v0、固定 ACL・HMAC Bearer）。
#  A. 空リポジトリの clone、最初の clone、新しいコミット後の増分 fetch（fsck --strict・log・diff で確認）
#  B. 注釈付きタグ（peeled）と軽量タグ、gc 済み（pack・delta）のリポジトリの clone
#  C. 既定の v2 要求から v0 への戻りと `-c protocol.version=0`
#  D. gzip 要求（実 Git が 1024 バイト超の要求で自動で付ける）の clone／fetch と、符号化の前後の大きさの記録、小さい identity 要求
#  E. 認証・認可（401／404）、未対応の機能（shallow・filter）の拒否、gzip の拒否の分類（400／413／415）
set -euo pipefail

: "${SIGIL:=sigil}"
: "${STAGE5_GIT:=git}"
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Git version: $("$STAGE5_GIT" --version)"
if [[ -n "${STAGE5_GIT_VERSION:-}" ]]; then
  test "$("$STAGE5_GIT" --version)" = "git version $STAGE5_GIT_VERSION"
fi
"$STAGE5_GIT" init --object-format=sha256 --bare -q "$(mktemp -d)" || { echo "this git does not support SHA-256" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }

mkdir -p tmp
W="$(mktemp -d tmp/interop_upload.XXXXXX)"
SERVER_PIDS=()
cleanup() {
  for p in "${SERVER_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  [ -n "${KEEP:-}" ] || rm -rf "$W"
}
trap cleanup EXIT
export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset GIT_PROTOCOL
G="$STAGE5_GIT"
t=1700000000
tick() { t=$((t + 60)); export GIT_AUTHOR_DATE="$t +0000" GIT_COMMITTER_DATE="$t +0000"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

$SIGIL build --root . upload_server.sigil main -o "$W/upload_server"

KEY=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
AUD=sigil-git
export SIGIL_AUTH_HMAC_KEY_HEX=$KEY SIGIL_AUTH_AUDIENCE=$AUD
cat >"$W/mint.py" <<'PY'
import sys, hmac, hashlib, base64, struct, time
key = bytes.fromhex(sys.argv[1]); aud = sys.argv[2].encode(); sub = sys.argv[3].encode()
now = int(time.time())
payload = struct.pack(">QQH", now - 5, now + 3000, len(aud)) + aud + struct.pack(">H", len(sub)) + sub
b = lambda x: base64.urlsafe_b64encode(x).rstrip(b"=")
head = b"sigil1." + b(payload)
print((head + b"." + b(hmac.new(key, head, hashlib.sha256).digest())).decode())
PY
TOKEN="$(python3 -I "$W/mint.py" $KEY $AUD alice)"
TOKEN_BOB="$(python3 -I "$W/mint.py" $KEY $AUD bob)"

# サーバー起動: start_server <log> → $PORT
start_server() {
  local log="$1"
  mkdir -p "$W/repos"
  SIGIL_GIT_REPO_ROOT="$PWD/$W/repos" SIGIL_GIT_ACL="demo:alice;empty:alice;packed:alice" SIGIL_GIT_SERVE_CONNS=200 SIGIL_GIT_LOG_REQUESTS=1 \
    "$W/upload_server" >"$log" 2>&1 &
  SERVER_PIDS+=("$!")
  local i
  for i in $(seq 1 50); do
    PORT="$(head -n 1 "$log" 2>/dev/null || true)"
    [[ "$PORT" =~ ^[0-9]+$ ]] && return 0
    sleep 0.1
  done
  fail "server did not start"
}
gc_() { "$G" -c http.extraHeader="Authorization: Bearer $TOKEN" "$@"; }
URL() { echo "http://127.0.0.1:$PORT/repos/$1"; }

# --- 準備: 作業リポジトリと公開側（bare）---
WORK="$W/work"
"$G" init -q --object-format=sha256 -b main "$WORK"
w() { "$G" -C "$WORK" "$@"; }
dm() { "$G" -C "$W/repos/demo.git" rev-parse main; }
printf 'one\n' >"$WORK/a.txt"; w add a.txt; tick; w commit -q -m c1
seq 1 400 >"$WORK/big.txt"; w add big.txt; tick; w commit -q -m c2
w tag light
tick; w tag -a -m annotated t1
w branch feature
for n in 1 2 3; do printf 'f%s\n' "$n" >>"$WORK/a.txt"; w add a.txt; tick; w commit -q -m "m$n"; done
mkdir -p "$W/repos"
"$G" init -q --object-format=sha256 --bare "$W/repos/empty.git"
"$G" init -q --object-format=sha256 --bare "$W/repos/demo.git"
w push -q "$PWD/$W/repos/demo.git" main feature light t1
"$G" -C "$W/repos/demo.git" symbolic-ref HEAD refs/heads/main
# gc 済み（pack・delta）
"$G" clone -q --bare "$W/repos/demo.git" "$W/repos/packed.git"
for n in 1 2 3 4 5 6; do printf 'x%s\n' "$n" >>"$WORK/big.txt"; w add big.txt; tick; w commit -q -m "d$n"; done
w push -q "$PWD/$W/repos/packed.git" main
"$G" -C "$W/repos/packed.git" -c gc.writeCommitGraph=false -c repack.writeBitmaps=false gc -q --aggressive
"$G" -C "$W/repos/packed.git" pack-refs --all
ls "$W/repos/packed.git/objects/pack"/*.pack >/dev/null

start_server "$W/server.log"
echo "server port $PORT"

# A. 空リポジトリ
gc_ clone -q "$(URL empty)" "$W/c_empty" 2>"$W/c_empty.err" || fail "empty clone"
grep -q "empty repository" "$W/c_empty.err" || fail "empty clone warning missing"
test "$("$G" -C "$W/c_empty" rev-parse --show-object-format)" = sha256
echo "OK empty clone"

# A. 最初の clone
gc_ clone -q "$(URL demo)" "$W/c1"
"$G" -C "$W/c1" fsck --strict >/dev/null 2>&1 || fail "fsck c1"
test "$("$G" -C "$W/c1" rev-parse HEAD)" = "$(dm)" || fail "HEAD c1"
test "$("$G" -C "$W/c1" rev-parse origin/feature)" = "$(w rev-parse feature)" || fail "feature"
test "$("$G" -C "$W/c1" log --format=%s | tr '\n' ' ')" = "m3 m2 m1 c2 c1 " || fail "log c1"
echo "OK first clone"

# B. タグ
test "$("$G" -C "$W/c1" rev-parse t1)" = "$(w rev-parse t1)" || fail "annotated tag object"
test "$("$G" -C "$W/c1" rev-parse 't1^{commit}')" = "$(w rev-parse 't1^{commit}')" || fail "peeled"
test "$("$G" -C "$W/c1" cat-file -t t1)" = tag || fail "t1 type"
test "$("$G" -C "$W/c1" cat-file -t light)" = commit || fail "light type"
echo "OK annotated and lightweight tags"

# A. 増分 fetch（新しいコミット）
printf 'new\n' >"$WORK/new.txt"; w add new.txt; tick; w commit -q -m c5
w push -q "$PWD/$W/repos/demo.git" main
gc_ -C "$W/c1" fetch -q origin
"$G" -C "$W/c1" fsck --strict >/dev/null 2>&1 || fail "fsck after fetch"
test "$("$G" -C "$W/c1" rev-parse origin/main)" = "$(dm)" || fail "fetch main"
stat="$("$G" -C "$W/c1" diff --stat HEAD origin/main)"
[[ "$stat" == *new.txt* ]] || fail "diff after fetch"
test "$("$G" -C "$W/c1" log -1 --format=%s origin/main)" = c5 || fail "log after fetch"
echo "OK incremental fetch"

# B. gc 済み
gc_ clone -q "$(URL packed)" "$W/c_packed"
"$G" -C "$W/c_packed" fsck --strict >/dev/null 2>&1 || fail "fsck packed"
test "$("$G" -C "$W/c_packed" rev-parse HEAD)" = "$("$G" -C "$W/repos/packed.git" rev-parse main)" || fail "packed HEAD"
"$G" -C "$W/c_packed" diff --quiet HEAD~3 HEAD && fail "packed diff should differ" || true
echo "OK packed (delta) repository clone"

# C. v2 から v0 への戻りと protocol.version=0
GIT_TRACE_PACKET="$PWD/$W/trace_v2.txt" gc_ -c protocol.version=2 clone -q "$(URL demo)" "$W/c_v2" 2>/dev/null
grep -q "version 2" "$W/trace_v2.txt" && fail "server must not answer v2" || true
test "$("$G" -C "$W/c_v2" rev-parse HEAD)" = "$(dm)" || fail "v2 fallback"
gc_ -c protocol.version=0 clone -q "$(URL demo)" "$W/c_v0"
test "$("$G" -C "$W/c_v0" rev-parse HEAD)" = "$(dm)" || fail "v0"
echo "OK default v2 request falls back to v0; protocol.version=0"

# D. gzip: 利用側に 16 個以上のコミットがあると、実 Git は最初の要求を gzip で送る
CL="$W/c_gz"
gc_ clone -q "$(URL demo)" "$CL"
cg() { "$G" -C "$CL" "$@"; }
for n in $(seq 1 30); do printf 'l%s\n' "$n" >>"$CL/a.txt"; cg add a.txt; tick; cg commit -q -m "local$n"; done
for n in 1 2; do printf 's%s\n' "$n" >>"$WORK/new.txt"; w add new.txt; tick; w commit -q -m "s$n"; done
w push -q "$PWD/$W/repos/demo.git" main
: >"$W/gz_before.log"; cp "$W/server.log" "$W/gz_before.log"
gc_ -C "$CL" fetch -q origin
cg fsck --strict >/dev/null 2>&1 || fail "fsck gzip fetch"
test "$(cg rev-parse origin/main)" = "$(dm)" || fail "gzip fetch"
diff <(cat "$W/gz_before.log") <(cat "$W/server.log") | grep '^>' | sed 's/^> //' >"$W/gz_new.log" || true
grep -q 'content-encoding=gzip' "$W/gz_new.log" || fail "no gzip request seen: $(cat "$W/gz_new.log")"
echo "OK gzip fetch; recorded sizes (encoded/decoded bytes):"
grep 'content-encoding=gzip' "$W/gz_new.log" | sed 's/^/  /'
# 小さい identity 要求（最初の clone）
grep -q 'content-encoding=identity' "$W/server.log" || fail "no identity request seen"
echo "OK small identity request recorded:"
grep 'content-encoding=identity' "$W/server.log" | head -n 1 | sed 's/^/  /'
# 実 Git の gzip で clone（多数の want）
gc_ clone -q "$(URL demo)" "$W/c_gz2"
"$G" -C "$W/c_gz2" fsck --strict >/dev/null 2>&1 || fail "fsck gz2"

# E. 認証・認可
code() { curl -s -o "$W/body.out" -w '%{http_code}' "$@"; }
B="http://127.0.0.1:$PORT/repos/demo"
test "$(code "$B/info/refs?service=git-upload-pack")" = 401 || fail "no token should be 401"
test "$(code -H "Authorization: Bearer ${TOKEN}x" "$B/info/refs?service=git-upload-pack")" = 401 || fail "bad token 401"
test "$(code -H "Authorization: Bearer $TOKEN_BOB" "$B/info/refs?service=git-upload-pack")" = 404 || fail "non-ACL subject 404"
test "$(code -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/repos/nosuch/info/refs?service=git-upload-pack")" = 404 || fail "unknown repo 404"
test "$(code -H "Authorization: Bearer $TOKEN" "$B/info/refs")" = 400 || fail "missing service 400"
test "$(code -H "Authorization: Bearer $TOKEN" "$B/info/refs?service=git-receive-pack")" = 400 || fail "receive-pack not served"
test "$(code -H "Authorization: Bearer $TOKEN" "$B/info/refs?service=git-upload-pack&x=1")" = 400 || fail "extra query"
test "$(code -H "Authorization: Bearer $TOKEN" "$B/info/refs?service=git-upload-pack&service=git-upload-pack")" = 400 || fail "dup service"
test "$(code -H "Authorization: Bearer $TOKEN" "$B/info/refs?service=git-upload-pack")" = 200 || fail "good adv"
echo "OK authn/authz and advertisement query checks"

# E. 未対応の機能の拒否（pack を返さない）
if gc_ clone -q --depth 1 "$(URL demo)" "$W/c_shallow" 2>/dev/null; then fail "shallow must be rejected"; fi
if gc_ clone -q --filter=blob:none "$(URL demo)" "$W/c_filter" 2>/dev/null; then fail "filter must be rejected"; fi
echo "OK shallow and filter rejected"

# E. gzip の拒否の分類（ADR 0052）
OID="$(dm)"
python3 -I - "$OID" "$W" <<'PY'
import sys, gzip, zlib, io, struct
oid, w = sys.argv[1], sys.argv[2]
def pkt(s): return b"%04x" % (len(s) + 4) + s
body = pkt(b"want %s side-band-64k\n" % oid.encode()) + b"0000" + pkt(b"done\n")
good = gzip.compress(body, mtime=0)
open(w + "/gz_good.bin", "wb").write(good)
open(w + "/gz_trunc.bin", "wb").write(good[:-5])
crc = bytearray(good); crc[-6] ^= 0xFF
open(w + "/gz_crc.bin", "wb").write(bytes(crc))
isz = bytearray(good); isz[-1] ^= 0xFF
open(w + "/gz_isize.bin", "wb").write(bytes(isz))
open(w + "/gz_trailing.bin", "wb").write(good + b"x")
open(w + "/gz_concat.bin", "wb").write(good + good)
open(w + "/gz_magic.bin", "wb").write(b"\x1f\x8c" + good[2:])
open(w + "/gz_plain.bin", "wb").write(body)
big = gzip.compress(b"0" * (1048576 + 1), mtime=0)
open(w + "/gz_over.bin", "wb").write(big)
PY
post() { # post <encoding|-> <file>
  local enc="$1" f="$2"; local args=(-H "Authorization: Bearer $TOKEN" -H "Content-Type: application/x-git-upload-pack-request" --data-binary "@$f")
  [ "$enc" = - ] || args+=(-H "Content-Encoding: $enc")
  code "${args[@]}" "$B/git-upload-pack"
}
test "$(post gzip "$W/gz_good.bin")" = 200 || fail "good gzip"
grep -aq PACK "$W/body.out" || fail "good gzip: no pack"
test "$(post - "$W/gz_plain.bin")" = 200 || fail "identity"
for c in gz_trunc gz_crc gz_isize gz_trailing gz_concat gz_magic; do
  test "$(post gzip "$W/$c.bin")" = 400 || fail "$c should be 400"
  grep -aq PACK "$W/body.out" && fail "$c returned a pack" || true
done
test "$(post gzip "$W/gz_over.bin")" = 413 || fail "gz_over should be 413"
test "$(post x-gzip "$W/gz_good.bin")" = 415 || fail "x-gzip 415"
test "$(post deflate "$W/gz_good.bin")" = 415 || fail "deflate 415"
test "$(post "gzip, gzip" "$W/gz_good.bin")" = 415 || fail "multiple encodings 415"
test "$(post "gzip, identity" "$W/gz_good.bin")" = 415 || fail "list encodings 415"
echo "OK gzip rejection classes (400/413/415)"
echo "interop_upload: ALL OK"
