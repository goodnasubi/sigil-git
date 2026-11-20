#!/usr/bin/env bash
# 実際の Git（SHA-256 形式）との相互運用テスト（Issue #628 の完了確認。索引・add・commit・checkout・作業木の書き込み）。
#  A. 私たちの init / add / commit / branch で作ったリポジトリを、実 Git の fsck・log・ls-tree・diff・cat-file で検証する。
#  B. 実 Git の clone と checkout が、私たちの commit で clean な status になり、実行ビットが往復する。
#  C. 私たちの checkout の結果が、実 Git の checkout と同じ索引・作業木で、git status が clean。
#  D. 衝突（作業木の変更・索引の変更・追跡外ファイルの上書き）は何も変えずに失敗する。
#  E. 悪意のある tree（.git・..・gitlink・symlink）は木の外に何も書かず、panic せずに失敗する。
#  F. 作業木の中の symlink を通した書き込み・読み取り・checkout は失敗し、外には何も書かれない。
#  H. 日本語など UTF-8 のパスが add・commit・checkout で往復する。
set -euo pipefail

: "${SIGIL:=sigil}"
: "${STAGE5_GIT:=git}"
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Git version: $("$STAGE5_GIT" --version)"
if [[ -n "${STAGE5_GIT_VERSION:-}" ]]; then
  test "$("$STAGE5_GIT" --version)" = "git version $STAGE5_GIT_VERSION"
fi
"$STAGE5_GIT" init --object-format=sha256 --bare -q "$(mktemp -d)" || { echo "this git does not support SHA-256" >&2; exit 1; }

W=tmp/interop_ops
rm -rf "$W"
mkdir -p "$W"
trap '[ -n "${KEEP:-}" ] || rm -rf "$W"' EXIT
export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

$SIGIL build --root . interop_ops.sigil main -o "$W/ops_bin"
R="$W/repo"
# run <expected output, newline separated>  (stdin: commands)
run() {
  cat >"$W/cmds.txt"
  "$W/ops_bin" | sed '$d' >"$W/out.txt"
}
expect_out() { test "$(cat "$W/out.txt" | tr '\n' ' ')" = "$1 " || { echo "unexpected output: $(cat "$W/out.txt" | tr '\n' ' ') (wanted: $1)" >&2; exit 1; }; }
g() { "$STAGE5_GIT" -C "$R" "$@"; }

echo "=== A. our init / add / commit / branch verified by real Git ==="
run <<'CMDS'
init
CMDS
expect_out "ok:init"
mkdir -p "$R/dir/sub" "$R/empty-not-created"
printf 'alpha\n' >"$R/a.txt"
printf 'bravo\n' >"$R/dir/b.txt"
printf '#!/bin/sh\necho hi\n' >"$R/dir/sub/run.sh"
chmod 755 "$R/dir/sub/run.sh"
printf '\000\001binary\377' >"$R/bin.dat"
run <<'CMDS'
add:a.txt
add:dir
add:bin.dat
commit:first
branch:topic
CMDS
C1="$(g rev-parse HEAD)"
sed -n 1,3p "$W/out.txt" | tr '\n' ' ' | grep -q '^ok:added ok:added ok:added ' || { echo "bad add output" >&2; cat "$W/out.txt" >&2; exit 1; }
test "$(sed -n 4p "$W/out.txt")" = "ok:$C1"
printf 'bravo2\n' >"$R/dir/b.txt"
printf 'new\n' >"$R/c.txt"
run <<'CMDS'
add:dir/b.txt
add:c.txt
commit:second
CMDS
C2="$(g rev-parse HEAD)"
test "$(g rev-parse --show-object-format)" = "sha256"
g fsck --strict --full
test "$(g log --topo-order --format=%s | tr '\n' ' ')" = "second first "
test "$(g rev-parse topic)" = "$C1"
test "$(g ls-tree -r --name-only HEAD | tr '\n' ' ')" = "a.txt bin.dat c.txt dir/b.txt dir/sub/run.sh "
test "$(g ls-tree -r HEAD | grep -c '^100755 ')" = "1"
test "$(g ls-tree -r HEAD | grep 'run.sh' | cut -c1-6)" = "100755"
test "$(g diff --name-status "$C1" "$C2" | tr '\t\n' ': ')" = "A:c.txt M:dir/b.txt " || test "$(g diff --name-status "$C1" "$C2" | tr '\t\n' ': ')" = "M:dir/b.txt A:c.txt " || { echo "bad diff" >&2; exit 1; }
test "$(g cat-file -p HEAD:dir/b.txt)" = "bravo2"
test "$(g cat-file -p "$C1:dir/b.txt")" = "bravo"
test "$(g cat-file -t HEAD)" = "commit"
test "$(g cat-file -p HEAD | sed -n '/^author/p')" = "author T <t@example.com> 1700000000 +0900"
test "$(g cat-file -p HEAD | tail -n 1)" = "second"
test -z "$(g status --porcelain)"
test ! -e "$R/.git/index.lock"
echo "our repository passes fsck --strict --full, log, ls-tree, diff and cat-file; git status is clean"

