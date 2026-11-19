#!/usr/bin/env bash
# ADR 0047 第5段の Git 相互運用テスト。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
: "${SIGIL:=sigil}"
: "${STAGE5_GIT:=git}"
echo "Git version: $("$STAGE5_GIT" --version)"
if [[ -n "${STAGE5_GIT_VERSION:-}" ]]; then
  test "$("$STAGE5_GIT" --version)" = "git version $STAGE5_GIT_VERSION"
fi
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com
export LC_ALL=C
W=tmp/interop_history
R=$W/repo
rm -rf "$W"
mkdir -p "$W"
trap 'rm -rf "$W"' EXIT
"$STAGE5_GIT" init -q -b main --object-format=sha256 "$R"
g() { "$STAGE5_GIT" -C "$R" "$@"; }
run() {
  printf '%s\n' "$@" >"$W/command"
  rm -f "$W/patch.out" "$W"/applied.*
  "$W/driver" >"$W/output"
  test "$(tail -n1 "$W/output")" = 0
  sed -i '$d' "$W/output"
}
"$SIGIL" build --root . interop_history.sigil main -o "$W/driver"

printf 'one\ntwo\nthree\nfour\nfive\n' >"$R/merge.txt"
printf 'before\r\nlast' >"$R/crlf"
printf 'original\n' >"$R/日本 語"
seq 24 >"$R/multi"

printf 'gone\n' >"$R/delete"
printf '#!/bin/sh\n' >"$R/mode"
printf 'original\n' >"$R/rename"
printf '\000a' >"$R/binary"
mkdir "$R/dir"
printf 'nested file\n' >"$R/dir/item"
g add .
g commit -qm base
base=$(g rev-parse HEAD)
g tag -am base base
g branch side
printf 'ONE\ntwo\nthree\nfour\nfive\n' >"$R/merge.txt"
g add merge.txt
g commit -qm ours
left=$(g rev-parse HEAD)
g checkout -q side
printf 'one\ntwo\nthree\nfour\nFIVE\n' >"$R/merge.txt"
printf 'after\r\nlast without newline' >"$R/crlf"
printf 'changed\n' >"$R/日本 語"
sed -i '2s/^/changed /;20s/^/changed /' "$R/multi"

rm "$R/delete"
chmod +x "$R/mode"
mv "$R/rename" "$R/renamed"
touch "$R/empty"
g add -A
g commit -qm theirs
right=$(g rev-parse HEAD)
g checkout -q main
g branch git-merge
g checkout -q git-merge
g -c merge.renames=false merge --no-ff --no-edit -q side
expected=$(g rev-parse 'HEAD^{tree}')
g checkout -q main
run merge "$right"
test "$(cat "$W/output")" = "$(g rev-parse HEAD)"
test "$(g rev-parse 'HEAD^{tree}')" = "$expected"
test "$(g show -s --format=%P)" = "$left $right"
test -z "$(g status --porcelain)"
g fsck --strict --full

g -c gc.writeCommitGraph=false -c repack.writeBitmaps=false gc --quiet
g pack-refs --all
tip=$(g rev-parse HEAD)
run log "$tip"
g log --topo-order --format=%H >"$W/expected"
cmp "$W/output" "$W/expected"
run snapshot "$tip"
g -c core.quotePath=false ls-tree -r "$tip" >"$W/expected"
cmp "$W/output" "$W/expected"
n=0
while IFS=$'\t' read -r metadata path; do
  g cat-file blob "$tip:$path" >"$W/expected-blob"
  cmp "$W/blob.$n" "$W/expected-blob"
  n=$((n + 1))
done <"$W/expected"
test -z "$(g status --porcelain)"

