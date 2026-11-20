#!/usr/bin/env bash
# 実際の Git（SHA-256 形式）との相互運用テスト（ADR 0048 第 3 段、Issue #13）。receive-pack（スマート HTTP v0、固定 ACL・HMAC Bearer）。
#  A. 空リポジトリへの初回 push、追加コミット（fast-forward）、新規ブランチ、軽量・注釈付きタグ、clone 後の push、`-c protocol.version=0`
#     （push のたびに公開側で fsck --strict・log・diff を確認）
#  B. 拒否（参照は不変）: 削除、タグの上書き、非 fast-forward、複数参照、SHA-1、未知の能力、thin pack、旧値の不一致（409）
#  C. 認証・認可（401／403／404）、ACL 変更との競合、gzip（415）、固定上限（本文 1 MiB、オブジェクト 4096）
set -euo pipefail

: "${SIGIL:=sigil}"
: "${STAGE5_GIT:=git}"
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Git version: $("$STAGE5_GIT" --version)"
if [[ -n "${STAGE5_GIT_VERSION:-}" ]]; then
  test "$("$STAGE5_GIT" --version)" = "git version $STAGE5_GIT_VERSION"
fi
"$STAGE5_GIT" init --object-format=sha256 --bare -q "$(mktemp -d)" || { echo "this git does not support SHA-256" >&2; exit 1; }

has_http() {
  local ep
  ep="$("$1" --exec-path 2>/dev/null)" || return 1
  [ -x "$ep/git-remote-http" ] && "$1" init --object-format=sha256 --bare -q "$(mktemp -d)" >/dev/null 2>&1
}
HTTP_GIT="$STAGE5_GIT"
if ! has_http "$HTTP_GIT"; then
  echo "note: $STAGE5_GIT has no git-remote-http; trying git from PATH"
  HTTP_GIT=git
  has_http "$HTTP_GIT" || { echo "no git with git-remote-http and SHA-256 support found" >&2; exit 1; }
fi
echo "Git for HTTP: $("$HTTP_GIT" --version)"
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }

