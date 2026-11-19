#!/usr/bin/env bash
# 実際の Git（SHA-256 形式）との相互運用テスト（Issue #621 の完了確認）。
#  1. 私たちの init / odb_write / refs で作ったリポジトリを git fsck --strict --full と git cat-file で検証する。
#  2. 実 Git が作った packed-refs 付きのリポジトリから、私たちの delete_branch / delete_tag でブランチとタグを消し、
#     git が復活させない（show-ref に出ない）ことを確かめる。
set -euo pipefail

if [ -z "${SIGIL:-}" ]; then
  if command -v sigil >/dev/null 2>&1; then SIGIL="sigil"; else echo "SIGIL is not set" >&2; exit 1; fi
fi
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Git version: $(git --version)"
git init --object-format=sha256 --bare -q "$(mktemp -d)" || { echo "this git does not support SHA-256" >&2; exit 1; }

WORK=tmp/interop
rm -rf "$WORK"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

$SIGIL build --root . interop_make.sigil main -o "$WORK/make_bin"
$SIGIL build --root . interop_delete.sigil main -o "$WORK/delete_bin"

echo "=== A. our repository verified by real Git ==="
LAST="$("$WORK/make_bin" | head -n 1)"
G="$WORK/made.git"
test "$(git --git-dir="$G" rev-parse --show-object-format)" = "sha256"
git --git-dir="$G" fsck --strict --full
test "$(git --git-dir="$G" rev-parse HEAD)" = "$LAST"
test "$(git --git-dir="$G" cat-file -t "$LAST")" = "commit"
test "$(git --git-dir="$G" cat-file -p "$LAST:file.txt")" = "two"
test "$(git --git-dir="$G" cat-file -s "$LAST")" -gt 0
test "$(git --git-dir="$G" for-each-ref --format='%(refname)' | tr '\n' ' ')" = "refs/heads/main refs/heads/topic/a refs/tags/v1 refs/tags/v2 "
test "$(git --git-dir="$G" rev-parse refs/tags/v2)" = "$LAST"
test "$(git --git-dir="$G" log --format=%s main | tr '\n' ' ')" = "second "
echo "our repository passes fsck --strict --full and cat-file"

echo "=== B. deleting packed refs created by real Git ==="
R="$WORK/real.git"
git init --object-format=sha256 --bare -q "$R"
export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com
export GIT_AUTHOR_DATE="1700000000 +0000" GIT_COMMITTER_DATE="1700000000 +0000"
TREE="$(git --git-dir="$R" mktree </dev/null)"
C1="$(git --git-dir="$R" commit-tree "$TREE" -m one)"
C2="$(git --git-dir="$R" commit-tree "$TREE" -p "$C1" -m two)"
git --git-dir="$R" update-ref refs/heads/main "$C2"
git --git-dir="$R" update-ref refs/heads/old "$C1"
git --git-dir="$R" update-ref refs/heads/keep "$C2"
git --git-dir="$R" update-ref refs/tags/v1 "$C1"
git --git-dir="$R" update-ref refs/tags/v2 "$C2"
git --git-dir="$R" tag -a -m annotated v3 "$C1"
git --git-dir="$R" pack-refs --all
test -z "$(find "$R/refs" -type f)"
grep -q 'refs/heads/old' "$R/packed-refs"
grep -q '^\^' "$R/packed-refs"
"$WORK/delete_bin"
if git --git-dir="$R" show-ref --verify -q refs/heads/old; then echo "old branch resurrected" >&2; exit 1; fi
if git --git-dir="$R" show-ref --verify -q refs/tags/v1; then echo "v1 tag resurrected" >&2; exit 1; fi
! grep -q 'refs/heads/old' "$R/packed-refs"
! grep -q 'refs/tags/v1$' "$R/packed-refs"
git --git-dir="$R" show-ref --verify -q refs/heads/keep
git --git-dir="$R" show-ref --verify -q refs/tags/v2
git --git-dir="$R" show-ref --verify -q refs/tags/v3
# 注釈付きタグの peeled 行は残っている
grep -q '^\^' "$R/packed-refs"
test "$(git --git-dir="$R" rev-parse 'v3^{commit}')" = "$C1"
git --git-dir="$R" fsck --strict --full
test ! -e "$R/packed-refs.lock"
echo "packed refs are deleted and do not resurrect"
echo "=== interop OK ==="