run diff "$base" "$right"
g -c core.quotePath=false diff --no-renames --name-status "$base" "$right" >"$W/expected"
cmp "$W/output" "$W/expected"
g diff --name-status -M "$base" "$right" | grep -q $'^R100\trename\trenamed$'
g checkout -q --detach "$base"
g apply --index "$(realpath "$W/patch.out")"
test "$(g write-tree)" = "$(g rev-parse "$right^{tree}")"
g reset -q --hard "$base"

export GIT_INDEX_FILE="$(realpath "$W")/patch.index"
g read-tree "$base"
g diff --no-renames "$base" "$right" >"$W/patch.in"
run apply "$base"
n=0
while IFS=$'\t' read -r mode path; do
  if [[ "$mode" != 0 ]]; then
    blob=$(g hash-object -w --stdin <"$W/applied.$n")
    g update-index --add --cacheinfo "$mode,$blob,$path"
  else
    g update-index --force-remove -- "$path"
  fi
  n=$((n + 1))
done <"$W/output"
test "$(g write-tree)" = "$(g rev-parse "$right^{tree}")"
unset GIT_INDEX_FILE

printf '\000b' >"$R/binary"
printf 'unstaged\r\n' >"$R/crlf"
printf 'untracked\n' >"$R/untracked"
run worktree "$base"
g diff --no-renames --name-status "$base" >"$W/expected"
cmp "$W/output" "$W/expected"
grep -qx 'Binary files differ' "$W/patch.out"

g reset -q --hard "$base"
g checkout -qb conflict-right
printf 'conflicting\ntwo\nthree\nfour\nfive\n' >"$R/merge.txt"
g add merge.txt
g commit -qm conflicting
conflicting=$(g rev-parse HEAD)
g checkout -qb conflict-left "$left"
cp "$R/.git/index" "$W/index.before"
tree_digest() { (cd "$R" && find .git -type f -print0 | sort -z | xargs -0 sha256sum); }
tree_digest >"$W/git.before"
run merge "$conflicting"
printf 'Text\tmerge.txt\n' >"$W/expected"
cmp "$W/output" "$W/expected"
tree_digest >"$W/git.after"
cmp "$W/git.before" "$W/git.after"
cmp "$W/index.before" "$R/.git/index"
g cat-file blob "$left:merge.txt" >"$W/expected-blob"
cmp "$W/expected-blob" "$R/merge.txt"
test "$(g rev-parse HEAD)" = "$left"
if g -c merge.renames=false merge --no-ff --no-edit -q "$conflicting"; then
  echo "expected a Git merge conflict" >&2
  exit 1
fi
g merge --abort

# バイナリ・追加・モード・改名/編集を同時に衝突させ、一覧を比較する。
g checkout -qb kinds-left "$base"
printf '\000left' >"$R/binary"
printf 'left\n' >"$R/added"
chmod +x "$R/mode"
printf 'edited\n' >"$R/rename"
g add -A -- binary added mode rename
g commit -qm kinds-left
kinds_left=$(g rev-parse HEAD)
g checkout -qb kinds-right "$base"
printf '\000right' >"$R/binary"
printf 'right\n' >"$R/added"
printf 'changed\n' >"$R/mode"
g mv rename moved
g add -A -- binary added mode
g commit -qm kinds-right
kinds_right=$(g rev-parse HEAD)
g checkout -q kinds-left
tree_digest >"$W/git.before"
run merge "$kinds_right"
printf 'AddAdd\tadded\nBinary\tbinary\nMode\tmode\nDeleteModify\trename\n' >"$W/expected"
cmp "$W/output" "$W/expected"
tree_digest >"$W/git.after"
cmp "$W/git.before" "$W/git.after"
test "$(g rev-parse HEAD)" = "$kinds_left"
test "$(g ls-files -u)" = ""
g checkout -q conflict-left

