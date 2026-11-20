#!/usr/bin/env bash
# 実際の Git（SHA-256 形式）との相互運用テスト（Issue #621 の完了確認）。
#  1. 私たちの init / odb_write / refs で作ったリポジトリを git fsck --strict --full と git cat-file で検証する。
#  2. 実 Git が作った packed-refs 付きのリポジトリから、私たちの delete_branch / delete_tag でブランチとタグを消し、
#     git が復活させない（show-ref に出ない）ことを確かめる。
set -euo pipefail

: "${SIGIL:=sigil}"
: "${STAGE5_GIT:=git}"
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Git version: $("$STAGE5_GIT" --version)"
if [[ -n "${STAGE5_GIT_VERSION:-}" ]]; then
  test "$("$STAGE5_GIT" --version)" = "git version $STAGE5_GIT_VERSION"
fi
"$STAGE5_GIT" init --object-format=sha256 --bare -q "$(mktemp -d)" || { echo "this git does not support SHA-256" >&2; exit 1; }

WORK=tmp/interop
rm -rf "$WORK"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

$SIGIL build --root . interop_make.sigil main -o "$WORK/make_bin"
$SIGIL build --root . interop_delete.sigil main -o "$WORK/delete_bin"

echo "=== A. our repository verified by real Git ==="
LAST="$("$WORK/make_bin" | head -n 1)"
G="$WORK/made.git"
test "$("$STAGE5_GIT" --git-dir="$G" rev-parse --show-object-format)" = "sha256"
"$STAGE5_GIT" --git-dir="$G" fsck --strict --full
test "$("$STAGE5_GIT" --git-dir="$G" rev-parse HEAD)" = "$LAST"
test "$("$STAGE5_GIT" --git-dir="$G" cat-file -t "$LAST")" = "commit"
test "$("$STAGE5_GIT" --git-dir="$G" cat-file -p "$LAST:file.txt")" = "two"
test "$("$STAGE5_GIT" --git-dir="$G" cat-file -s "$LAST")" -gt 0
test "$("$STAGE5_GIT" --git-dir="$G" for-each-ref --format='%(refname)' | tr '\n' ' ')" = "refs/heads/main refs/heads/topic/a refs/tags/v1 refs/tags/v2 "
test "$("$STAGE5_GIT" --git-dir="$G" rev-parse refs/tags/v2)" = "$LAST"
test "$("$STAGE5_GIT" --git-dir="$G" log --format=%s main | tr '\n' ' ')" = "second "
echo "our repository passes fsck --strict --full and cat-file"

echo "=== B. deleting packed refs created by real Git ==="
R="$WORK/real.git"
"$STAGE5_GIT" init --object-format=sha256 --bare -q "$R"
export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com
export GIT_AUTHOR_DATE="1700000000 +0000" GIT_COMMITTER_DATE="1700000000 +0000"
TREE="$("$STAGE5_GIT" --git-dir="$R" mktree </dev/null)"
C1="$("$STAGE5_GIT" --git-dir="$R" commit-tree "$TREE" -m one)"
C2="$("$STAGE5_GIT" --git-dir="$R" commit-tree "$TREE" -p "$C1" -m two)"
"$STAGE5_GIT" --git-dir="$R" update-ref refs/heads/main "$C2"
"$STAGE5_GIT" --git-dir="$R" update-ref refs/heads/old "$C1"
"$STAGE5_GIT" --git-dir="$R" update-ref refs/heads/keep "$C2"
"$STAGE5_GIT" --git-dir="$R" update-ref refs/tags/v1 "$C1"
"$STAGE5_GIT" --git-dir="$R" update-ref refs/tags/v2 "$C2"
"$STAGE5_GIT" --git-dir="$R" tag -a -m annotated v3 "$C1"
"$STAGE5_GIT" --git-dir="$R" pack-refs --all
test -z "$(find "$R/refs" -type f)"
grep -q 'refs/heads/old' "$R/packed-refs"
grep -q '^\^' "$R/packed-refs"
"$WORK/delete_bin"
if "$STAGE5_GIT" --git-dir="$R" show-ref --verify -q refs/heads/old; then echo "old branch resurrected" >&2; exit 1; fi
if "$STAGE5_GIT" --git-dir="$R" show-ref --verify -q refs/tags/v1; then echo "v1 tag resurrected" >&2; exit 1; fi
! grep -q 'refs/heads/old' "$R/packed-refs"
! grep -q 'refs/tags/v1$' "$R/packed-refs"
"$STAGE5_GIT" --git-dir="$R" show-ref --verify -q refs/heads/keep
"$STAGE5_GIT" --git-dir="$R" show-ref --verify -q refs/tags/v2
"$STAGE5_GIT" --git-dir="$R" show-ref --verify -q refs/tags/v3
# 注釈付きタグの peeled 行は残っている
grep -q '^\^' "$R/packed-refs"
test "$("$STAGE5_GIT" --git-dir="$R" rev-parse 'v3^{commit}')" = "$C1"
"$STAGE5_GIT" --git-dir="$R" fsck --strict --full
test ! -e "$R/packed-refs.lock"
echo "packed refs are deleted and do not resurrect"
echo "=== interop OK ==="
