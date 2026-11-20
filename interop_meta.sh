#!/usr/bin/env bash
# 実際の Git（SHA-256 形式）および HTTP クライアントとの相互運用テスト（ADR 0048 第 4 段、Issue #15）。
# metadata／ACLと管理UI（管理 API、UI、Git 認可、public-read/private、破損 metadata 拒否）
set -euo pipefail

: "${SIGIL:=sigil}"
: "${STAGE5_GIT:=git}"
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Git version: $("$STAGE5_GIT" --version)"
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
W="$(mktemp -d tmp/interop_meta.XXXXXX)"
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
ADMIN=admin
export SIGIL_AUTH_HMAC_KEY_HEX=$KEY SIGIL_AUTH_AUDIENCE=$AUD SIGIL_GIT_ADMIN=$ADMIN

cat >"$W/mint.py" <<'PY'
import sys, hmac, hashlib, base64, struct, time
key = bytes.fromhex(sys.argv[1]); aud = sys.argv[2].encode(); sub = sys.argv[3].encode()
now = int(time.time())
payload = struct.pack(">QQH", now - 5, now + 3000, len(aud)) + aud + struct.pack(">H", len(sub)) + sub
b = lambda x: base64.urlsafe_b64encode(x).rstrip(b"=")
head = b"sigil1." + b(payload)
print((head + b"." + b(hmac.new(key, head, hashlib.sha256).digest())).decode())
PY

ADMIN_TOKEN="$(python3 -I "$W/mint.py" $KEY $AUD admin)"
ALICE_TOKEN="$(python3 -I "$W/mint.py" $KEY $AUD alice)"
BOB_TOKEN="$(python3 -I "$W/mint.py" $KEY $AUD bob)"
CHARLIE_TOKEN="$(python3 -I "$W/mint.py" $KEY $AUD charlie)"

mkdir -p "$W/repos"
start_server() {
  local log="$1"
  SIGIL_GIT_REPO_ROOT="$PWD/$W/repos" SIGIL_GIT_ACL="" SIGIL_GIT_ACL_FILE="" SIGIL_GIT_SERVE_CONNS=400 \
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

start_server "$W/server.log"
echo "server port $PORT"

ORIGIN="http://127.0.0.1:$PORT"
code() { curl -s -o "$W/body.out" -w '%{http_code}' "$@"; }

# 1. UI エンドポイントの確認
echo "Testing UI endpoints..."
test "$(code "http://127.0.0.1:$PORT/")" = 200 || fail "GET / should return 200"
grep -q "Sigil Git Management" "$W/body.out" || fail "GET / should return HTML"
test "$(code "http://127.0.0.1:$PORT/ui")" = 200 || fail "GET /ui should return 200"
grep -q "document.createElement" "$W/body.out" || fail "GET /ui should contain secure DOM scripting"

# 2. 管理 API のセキュリティ検証 (Origin, 16 KiB, DELETE 405, 非対応操作 400, Content-Type 415)
echo "Testing API security constraints..."
# Origin なし -> 403
test "$(code -X POST -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" "http://127.0.0.1:$PORT/api/repos" -d '{"id":"test"}')" = 403 || fail "missing origin should be 403"
# Origin 不一致 -> 403
test "$(code -X POST -H "Origin: http://evil.com" -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" "http://127.0.0.1:$PORT/api/repos" -d '{"id":"test"}')" = 403 || fail "origin mismatch should be 403"
# 非対応の DELETE -> 405
test "$(code -X DELETE -H "Origin: $ORIGIN" -H "Authorization: Bearer $ADMIN_TOKEN" "http://127.0.0.1:$PORT/api/repos/test")" = 405 || fail "DELETE should be 405"
# 非対応操作 (rename, quota, token) -> 400
test "$(code -X POST -H "Origin: $ORIGIN" -H "Authorization: Bearer $ADMIN_TOKEN" "http://127.0.0.1:$PORT/api/repos/test/rename" -d '{}')" = 400 || fail "rename should be 400"
test "$(code -X POST -H "Origin: $ORIGIN" -H "Authorization: Bearer $ADMIN_TOKEN" "http://127.0.0.1:$PORT/api/repos/test/quota" -d '{}')" = 400 || fail "quota should be 400"
test "$(code -X POST -H "Origin: $ORIGIN" -H "Authorization: Bearer $ADMIN_TOKEN" "http://127.0.0.1:$PORT/api/repos/test/token" -d '{}')" = 400 || fail "token should be 400"
# 非 JSON Content-Type -> 415
test "$(code -X POST -H "Origin: $ORIGIN" -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: text/plain" "http://127.0.0.1:$PORT/api/repos" -d 'text')" = 415 || fail "non-json content-type should be 415"

