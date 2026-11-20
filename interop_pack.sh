#!/usr/bin/env bash
# 本物の Git（SHA-256 形式）が作って gc（pack 化と差分）した履歴を、pack を含めて読めることの確認（Issue #622）。
# 比較するもの: オブジェクトの型・長さ・内容、git log --topo-order、git ls-tree -r、git diff-tree --name-status、
# git fsck --strict、pack の差分（OFS_DELTA）が実際に含まれること。
set -euo pipefail

: "${SIGIL:=sigil}"
: "${STAGE5_GIT:=git}"
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Git version: $("$STAGE5_GIT" --version)"
if [[ -n "${STAGE5_GIT_VERSION:-}" ]]; then
  test "$("$STAGE5_GIT" --version)" = "git version $STAGE5_GIT_VERSION"
fi
WORK=tmp/pk
rm -rf "$WORK"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
R="$WORK/repo"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com
t=1700000000
tick() { t=$((t + 60)); export GIT_AUTHOR_DATE="$t +0000" GIT_COMMITTER_DATE="$t +0000"; }

"$STAGE5_GIT" init --object-format=sha256 -q -b main "$R"
"$STAGE5_GIT" -C "$R" config gc.writeCommitGraph false
"$STAGE5_GIT" -C "$R" config repack.writeBitmaps false
"$STAGE5_GIT" -C "$R" config core.multiPackIndex false
"$STAGE5_GIT" -C "$R" config user.name T
"$STAGE5_GIT" -C "$R" config user.email t@example.com

# 履歴: 差分に圧縮されやすい大きめのテキストを少しずつ変える。ブランチ・マージ・タグ・ディレクトリ・実行ビット・symlink を含む。
big() { for n in $(seq 1 400); do echo "line $n: the quick brown fox jumps over the lazy dog"; done; }
mkdir -p "$R/dir/sub"
big > "$R/big.txt"
echo hello > "$R/dir/a.txt"
echo deep > "$R/dir/sub/b.txt"
printf '#!/bin/sh\necho hi\n' > "$R/run.sh"; chmod +x "$R/run.sh"
ln -s big.txt "$R/link"
"$STAGE5_GIT" -C "$R" add -A; tick; "$STAGE5_GIT" -C "$R" commit -q -m "c1"
for i in 2 3 4 5 6; do
  echo "extra $i" >> "$R/big.txt"
  echo "v$i" > "$R/dir/a.txt"
  "$STAGE5_GIT" -C "$R" add -A; tick; "$STAGE5_GIT" -C "$R" commit -q -m "c$i"
done
"$STAGE5_GIT" -C "$R" tag -a -m "annotated" v1
"$STAGE5_GIT" -C "$R" checkout -q -b topic main~2
echo topic1 > "$R/topic.txt"; sed -i "1s/.*/line 1: edited on the topic branch/" "$R/big.txt"
"$STAGE5_GIT" -C "$R" add -A; tick; "$STAGE5_GIT" -C "$R" commit -q -m "t1"
echo topic2 > "$R/topic.txt"; "$STAGE5_GIT" -C "$R" rm -q dir/sub/b.txt
"$STAGE5_GIT" -C "$R" add -A; tick; "$STAGE5_GIT" -C "$R" commit -q -m "t2"
"$STAGE5_GIT" -C "$R" checkout -q main
echo main7 >> "$R/big.txt"; "$STAGE5_GIT" -C "$R" add -A; tick; "$STAGE5_GIT" -C "$R" commit -q -m "c7"
tick; "$STAGE5_GIT" -C "$R" merge -q --no-ff -m "merge topic" topic
echo after > "$R/after.txt"; "$STAGE5_GIT" -C "$R" add -A; tick; "$STAGE5_GIT" -C "$R" commit -q -m "c8"

$SIGIL build --root . interop_read.sigil main -o "$WORK/read_bin"

# 本物の Git の出力と比べる。$1: 表示名、$2: 期待する pack の数
compare() {
  local label="$1" packs="$2"
  "$STAGE5_GIT" -C "$R" cat-file --batch-all-objects --batch-check='%(objectname)' > "$WORK/ids.txt"
  "$WORK/read_bin" > "$WORK/out.txt" || { cat "$WORK/out.txt"; exit 1; }
  local exp="$WORK/expected.txt"
  echo "PACKS $packs" > "$exp"
  while read -r id; do
    type="$("$STAGE5_GIT" -C "$R" cat-file -t "$id")"
    size="$("$STAGE5_GIT" -C "$R" cat-file -s "$id")"
    sum="$("$STAGE5_GIT" -C "$R" cat-file "$type" "$id" | sha256sum | cut -d' ' -f1)"
    echo "OBJ $id $type $size $sum" >> "$exp"
  done < "$WORK/ids.txt"
  "$STAGE5_GIT" -C "$R" log --topo-order --format='LOG %H' main >> "$exp"
  "$STAGE5_GIT" -C "$R" ls-tree -r main | sed 's/^/TREE /' >> "$exp"
  for c in $("$STAGE5_GIT" -C "$R" log --topo-order --format=%H main); do
    echo "DIFF $c" >> "$exp"
    if "$STAGE5_GIT" -C "$R" rev-parse -q --verify "$c^1" >/dev/null; then
      "$STAGE5_GIT" -C "$R" diff-tree -r --name-status --no-renames "$c^1" "$c" >> "$exp"
    else
      "$STAGE5_GIT" -C "$R" diff-tree -r --no-commit-id --name-status --no-renames --root "$c" >> "$exp"
    fi
  done
  # 出力の最後の行は main の戻り値 0
  sed -i '$ d' "$WORK/out.txt"
  if ! diff -u "$exp" "$WORK/out.txt"; then
    echo "[$label] output differs from real Git" >&2
    exit 1
  fi
  echo "[$label] read $(wc -l < "$WORK/ids.txt") objects, the history, ls-tree -r and diff --name-status identically to real Git"
}

# 1. gc の前: 緩いオブジェクト（本物の Git が書いた Huffman 圧縮の zlib）
test -z "$(ls "$R"/.git/objects/pack/*.idx 2>/dev/null)"
"$STAGE5_GIT" -C "$R" fsck --strict --full
compare "loose" 0

# 2. gc（pack 化と差分）と pack-refs の後
"$STAGE5_GIT" -C "$R" gc -q --aggressive --prune=now
"$STAGE5_GIT" -C "$R" pack-refs --all
test -n "$(ls "$R"/.git/objects/pack/*.idx)"
test "$(find "$R/.git/objects" -type f -path '*/objects/??/*' | wc -l)" -eq 0
VP="$("$STAGE5_GIT" -C "$R" verify-pack -v "$PWD"/"$R"/.git/objects/pack/*.idx)"
grep -qE '^chain length = [0-9]+: [0-9]+ objects?$' <<<"$VP" || { echo "the pack has no delta objects" >&2; exit 1; }
"$STAGE5_GIT" -C "$R" fsck --strict --full
compare "packed" 1
echo "=== interop (pack) OK ==="