mkdir -p tmp
W="$(mktemp -d tmp/interop_receive.XXXXXX)"
SERVER_PIDS=()
cleanup() {
  for p in "${SERVER_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  [ -n "${KEEP:-}" ] || rm -rf "$W"
}
trap cleanup EXIT
export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset GIT_PROTOCOL
G="$HTTP_GIT"
t=1700000000
tick() { t=$((t + 60)); export GIT_AUTHOR_DATE="$t +0000" GIT_COMMITTER_DATE="$t +0000"; }
fail() {
  echo "FAIL: $*" >&2
  for f in "$W"/*.err "$W"/server.log; do [ -f "$f" ] && { echo "--- $f" >&2; head -n 40 "$f" >&2; }; done
  exit 1
}

$SIGIL build --root . upload_server.sigil main -o "$W/server_bin"

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

mkdir -p "$W/repos"
ACLF="$W/acl.txt"
# rw: alice が読み書きできる／ro: alice は読むだけ／priv: bob だけが読み書き（alice には 404）
printf 'rw:alice=rw;lim:alice=rw;ro:alice;priv:bob=rw' >"$ACLF"
start_server() {
  local log="$1"
  SIGIL_GIT_REPO_ROOT="$PWD/$W/repos" SIGIL_GIT_ACL="" SIGIL_GIT_ACL_FILE="$PWD/$ACLF" SIGIL_GIT_SERVE_CONNS=400 \
    "$W/server_bin" >"$log" 2>&1 &
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
for r in rw lim ro priv; do "$G" init -q --object-format=sha256 --bare -b main "$W/repos/$r.git"; done
R="$W/repos/rw.git"
rr() { "$G" -C "$R" "$@"; }
start_server "$W/server.log"
echo "server port $PORT"

WORK="$W/work"
"$G" init -q --object-format=sha256 -b main "$WORK"
w() { "$G" -C "$WORK" "$@"; }
ref() { rr rev-parse --verify -q "$1" 2>/dev/null || echo none; }
check_repo() { rr fsck --strict >/dev/null 2>"$W/fsck.err" || fail "fsck --strict ($1)"; }

# A. 空リポジトリへの初回 push
printf 'one\n' >"$WORK/a.txt"; w add a.txt; tick; w commit -q -m c1
gc_ -C "$WORK" push -q "$(URL rw)" main 2>"$W/push1.err" || fail "first push"
test "$(ref main)" = "$(w rev-parse main)" || fail "first push ref"
check_repo first
test "$(rr log --format=%s | tr '\n' ' ')" = "c1 " || fail "log after first push"
echo "OK first push to an empty repository"

# A. 追加コミット（fast-forward）
printf 'two\n' >>"$WORK/a.txt"; w add a.txt; tick; w commit -q -m c2
gc_ -C "$WORK" push -q "$(URL rw)" main 2>"$W/push2.err" || fail "fast-forward push"
test "$(ref main)" = "$(w rev-parse main)" || fail "ff ref"
check_repo ff
stat="$(rr diff --stat HEAD~1 HEAD)"
[[ "$stat" == *a.txt* ]] || fail "diff after ff"
echo "OK fast-forward push"

# A. 新規ブランチ
w branch feature
printf 'f\n' >"$WORK/f.txt"; w add f.txt; tick; w commit -q -m f1
gc_ -C "$WORK" push -q "$(URL rw)" main 2>"$W/push3.err" || fail "push main"
w checkout -q -b topic main~1
printf 't\n' >"$WORK/t.txt"; w add t.txt; tick; w commit -q -m t1
gc_ -C "$WORK" push -q "$(URL rw)" topic 2>"$W/push4.err" || fail "new branch push"
test "$(ref topic)" = "$(w rev-parse topic)" || fail "new branch ref"
check_repo branch
w checkout -q main
echo "OK new branch push"

# A. タグ（軽量・注釈付き）
w tag light
tick; w tag -a -m annotated t1
gc_ -C "$WORK" push -q "$(URL rw)" light t1 2>"$W/push5.err" && fail "two refs in one push must be rejected" || true
test "$(ref refs/tags/light)" = none || fail "multi-ref push created a tag"
gc_ -C "$WORK" push -q "$(URL rw)" light 2>"$W/push6.err" || fail "lightweight tag push"
gc_ -C "$WORK" push -q "$(URL rw)" t1 2>"$W/push7.err" || fail "annotated tag push"
test "$(ref refs/tags/light)" = "$(w rev-parse light)" || fail "light tag ref"
test "$(rr cat-file -t t1)" = tag || fail "t1 is a tag object"
test "$(rr rev-parse 't1^{commit}')" = "$(w rev-parse 't1^{commit}')" || fail "t1 peeled"
check_repo tags
echo "OK lightweight and annotated tag pushes (and a two-ref push rejected whole)"

# A. clone 後の push と protocol.version=0
gc_ clone -q "$(URL rw)" "$W/c1" 2>"$W/clone.err" || fail "clone"
C1="$W/c1"
printf 'c1\n' >"$C1/cl.txt"; "$G" -C "$C1" add cl.txt; tick; "$G" -C "$C1" commit -q -m clone1
gc_ -C "$C1" push -q origin main 2>"$W/push8.err" || fail "push after re-clone"
test "$(ref main)" = "$("$G" -C "$C1" rev-parse main)" || fail "push after clone ref"
printf 'c2\n' >>"$C1/cl.txt"; "$G" -C "$C1" add cl.txt; tick; "$G" -C "$C1" commit -q -m clone2
gc_ -C "$C1" -c protocol.version=0 push -q origin main 2>"$W/push9.err" || fail "push with protocol.version=0"
test "$(ref main)" = "$("$G" -C "$C1" rev-parse main)" || fail "v0 push ref"
check_repo clone
test "$(rr log -1 --format=%s)" = clone2 || fail "log after v0 push"
echo "OK push after re-clone and protocol.version=0"

# B. 拒否（参照は不変）
BEFORE="$(rr for-each-ref --format='%(refname) %(objectname)')"
unchanged() { test "$(rr for-each-ref --format='%(refname) %(objectname)')" = "$BEFORE" || fail "refs changed after $1"; }
if gc_ -C "$C1" push -q origin :topic 2>"$W/del.err"; then fail "delete must be rejected"; fi
unchanged delete
w tag -f -m moved light >/dev/null 2>&1 || true
if gc_ -C "$WORK" push -q --force "$(URL rw)" refs/tags/light:refs/tags/light 2>"$W/tagover.err"; then fail "tag overwrite must be rejected"; fi
unchanged tag-overwrite
w checkout -q -b rewrite main~2
printf 'r\n' >"$WORK/r.txt"; w add r.txt; tick; w commit -q -m rewrite
if gc_ -C "$WORK" push -q --force "$(URL rw)" rewrite:main 2>"$W/nff.err"; then fail "non-fast-forward must be rejected"; fi
unchanged non-ff
if gc_ -C "$WORK" push -q "$(URL rw)" main:refs/heads/m1 main:refs/heads/m2 2>"$W/multi.err"; then fail "multi-ref must be rejected"; fi
unchanged multi-ref
if gc_ -C "$WORK" push -q --atomic "$(URL rw)" rewrite 2>"$W/atomic.err"; then fail "atomic must be rejected"; fi
unchanged atomic
w checkout -q main
# SHA-1 の作業リポジトリからの push（object-format が違うので Git が断る）
S1="$W/sha1work"; "$G" init -q --object-format=sha1 -b main "$S1"
printf 's\n' >"$S1/s.txt"; "$G" -C "$S1" add s.txt; tick; "$G" -C "$S1" commit -q -m s
if gc_ -C "$S1" push -q "$(URL rw)" main 2>"$W/sha1.err"; then fail "SHA-1 push must be rejected"; fi
unchanged sha1
echo "OK rejected pushes leave every ref unchanged (delete, tag overwrite, non-ff, multi-ref, atomic, SHA-1)"

# B. 生の要求: 未知の能力・thin pack・旧値の不一致・gzip
cat >"$W/raw.py" <<'PY'
import sys, subprocess, gzip
mode, git, repo, old, new, ref, out = sys.argv[1:8]
base = sys.argv[8] if len(sys.argv) > 8 else old
def pkt(b): return b"%04x" % (len(b) + 4) + b
caps = b"report-status object-format=sha256"
if mode == "atomic": caps = b"report-status atomic object-format=sha256"
cmd = pkt(old.encode() + b" " + new.encode() + b" " + ref.encode() + b"\0" + caps) + b"0000"
if mode == "thin":
    revs = new + "\n^" + base + "\n"
    pack = subprocess.run([git, "-C", repo, "pack-objects", "--revs", "--thin", "--stdout"], input=revs.encode(), capture_output=True, check=True).stdout
elif mode == "empty":
    pack = subprocess.run([git, "-C", repo, "pack-objects", "--stdout"], input=b"", capture_output=True, check=True).stdout
else:
    pack = subprocess.run([git, "-C", repo, "pack-objects", "--revs", "--stdout"], input=(new + "\n").encode(), capture_output=True, check=True).stdout
body = cmd + pack
if mode == "gzip": body = gzip.compress(body, mtime=0)
open(out, "wb").write(body)
PY
rawpost() { # rawpost <mode> <old> <new> <ref> [extra curl args]
  local mode="$1" old="$2" new="$3" rf="$4"; shift 4
  python3 -I "$W/raw.py" "$mode" "$G" "$WORK" "$old" "$new" "$rf" "$W/raw.bin" "${THIN_BASE:-$old}"
  curl -s -o "$W/raw.out" -w '%{http_code}' -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/x-git-receive-pack-request" "$@" --data-binary "@$W/raw.bin" "http://127.0.0.1:$PORT/repos/rw/git-receive-pack"
}
Z="$(printf '0%.0s' $(seq 1 64))"
HEAD_NOW="$(rr rev-parse main)"
NEWC="$(w rev-parse main)"
test "$(rawpost atomic "$HEAD_NOW" "$NEWC" refs/heads/main)" = 200 || fail "atomic raw should be an ERR with 200"
grep -aq "ERR" "$W/raw.out" || fail "unknown capability should be ERR"
unchanged unknown-capability
# thin pack: 基底が受信側の既存オブジェクトだけにある pack（大きいファイルを 1 行だけ変える）
seq 1 3000 >"$WORK/thinbase.txt"; w add thinbase.txt; tick; w commit -q -m thinbase
gc_ -C "$WORK" push -q "$(URL rw)" main:refs/heads/base 2>"$W/base.err" || fail "push of the thin base"
BEFORE="$(rr for-each-ref --format='%(refname) %(objectname)')"
sed -i '1500s/.*/changed/' "$WORK/thinbase.txt"; w add thinbase.txt; tick; w commit -q -m thin
THIN="$(w rev-parse main)"
THIN_BASE="$(w rev-parse main~1)"
THIN_CODE="$(rawpost thin "$Z" "$THIN" refs/heads/thin)"
unset THIN_BASE
test "$THIN_CODE" = 200 || fail "thin raw status $THIN_CODE: $(head -c 300 "$W/raw.out")"
grep -aq "ng refs/heads/thin thin_pack\|ng refs/heads/thin unpack_failed" "$W/raw.out" || fail "thin pack should be ng: $(head -c 300 "$W/raw.out")"
grep -aq "unpack thin_pack" "$W/raw.out" || fail "thin pack should report unpack thin_pack"
unchanged thin-pack
# 旧値の不一致は 409 で、成功にしない
test "$(rawpost plain "$Z" "$NEWC" refs/heads/main)" = 409 || fail "creating an existing branch should be 409"
test "$(rawpost plain "$(w rev-parse main~2)" "$NEWC" refs/heads/main)" = 409 || fail "stale old should be 409"
unchanged cas
# gzip は 415
test "$(rawpost gzip "$HEAD_NOW" "$NEWC" refs/heads/main -H 'Content-Encoding: gzip')" = 415 || fail "gzip receive-pack should be 415"
test "$(rawpost plain "$HEAD_NOW" "$NEWC" refs/heads/main -H 'Content-Encoding: x-gzip')" = 415 || fail "x-gzip should be 415"
test "$(rawpost plain "$HEAD_NOW" "$NEWC" refs/heads/main -H 'Content-Encoding: identity, gzip')" = 415 || fail "multiple encodings should be 415"
unchanged gzip
echo "OK raw requests: unknown capability, thin pack, CAS (409), gzip (415)"

# C. 認証・認可
code() { curl -s -o "$W/body.out" -w '%{http_code}' "$@"; }
adv() { echo "http://127.0.0.1:$PORT/repos/$1/info/refs?service=git-receive-pack"; }
test "$(code "$(adv rw)")" = 401 || fail "no token 401"
test "$(code -H "Authorization: Bearer ${TOKEN}x" "$(adv rw)")" = 401 || fail "bad token 401"
test "$(code -H "Authorization: Bearer $TOKEN" "$(adv priv)")" = 404 || fail "no-read private repo 404"
test "$(code -H "Authorization: Bearer $TOKEN" "$(adv ro)")" = 403 || fail "read-only repo 403"
test "$(code -H "Authorization: Bearer $TOKEN" "$(adv nosuch)")" = 404 || fail "unknown repo 404"
test "$(code -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/repos/rw/info/refs")" = 400 || fail "missing service 400"
test "$(code -H "Authorization: Bearer $TOKEN" "$(adv rw)&x=1")" = 400 || fail "extra query 400"
test "$(code -H "Authorization: Bearer $TOKEN" "$(adv rw)&service=git-receive-pack")" = 400 || fail "dup service 400"
test "$(code -H "Authorization: Bearer $TOKEN" "$(adv rw)")" = 200 || fail "good advertisement"
grep -aq "report-status" "$W/body.out" || fail "advertisement capabilities"
grep -aq "side-band" "$W/body.out" && fail "side-band must not be advertised" || true
grep -aq '\^{}' "$W/body.out" && fail "peeled lines must not be advertised" || true
test "$(code -H "Authorization: Bearer $TOKEN" "$(adv lim)")" = 200 || fail "empty repo advertisement"
grep -aq "capabilities^{}" "$W/body.out" || fail "empty repo advertises capabilities^{}"
if gc_ -C "$WORK" push -q "$(URL ro)" main 2>"$W/ro.err"; then fail "push to read-only must fail"; fi
grep -q "403" "$W/ro.err" || fail "read-only push should report 403"
"$G" -C "$W/repos/ro.git" rev-parse --verify -q main >/dev/null 2>&1 && fail "ro ref changed" || true
if gc_ -C "$WORK" push -q "$(URL priv)" main 2>"$W/priv.err"; then fail "push to hidden repo must fail"; fi
grep -q "not found" "$W/priv.err" || fail "hidden repo push should look like a missing repository (404)"
echo "OK authn/authz (401/403/404) and advertisement checks"