# 16 KiB 超えのボディ -> 413
python3 -c "print('x' * (17 * 1024))" > "$W/large.txt"
test "$(code -X POST -H "Origin: $ORIGIN" -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" "http://127.0.0.1:$PORT/api/repos" --data-binary @"$W/large.txt")" = 413 || fail "oversized body should be 413"

# 3. リポジトリ作成の権限検証 (管理者のみ作成可能)
echo "Testing repo creation..."
# 非管理者の Alice による作成 -> 403
test "$(code -X POST -H "Origin: $ORIGIN" -H "Authorization: Bearer $ALICE_TOKEN" -H "Content-Type: application/json" "http://127.0.0.1:$PORT/api/repos" \
  -d '{"id":"myrepo","visibility":"private","default_branch":"main","owners":["alice"],"writers":[],"readers":[]}')" = 403 || fail "non-admin create should be 403"

# 管理者による作成 -> 201
test "$(code -X POST -H "Origin: $ORIGIN" -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" "http://127.0.0.1:$PORT/api/repos" \
  -d '{"id":"myrepo","visibility":"private","default_branch":"main","owners":["alice"],"writers":[],"readers":[]}')" = 201 || fail "admin create should be 201"

# 重複作成 -> 409
test "$(code -X POST -H "Origin: $ORIGIN" -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" "http://127.0.0.1:$PORT/api/repos" \
  -d '{"id":"myrepo","visibility":"private","default_branch":"main","owners":["alice"],"writers":[],"readers":[]}')" = 409 || fail "duplicate create should be 409"

# 不正な repo id -> 400
test "$(code -X POST -H "Origin: $ORIGIN" -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" "http://127.0.0.1:$PORT/api/repos" \
  -d '{"id":"../escape","visibility":"private","default_branch":"main","owners":["alice"],"writers":[],"readers":[]}')" = 400 || fail "path traversal id should be 400"

# 4. 一覧・詳細の可視性
echo "Testing repo visibility in API..."
# Alice (owner) の一覧には myrepo が含まれる
test "$(code -H "Authorization: Bearer $ALICE_TOKEN" "http://127.0.0.1:$PORT/api/repos")" = 200 || fail "GET /api/repos should be 200"
grep -q "myrepo" "$W/body.out" || fail "alice should see myrepo"

# Bob (無関係) の一覧には myrepo が含まれない
test "$(code -H "Authorization: Bearer $BOB_TOKEN" "http://127.0.0.1:$PORT/api/repos")" = 200 || fail "GET /api/repos should be 200"
grep -q "myrepo" "$W/body.out" && fail "bob should not see private myrepo"

# Alice の詳細取得 -> 200
test "$(code -H "Authorization: Bearer $ALICE_TOKEN" "http://127.0.0.1:$PORT/api/repos/myrepo")" = 200 || fail "alice get repo detail should be 200"
grep -q '"usage_bytes"' "$W/body.out" || fail "detail should include usage_bytes"

# Bob の詳細取得 -> 404 (private は存在を隠蔽)
test "$(code -H "Authorization: Bearer $BOB_TOKEN" "http://127.0.0.1:$PORT/api/repos/myrepo")" = 404 || fail "bob get private repo should be 404"

# 5. Git 操作 (Git 2.39+ によるクローンと push)
echo "Testing real Git operations on private repo..."
REPO_URL="http://127.0.0.1:$PORT/repos/myrepo"

# 匿名 clone -> 404
test "$("$G" ls-remote "$REPO_URL" 2>&1 >/dev/null || true)" != ""

# Bob (権限なし) clone -> 404
test "$("$G" -c http.extraHeader="Authorization: Bearer $BOB_TOKEN" ls-remote "$REPO_URL" 2>&1 >/dev/null || true)" != ""

# Alice (owner) がコミットして push
WORK="$W/work_alice"
"$G" init -q --object-format=sha256 -b main "$WORK"
echo "hello sigil" > "$WORK/README.md"
"$G" -C "$WORK" add README.md
tick
"$G" -C "$WORK" commit -q -m "initial commit"
"$G" -C "$WORK" -c http.extraHeader="Authorization: Bearer $ALICE_TOKEN" push -q "$REPO_URL" main
echo "Alice push succeeded"

# リポジトリ側で fsck
"$G" -C "$W/repos/myrepo.git" fsck --strict >/dev/null

# 6. ACL 更新 (writers に bob、readers に charlie を追加)
echo "Testing ACL update..."
# 空の主体名を拒否 -> 400
test "$(code -X POST -H "Origin: $ORIGIN" -H "Authorization: Bearer $ALICE_TOKEN" -H "Content-Type: application/json" "http://127.0.0.1:$PORT/api/repos/myrepo/acl" \
  -d '{"owners":["alice"],"writers":[""],"readers":[]}')" = 400 || fail "empty subject in acl should be 400"