# 二つの親の順序を入れ替えた merge commit を作って、交差した履歴を構成する。
tree=$(g rev-parse "$left^{tree}")
cross_left=$(printf 'cross left\n' | g commit-tree "$tree" -p "$left" -p "$right")
cross_right=$(printf 'cross right\n' | g commit-tree "$tree" -p "$right" -p "$left")
g update-ref refs/heads/conflict-left "$cross_left"
printf '%s\n' merge "$cross_right" >"$W/command"
"$W/driver" >"$W/output"
test "$(tail -n1 "$W/output")" = 1
grep -qx 'error:MultipleMergeBases' "$W/output"
test "$(g rev-parse HEAD)" = "$cross_left"

# 隣接行の変更を合成し、同じ位置に挿入した同一行は一度だけ反映する。
g checkout -qb adjacent-left "$base"
printf 'ONE\ntwo\nthree\nfour\ninserted\nfive\n' >"$R/merge.txt"
g commit -qam adjacent-left
adjacent_left=$(g rev-parse HEAD)
g checkout -qb adjacent-right "$base"
printf 'one\nTWO\nthree\nfour\ninserted\nfive\n' >"$R/merge.txt"
g commit -qam adjacent-right
adjacent_right=$(g rev-parse HEAD)
g branch adjacent-reverse
g checkout -q adjacent-left
printf 'ONE\nTWO\nthree\nfour\ninserted\nfive\n' >"$W/expected-blob"
run merge "$adjacent_right"
cmp "$W/expected-blob" "$R/merge.txt"
test "$(g show -s --format=%P)" = "$adjacent_left $adjacent_right"
g checkout -q adjacent-reverse
run merge "$adjacent_left"
cmp "$W/expected-blob" "$R/merge.txt"
test "$(g show -s --format=%P)" = "$adjacent_right $adjacent_left"

# 同じ位置に挿入した行が異なるときは衝突する。
g checkout -qb insert-conflict "$base"
printf 'one\ntwo\nthree\nfour\nother\nfive\n' >"$R/merge.txt"
g commit -qam insert-conflict
run merge "$adjacent_right"
printf 'Text\tmerge.txt\n' >"$W/expected"
cmp "$W/output" "$W/expected"

# 通常ファイルと symlink の種別変更は T で、パッチは削除と追加の二節になる。
g checkout -qb type-change "$base"
rm "$R/mode"
ln -s destination "$R/mode"
g add mode
g commit -qm type
type_tip=$(g rev-parse HEAD)
run diff "$base" "$type_tip"
printf 'T\tmode\n' >"$W/expected"
cmp "$W/output" "$W/expected"
g checkout -q --detach "$base"
g apply --index "$(realpath "$W/patch.out")"
test "$(g write-tree)" = "$(g rev-parse "$type_tip^{tree}")"
g reset -q --hard "$base"
g diff --no-renames "$base" "$type_tip" >"$W/patch.in"
run apply "$base"
printf '0\tmode\n120000\tmode\n' >"$W/expected"
cmp "$W/output" "$W/expected"
g cat-file blob "$type_tip:mode" >"$W/expected-blob"
cmp "$W/applied.1" "$W/expected-blob"

# パスの深さとパッチの整数上限を超える入力は LimitExceeded。
deep=$(printf 'd/%.0s' {1..128})file
mkdir -p "$R/${deep%/*}"
touch "$R/$deep"
g add -- "$deep"
g commit -qm deep
printf '%s\n' snapshot "$(g rev-parse HEAD)" >"$W/command"
"$W/driver" >"$W/output"
test "$(tail -n1 "$W/output")" = 1
grep -qx 'error:LimitExceeded' "$W/output"
printf '%s\n' 'diff --git a/crlf b/crlf' '--- a/crlf' '+++ b/crlf' '@@ -99999999999999999999999 +1 @@' >"$W/patch.in"
printf '%s\n' apply "$base" >"$W/command"
"$W/driver" >"$W/output"
test "$(tail -n1 "$W/output")" = 1
grep -qx 'error:LimitExceeded' "$W/output"

echo "Stage 5 Git interoperability passed"