echo "=== B. real git clone / checkout of our commits ==="
"$STAGE5_GIT" clone -q "$R" "$W/clone"
test "$("$STAGE5_GIT" -C "$W/clone" rev-parse --show-object-format)" = "sha256"
test -z "$("$STAGE5_GIT" -C "$W/clone" status --porcelain)"
test -x "$W/clone/dir/sub/run.sh"
test "$(cat "$W/clone/dir/b.txt")" = "bravo2"
"$STAGE5_GIT" -C "$W/clone" checkout -q "$C1"
test -z "$("$STAGE5_GIT" -C "$W/clone" status --porcelain)"
test "$(cat "$W/clone/dir/b.txt")" = "bravo"
test ! -e "$W/clone/c.txt"
echo "real git checks out our commits with a clean status and the exec bit"

echo "=== C. our checkout equals real git checkout ==="
run <<'CMDS'
checkout:topic
CMDS
expect_out "ok:$C1"
test "$(g symbolic-ref HEAD)" = "refs/heads/topic"
test -z "$(g status --porcelain)"
test "$(cat "$R/dir/b.txt")" = "bravo"
test ! -e "$R/c.txt"
test -x "$R/dir/sub/run.sh"
test "$(g ls-files -s | cut -d' ' -f1,2 | tr '\n' ' ')" = "$("$STAGE5_GIT" -C "$W/clone" ls-files -s | cut -d' ' -f1,2 | tr '\n' ' ')"
run <<'CMDS'
checkout:main
CMDS
expect_out "ok:$C2"
test -z "$(g status --porcelain)"
test "$(cat "$R/dir/b.txt")" = "bravo2"
test "$(cat "$R/c.txt")" = "new"
test -x "$R/dir/sub/run.sh"
"$STAGE5_GIT" -C "$W/clone" checkout -q "$C2"
test "$(g ls-files -s | tr '\n' ' ')" = "$("$STAGE5_GIT" -C "$W/clone" ls-files -s | tr '\n' ' ')" || test "$(g ls-files -s | cut -d' ' -f1,2,4 | tr '\n' ' ')" = "$("$STAGE5_GIT" -C "$W/clone" ls-files -s | cut -d' ' -f1,2,4 | tr '\n' ' ')"
# 実行ビットが往復する（私たちの checkout が書いたファイルを実 Git が clean と判断する）
test -z "$(g status --porcelain)"
run <<'CMDS'
checkout:6666666666666666666666666666666666666666666666666666666666666666
CMDS
grep -q '^error:' "$W/out.txt"
test "$(g symbolic-ref HEAD)" = "refs/heads/main"
echo "our checkout matches real git: clean status, same index, exec bit round trip"

