#!/usr/bin/env bash
# ADR 0047 決定 6-5 障害注入・中断・実 Git (fsck --strict) 相互運用テスト
set -euo pipefail

: "${SIGIL:=sigil}"
: "${STAGE5_GIT:=git}"
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== 障害注入・プロセス中断・実 Git 整合性検証 (ADR 0047 決定 6-5) ==="
echo "Git version: $("$STAGE5_GIT" --version)"

W="tmp/interop_ops"
rm -rf "$W"
mkdir -p "$W"
trap '[ -n "${KEEP:-}" ] || rm -rf "$W"' EXIT

export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

$SIGIL build --root . interop_ops.sigil main -o "$W/ops_bin"
R="$W/repo"

run_ops() {
  cat >"$W/cmds.txt"
  "$W/ops_bin" <"$W/cmds.txt" | sed '$d' >"$W/out.txt"
}
g() { "$STAGE5_GIT" -C "$R" "$@"; }

# 1. 正常なリポジトリの初期化と初期コミット
run_ops <<'CMDS'
init
CMDS
mkdir -p "$R/dir"
printf "hello world\n" >"$R/hello.txt"
printf "version 1\n" >"$R/dir/v.txt"
run_ops <<'CMDS'
add:hello.txt
add:dir
commit:initial commit
branch:feature
CMDS

INITIAL_COMMIT="$(g rev-parse HEAD)"
echo "初期コミット作成完了: $INITIAL_COMMIT"
g fsck --strict --full

# 2. 障害シナリオ A: オブジェクト書き込み中断 (孤立 tmp_obj_* の残存)
echo "--- シナリオ A: tmp_obj_* 残存時の fsck と到達可能性 ---"
TMP_OBJ_DIR="$R/.git/objects/42"
mkdir -p "$TMP_OBJ_DIR"
printf "truncated partial zlib or raw data" >"$TMP_OBJ_DIR/tmp_obj_faultinjection_001"

# 書き込み中断後も実 Git の fsck が成功し、コミットが到達可能
g fsck --strict --full
test "$(g rev-parse HEAD)" = "$INITIAL_COMMIT"
test "$(g cat-file -p "$INITIAL_COMMIT" | grep -c "tree ")" -eq 1
echo "シナリオ A 合格: 孤立 tmp_obj_* があっても fsck 成功・到達可能"

# 3. 障害シナリオ B: 参照更新中の中断 (孤立 <ref>.lock の残存)
echo "--- シナリオ B: <ref>.lock 残存時の排他保護と HEAD 不変 ---"
mkdir -p "$R/.git/refs/heads"
printf "invalid_id_crashed_before_rename\n" >"$R/.git/refs/heads/main.lock"

# 孤立ロックがある状態でのコミット試行
printf "new edit\n" >"$R/new_edit.txt"
run_ops <<'CMDS'
add:new_edit.txt
commit:should fail due to lock
CMDS

# ロックのため更新失敗、HEAD は INITIAL_COMMIT のまま保護
test "$(g rev-parse refs/heads/main)" = "$INITIAL_COMMIT"
g fsck --strict --full
rm -f "$R/.git/refs/heads/main.lock"
echo "シナリオ B 合格: <ref>.lock 存在時は更新拒否・参照値は不変"

# 4. 障害シナリオ C: 索引更新中の中断 (孤立 index.lock と未保存変更の保護)
echo "--- シナリオ C: index.lock 残存時の未保存変更（作業木・未コミット変更）の保護 ---"
printf "dirty uncommitted worktree modification\n" >"$R/hello.txt"
printf "user unsaved file\n" >"$R/unsaved.txt"
printf "0" >"$R/.git/index.lock"

# index.lock がある状態での add 試行
run_ops <<'CMDS'
add:unsaved.txt
CMDS

# 未保存の変更が失われていないことを検証
test "$(cat "$R/hello.txt")" = "dirty uncommitted worktree modification"
test "$(cat "$R/unsaved.txt")" = "user unsaved file"
rm -f "$R/.git/index.lock"
g fsck --strict --full
echo "シナリオ C 合格: index.lock 中断時も作業木の未保存変更は完全に保持"

# 5. 障害シナリオ D: packed-refs 参照削除の競合中断と完全削除（復活防止）
echo "--- シナリオ D: packed-refs 参照削除の中断・非復活確認と fsck ---"
# pack-refs で packed-refs を生成
g pack-refs --all
test -f "$R/.git/packed-refs"
grep -q "refs/heads/feature" "$R/.git/packed-refs"

# D-1: packed-refs.lock が存在する場合の中断（ロールバック・参照保護）
printf "0" >"$R/.git/packed-refs.lock"
run_ops <<'CMDS'
delete_branch:feature
CMDS
grep -qi "error:locked" "$W/out.txt"
# ロック競合時は削除されず参照が保護される
test "$(g rev-parse refs/heads/feature)" = "$INITIAL_COMMIT"
grep -q "refs/heads/feature" "$R/.git/packed-refs"
g fsck --strict --full
rm -f "$R/.git/packed-refs.lock"

# D-2: 本実装の delete_branch による削除
run_ops <<'CMDS'
delete_branch:feature
CMDS
grep -q "ok:deleted" "$W/out.txt"
test ! -f "$R/.git/refs/heads/feature"
! grep -q "refs/heads/feature" "$R/.git/packed-refs" || { echo "packed-refs から削除されていません" >&2; exit 1; }

# 再起動・参照読み出しで feature が復活しない
g fsck --strict --full
! g rev-parse -q --verify refs/heads/feature >/dev/null || { echo "削除された参照が復活しました" >&2; exit 1; }
echo "シナリオ D 合格: Sigil delete_branch による packed-refs ロック保護および完全削除（非復活）・fsck 成功"

# 6. 障害シナリオ E: 中断・障害後の不変条件検証 (ADR 0047 決定 6-5 (b)(c)(d))
echo "--- シナリオ E: 障害・中断後の不変条件検証（コミット到達可能性・未欠落・未保存変更保護） ---"
# ユーザーの作業木変更と未コミット変更を準備
printf "critical user uncommitted work\n" >"$R/critical.txt"

# 競合ロックによる中断発生時
printf "0" >"$R/.git/index.lock"
run_ops <<'CMDS'
add:critical.txt
CMDS
rm -f "$R/.git/index.lock"

# 不変条件の検証:
# (b) 応答済みの commit は参照から到達できること
HEAD_COMMIT="$(g rev-parse HEAD)"
test "$HEAD_COMMIT" = "$INITIAL_COMMIT"
g cat-file -p "$HEAD_COMMIT" >/dev/null

# (c) 参照が指すオブジェクトが欠けた状態にならないこと
g fsck --strict --full

# (d) ユーザーの未保存の変更（作業木だけの変更）が失われないこと
test "$(cat "$R/critical.txt")" = "critical user uncommitted work"

echo "シナリオ E 合格: 障害後の不変条件（コミット到達可能性・オブジェクト非欠落・未保存変更保持）を検証"

echo "=== 障害注入・実 Git 整合性検証 全シナリオ合格 ==="