# 全ての owner を削除しようとする更新を拒否 -> 400
test "$(code -X POST -H "Origin: $ORIGIN" -H "Authorization: Bearer $ALICE_TOKEN" -H "Content-Type: application/json" "http://127.0.0.1:$PORT/api/repos/myrepo/acl" \
  -d '{"owners":[],"writers":["bob"],"readers":[]}')" = 400 || fail "removing all owners should be 400"

# 有効な更新
test "$(code -X POST -H "Origin: $ORIGIN" -H "Authorization: Bearer $ALICE_TOKEN" -H "Content-Type: application/json" "http://127.0.0.1:$PORT/api/repos/myrepo/acl" \
  -d '{"owners":["alice"],"writers":["bob"],"readers":["charlie"]}')" = 200 || fail "valid acl update should be 200"

# Bob が clone して追加コミットを push できることを確認
WORK_BOB="$W/work_bob"
"$G" -c http.extraHeader="Authorization: Bearer $BOB_TOKEN" clone -q "$REPO_URL" "$WORK_BOB"
echo "bob edit" >> "$WORK_BOB/README.md"
"$G" -C "$WORK_BOB" add README.md
tick
"$G" -C "$WORK_BOB" commit -q -m "bob commit"
"$G" -C "$WORK_BOB" -c pack.window=0 -c http.extraHeader="Authorization: Bearer $BOB_TOKEN" push -q "$REPO_URL" main
echo "Bob push succeeded"

# Charlie は clone できるが push は拒否される (403)
WORK_CHARLIE="$W/work_charlie"
"$G" -c http.extraHeader="Authorization: Bearer $CHARLIE_TOKEN" clone -q "$REPO_URL" "$WORK_CHARLIE"
echo "charlie edit" >> "$WORK_CHARLIE/README.md"
"$G" -C "$WORK_CHARLIE" add README.md
tick
"$G" -C "$WORK_CHARLIE" commit -q -m "charlie commit"
test "$(code -X POST -H "Authorization: Bearer $CHARLIE_TOKEN" -H "Content-Type: application/x-git-receive-pack-request" \
  "$REPO_URL/git-receive-pack" -d 'dummy')" = 403 || fail "charlie push should be 403"

# 7. デフォルトブランチ更新
echo "Testing default branch update..."
# 非 owner の Bob は更新不可 -> 403
test "$(code -X POST -H "Origin: $ORIGIN" -H "Authorization: Bearer $BOB_TOKEN" -H "Content-Type: application/json" "http://127.0.0.1:$PORT/api/repos/myrepo/default-branch" \
  -d '{"default_branch":"trunk"}')" = 403 || fail "bob update default-branch should be 403"

# Alice は更新可能 -> 200
test "$(code -X POST -H "Origin: $ORIGIN" -H "Authorization: Bearer $ALICE_TOKEN" -H "Content-Type: application/json" "http://127.0.0.1:$PORT/api/repos/myrepo/default-branch" \
  -d '{"default_branch":"trunk"}')" = 200 || fail "alice update default-branch should be 200"

# Bob が trunk ブランチを push
"$G" -C "$WORK_BOB" -c pack.window=0 -c http.extraHeader="Authorization: Bearer $BOB_TOKEN" push -q "$REPO_URL" main:trunk

# HEAD 参照が refs/heads/trunk に切り替わっていることを確認
grep -q "refs/heads/trunk" "$W/repos/myrepo.git/HEAD" || fail "HEAD should point to trunk"

# 8. Visibility 更新 (public-read) と匿名アクセス
echo "Testing public-read visibility..."
# Alice が public-read に更新 -> 200
test "$(code -X POST -H "Origin: $ORIGIN" -H "Authorization: Bearer $ALICE_TOKEN" -H "Content-Type: application/json" "http://127.0.0.1:$PORT/api/repos/myrepo/visibility" \
  -d '{"visibility":"public-read"}')" = 200 || fail "set public-read should be 200"

# 匿名 clone が成功することを確認
WORK_ANON="$W/work_anon"
"$G" clone -q "$REPO_URL" "$WORK_ANON"
test -f "$WORK_ANON/README.md" || fail "anonymous clone should succeed for public-read"

# 匿名の push は 401 Unauthorized
test "$(code -X POST -H "Content-Type: application/x-git-receive-pack-request" \
  "$REPO_URL/git-receive-pack" -d 'dummy')" = 401 || fail "anonymous push should be 401"

# 9. 破損 metadata の拒否 (存在を隠蔽して 404、決して public にフォールバックしない)
echo "Testing corrupted metadata denial..."
echo "corrupted-json-data" > "$W/repos/myrepo.git/sigil-metadata"

# 匿名アクセス -> 404
test "$("$G" ls-remote "$REPO_URL" 2>&1 >/dev/null || true)" != ""
# 認証済みアクセス -> 404
test "$("$G" -c http.extraHeader="Authorization: Bearer $ALICE_TOKEN" ls-remote "$REPO_URL" 2>&1 >/dev/null || true)" != ""

echo "interop_meta: ALL OK"