echo "=== D. conflicts leave everything unchanged ==="
snap() { { g rev-parse HEAD; g symbolic-ref HEAD; cat "$R/.git/index" | sha256sum; (cd "$R" && find . -path ./.git -prune -o -type f -print | sort | xargs sha256sum); } | sha256sum; }
# 作業木の変更
printf 'edited\n' >"$R/dir/b.txt"
S0="$(snap)"
run <<'CMDS'
checkout:topic
CMDS
expect_out "error:Conflict"
test "$(snap)" = "$S0"
test "$(g symbolic-ref HEAD)" = "refs/heads/main"
printf 'bravo2\n' >"$R/dir/b.txt"
# 索引の変更（ステージ済み）
printf 'staged\n' >"$R/dir/b.txt"
g add dir/b.txt
S0="$(snap)"
run <<'CMDS'
checkout:topic
CMDS
expect_out "error:Conflict"
test "$(snap)" = "$S0"
g reset -q --hard
test -z "$(g status --porcelain)"
# 追跡外ファイルが上書きされる（topic にだけ無い c.txt を main から topic へ…ではなく、topic から main へ）
run <<'CMDS'
checkout:topic
CMDS
expect_out "ok:$C1"
printf 'untracked\n' >"$R/c.txt"
S0="$(snap)"
run <<'CMDS'
checkout:main
CMDS
expect_out "error:Conflict"
test "$(snap)" = "$S0"
test "$(cat "$R/c.txt")" = "untracked"
rm -f "$R/c.txt"
test ! -e "$R/.git/index.lock"
echo "conflicts are refused and nothing changed"

echo "=== E. malicious trees ==="
run <<'CMDS'
checkout:main
CMDS
expect_out "ok:$C2"
OUT="$W/outside"
mkdir -p "$OUT"
BLOB="$(printf 'pwn\n' | g hash-object -w --stdin)"
mk_tree() { # name mode  → tree id（--literally で不正な名前も作る）
  python3 - "$BLOB" "$1" "$2" <<'PY' | g hash-object -t tree -w --stdin --literally
import sys
blob,name,mode=sys.argv[1],sys.argv[2],sys.argv[3]
sys.stdout.buffer.write(mode.encode()+b" "+name.encode()+b"\0"+bytes.fromhex(blob))
PY
}
mk_commit() { g commit-tree "$1" -m evil; }
n=0
for spec in ".git:100644" "..:100644" ".GIT:100644" "git~1:100644" ".git:40000" "link:120000" "sub:160000"; do
  name="${spec%:*}"; mode="${spec##*:}"
  n=$((n + 1))
  if [ "$mode" = 40000 ]; then T="$(python3 -c "
import sys
sys.stdout.buffer.write(b'40000 $name\0'+bytes.fromhex('$(printf '' | g hash-object -t tree -w --stdin)'))" | g hash-object -t tree -w --stdin --literally)"; else T="$(mk_tree "$name" "$mode")"; fi
  EC="$(mk_commit "$T")"
  g update-ref "refs/heads/evil$n" "$EC"
  S0="$(snap)"
  run <<CMDS
checkout:evil$n
CMDS
  grep -q '^error:' "$W/out.txt" || { echo "malicious tree '$spec' was accepted" >&2; cat "$W/out.txt" >&2; exit 1; }
  test "$(snap)" = "$S0" || { echo "malicious tree '$spec' changed the repository" >&2; exit 1; }
  test ! -e "$R/.git/index.lock"