# C. ACL の変更と push の競合: 権限を外すと、次の push は 403／404 になり参照は変わらない
printf 'acl\n' >"$WORK/acl.txt"; w add acl.txt; tick; w commit -q -m acl
printf 'rw:alice;lim:alice=rw;ro:alice;priv:bob=rw' >"$ACLF"
if gc_ -C "$WORK" push -q "$(URL rw)" main:refs/heads/acl 2>"$W/acl403.err"; then fail "push after losing write must fail"; fi
grep -q "403" "$W/acl403.err" || fail "lost write should be 403"
unchanged acl-403
printf 'rw:bob;lim:alice=rw;ro:alice;priv:bob=rw' >"$ACLF"
if gc_ -C "$WORK" push -q "$(URL rw)" main:refs/heads/acl 2>"$W/acl404.err"; then fail "push after losing read must fail"; fi
grep -q "not found" "$W/acl404.err" || fail "lost read should look like a missing repository (404)"
unchanged acl-404
printf 'rw:alice=rw;lim:alice=rw;ro:alice;priv:bob=rw' >"$ACLF"
# 実 Git は既定で thin pack（受信側にある基底への差分）を送りうる。外部基底は受け付けないので、差分を伴う既定の push は thin_pack で断られる
# （Issue #13 の「thin pack の外部基底は拒否」に従った挙動。Git 2.43 は HTTP では --no-thin を効かせないので所見として Issue に記録）。
# 差分の探索を切る（pack.window=0）と完結した pack になり通る
if gc_ -C "$WORK" push -q "$(URL rw)" main:refs/heads/acl 2>"$W/acl_thin.err"; then fail "a thin push must be rejected"; fi
grep -q "thin_pack" "$W/acl_thin.err" || fail "thin push should report thin_pack"
unchanged thin-push
gc_ -C "$WORK" -c pack.window=0 push -q "$(URL rw)" main:refs/heads/acl 2>"$W/acl_ok.err" || fail "push after restoring write"
test "$(ref refs/heads/acl)" = "$(w rev-parse main)" || fail "restored push ref"
check_repo acl
echo "OK ACL changes take effect on the next push (403/404 leave refs unchanged)"