done
test -z "$(find "$OUT" -type f)"
# 作業木に仕込んだ symlink を通した書き込み
ln -s "$PWD/$OUT" "$R/n"
T="$(mk_tree "n/x.txt" 100644)"   # n/x.txt（パスの区切りを含む名前）
EC="$(mk_commit "$T")"; g update-ref refs/heads/evilx "$EC"
run <<'CMDS'
checkout:evilx
CMDS
grep -q '^error:' "$W/out.txt"
rm -f "$R/n"
test -z "$(find "$OUT" -type f)"
test -z "$(g status --porcelain)"
echo "malicious trees are refused; nothing was written outside the work tree"
echo "=== F. writes and reads never follow symlinks in the work tree ==="
# 作業木の中の（外を指す）ディレクトリ symlink を通した書き込み・読み取りは失敗し、外には何も書かれない。
OUT2="$PWD/$W/outside2"
mkdir -p "$OUT2/sub"
printf 'secret\n' >"$OUT2/secret"
ln -s "$OUT2" "$R/lnk"
run <<'CMDS'
wtwrite:lnk/x.txt
wtwrite:lnk/sub/y.txt
wtread:lnk/secret
CMDS
test "$(sed -n 1p "$W/out.txt" | cut -c1-6)" = "error:" || { echo "write through a directory symlink was accepted" >&2; exit 1; }
test "$(sed -n 2p "$W/out.txt" | cut -c1-6)" = "error:" || { echo "write through a nested directory symlink was accepted" >&2; exit 1; }
test "$(sed -n 3p "$W/out.txt" | cut -c1-6)" = "error:" || { echo "read through a directory symlink was accepted" >&2; exit 1; }
test ! -e "$OUT2/x.txt" && test ! -e "$OUT2/sub/y.txt"
test -z "$(find "$OUT2" -name '.sigil-tmp-*')"
test "$(cat "$OUT2/secret")" = "secret"
rm -f "$R/lnk"
# 最後の成分が symlink のとき、rename は symlink 自体を置き換え、リンク先は変わらない。
printf 'orig\n' >"$OUT2/target"
ln -s "$OUT2/target" "$R/fl"
run <<'CMDS'
wtwrite:fl
CMDS
test "$(cat "$OUT2/target")" = "orig"
test ! -L "$R/fl" && test "$(cat "$R/fl")" = "pwn"
rm -f "$R/fl"
# 実 Git と同じ入れ子の木（n/x.txt）を、作業木の既存の symlink n（外を指す）に対して checkout する。
OUT3="$PWD/$W/outside3"
mkdir -p "$OUT3"
INNER="$(printf '100644 blob %s\tx.txt\n' "$BLOB" | g mktree)"
OUTER="$(printf '040000 tree %s\tn\n' "$INNER" | g mktree)"
g update-ref refs/heads/nested "$(mk_commit "$OUTER")"
ln -s "$OUT3" "$R/n"
S0="$(snap)"
run <<'CMDS'
checkout:nested
CMDS
grep -q '^error:' "$W/out.txt" || { echo "checkout through a symlink was accepted" >&2; exit 1; }
test -z "$(find "$OUT3" -type f)"
test -L "$R/n"
test "$(snap)" = "$S0"
rm -f "$R/n"
# 追跡しているディレクトリ dir が、外の同じ内容のディレクトリを指す symlink に置き換えられている。
OUT4="$PWD/$W/outside4"
mkdir -p "$OUT4"
cp -r "$R/dir/." "$OUT4/"
mv "$R/dir" "$W/dir.bak"
ln -s "$OUT4" "$R/dir"
run <<'CMDS'
checkout:topic
CMDS
expect_out "error:Conflict"
test "$(cat "$OUT4/b.txt")" = "bravo2"
test -L "$R/dir"
rm -f "$R/dir"
mv "$W/dir.bak" "$R/dir"
test -z "$(g status --porcelain)"
echo "no write or read follows a symlink; the checkout is refused without touching the target"
echo "=== H. non-ASCII paths ==="
printf 'こんにちは\n' >"$R/ファイル.txt"
run <<'CMDS'
add:ファイル.txt
commit:japanese
CMDS
C3="$(g rev-parse HEAD)"
test "$(sed -n 1p "$W/out.txt")" = "ok:added"
test "$(g -c core.quotepath=false ls-tree -r --name-only HEAD | grep -c 'ファイル.txt')" = "1"
# 悪意のある木（セクション E）が残っているので全体の fsck はせず、新しい commit から辿れるオブジェクトだけを検査する。
g rev-list --objects "$C3" >/dev/null
test -z "$(g status --porcelain)"
run <<'CMDS'
checkout:topic
CMDS
expect_out "ok:$C1"
test ! -e "$R/ファイル.txt"
run <<'CMDS'
checkout:refs/heads/main
CMDS
expect_out "ok:$C3"
test "$(cat "$R/ファイル.txt")" = "こんにちは"
test -z "$(g status --porcelain)"
echo "non-ASCII paths round trip"
echo "=== interop_ops OK ==="