# C. 固定上限
L="$W/repos/lim.git"
lr() { "$G" -C "$L" "$@"; }
LW="$W/limwork"; "$G" init -q --object-format=sha256 -b main "$LW"
lw() { "$G" -C "$LW" "$@"; }
head -c 1500000 /dev/urandom >"$LW/big.bin"; lw add big.bin; tick; lw commit -q -m big
if gc_ -C "$LW" push -q "$(URL lim)" main 2>"$W/big.err"; then fail "body over 1 MiB must be rejected"; fi
lr rev-parse --verify -q main >/dev/null 2>&1 && fail "big push changed the ref" || true
echo "OK request body over 1 MiB rejected (ref unchanged)"
LW2="$W/limwork2"; "$G" init -q --object-format=sha256 -b main "$LW2"
mkdir -p "$LW2/d"
for i in $(seq 1 4100); do printf '%s\n' "$i" >"$LW2/d/f$i.txt"; done
"$G" -C "$LW2" add d; tick; "$G" -C "$LW2" commit -q -m many
if gc_ -C "$LW2" push -q "$(URL lim)" main 2>"$W/many.err"; then fail "more than 4096 objects must be rejected"; fi
lr rev-parse --verify -q main >/dev/null 2>&1 && fail "many-objects push changed the ref" || true
echo "OK more than 4096 objects rejected (ref unchanged)"
LW3="$W/limwork3"; "$G" init -q --object-format=sha256 -b main "$LW3"
mkdir -p "$LW3/d"
for i in $(seq 1 1500); do printf '%s\n' "$i" >"$LW3/d/f$i.txt"; done
"$G" -C "$LW3" add d; tick; "$G" -C "$LW3" commit -q -m under
gc_ -C "$LW3" push -q "$(URL lim)" main 2>"$W/under.err" || fail "1500 files (under the limits) must be accepted"
test "$(lr rev-parse main)" = "$("$G" -C "$LW3" rev-parse main)" || fail "under-limit ref"
lr fsck --strict >/dev/null 2>&1 || fail "fsck lim"
echo "OK a push under the limits is accepted"
echo "interop_receive: ALL OK"
