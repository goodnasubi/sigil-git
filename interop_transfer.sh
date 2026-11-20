#!/usr/bin/env bash
# 実際の Git（SHA-256 形式）との相互運用テスト（ADR 0048 第 1 段、Issue #8）。転送の符号化・復号（codec）と wire 専用 pack の出力。
#  A. 能力広告: 私たちの upload-pack／receive-pack の広告が、実 Git の `upload-pack --advertise-refs`／`receive-pack --advertise-refs` と
#     同じ参照行（HEAD・ブランチ・タグ・peeled 行・空リポジトリの capabilities^{}）になり、能力は実 Git が広告するものの部分集合である。
#     packed-refs にした状態でも同じ。実 Git の広告を私たちの pkt-line の復号が受理する。
#  B. wire 専用 pack: 私たちの pack を、実 Git の index-pack --strict・verify-pack・unpack-objects・fsck --strict が受理し、
#     全オブジェクトの型・長さ・内容・識別子が一致する。非 delta で、すべてのブロックが stored である。
#  C. 拒否: 存在しないオブジェクトと、オブジェクト数 4096 超過は pack を作らずに失敗する。
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

W=tmp/interop_transfer
rm -rf "$W"
mkdir -p "$W"
trap '[ -n "${KEEP:-}" ] || rm -rf "$W"' EXIT
export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset GIT_PROTOCOL

$SIGIL build --root . interop_transfer.sigil main -o "$W/transfer_bin"
R="$W/repo"
g() { "$STAGE5_GIT" -C "$R" "$@"; }
t=1700000000
tick() { t=$((t + 60)); export GIT_AUTHOR_DATE="$t +0000" GIT_COMMITTER_DATE="$t +0000"; }

run_driver() {
  cat >"$W/cmds.txt"
  "$W/transfer_bin" <"$W/cmds.txt" | sed '$d' >"$W/out.txt"
}

# pkt-line を実 Git の広告から正規化する: 参照行を "id name" で、先頭行の能力を "CAPS ..." で出す
norm() {
  python3 - "$1" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
pos = 0
first = True
while pos < len(data):
    n = int(data[pos:pos+4], 16)
    if n == 0:
        pos += 4
        continue
    payload = data[pos+4:pos+n]
    pos += n
    if payload.endswith(b'\n'):
        payload = payload[:-1]
    if first:
        line, _, caps = payload.partition(b'\0')
        print('CAPS', caps.decode())
        first = False
    else:
        line = payload
    print(line.decode())
assert pos == len(data), 'trailing data'
PY
}

# 私たちの広告（$1）と実 Git の広告（$2）が、参照行は同じで、私たちの能力は実 Git の能力の部分集合で、能力の文字列が $3 と等しいこと
compare_adv() {
  local ours="$1" theirs="$2" want_caps="$3" label="$4"
  norm "$ours" >"$W/ours.norm"
  norm "$theirs" >"$W/theirs.norm"
  grep -v '^CAPS ' "$W/ours.norm" >"$W/ours.refs"
  grep -v '^CAPS ' "$W/theirs.norm" >"$W/theirs.refs"
  diff -u "$W/theirs.refs" "$W/ours.refs" || { echo "$label: 参照行が実 Git と違う" >&2; exit 1; }
  local oc tc
  oc="$(grep '^CAPS ' "$W/ours.norm" | cut -d' ' -f2-)"
  tc="$(grep '^CAPS ' "$W/theirs.norm" | cut -d' ' -f2-)"
  [ "$oc" = "$want_caps" ] || { echo "$label: 能力が期待と違う: $oc" >&2; exit 1; }
  for c in $oc; do
    case " $tc " in *" $c "*) ;; *) echo "$label: 実 Git が広告しない能力を広告している: $c (git: $tc)" >&2; exit 1 ;; esac
  done
  echo "  $label: 参照行 $(wc -l <"$W/ours.refs") 行が実 Git と一致、能力: $oc"
}

adv_both() {
  # $1: ラベル、$2: upload の期待する能力、$3: receive の期待する能力
  rm -f "$W/adv_upload.bin" "$W/adv_receive.bin" "$W/git_upload.bin" "$W/git_receive.bin"
  run_driver <<'CMDS'
adv_upload
adv_receive
CMDS
  grep -qx 'ok:written' "$W/out.txt" || { cat "$W/out.txt"; echo "広告の生成に失敗" >&2; exit 1; }
  [ "$(grep -c '^ok:written$' "$W/out.txt")" = 2 ]
  "$STAGE5_GIT" upload-pack --advertise-refs "$R" >"$W/git_upload.bin"
  "$STAGE5_GIT" receive-pack --advertise-refs "$R" >"$W/git_receive.bin"
  compare_adv "$W/adv_upload.bin" "$W/git_upload.bin" "$2" "$1 upload-pack"
  compare_adv "$W/adv_receive.bin" "$W/git_receive.bin" "$3" "$1 receive-pack"
  # 実 Git の広告を、私たちの pkt-line の復号が受理する（行数が一致する）
  run_driver <<'CMDS'
decode:git_upload
decode:git_receive
decode:adv_upload
decode:adv_receive
CMDS
  local want_up want_rp
  want_up="$(norm "$W/git_upload.bin" | grep -vc '^CAPS ')"
  want_rp="$(norm "$W/git_receive.bin" | grep -vc '^CAPS ')"
  # 先頭行は CAPS と参照行の 2 行に分かれて出るので、行数は参照行数と等しい
  [ "$(sed -n 1p "$W/out.txt")" = "ok:$want_up" ] || { cat "$W/out.txt"; echo "実 Git の upload-pack の広告の行数が復号と違う" >&2; exit 1; }
  [ "$(sed -n 2p "$W/out.txt")" = "ok:$want_rp" ] || { cat "$W/out.txt"; echo "実 Git の receive-pack の広告の行数が復号と違う" >&2; exit 1; }
}

UP_NOSYM="object-format=sha256 side-band-64k"
RP="object-format=sha256 report-status ofs-delta"

# A-1. 空のリポジトリ
"$STAGE5_GIT" init --object-format=sha256 -q -b main "$R"
echo "--- A. 能力広告 ---"
adv_both "空のリポジトリ" "$UP_NOSYM" "$RP"

# 履歴: ブランチ・マージ・軽量タグ・注釈付きタグ・タグのタグ・ディレクトリ・実行ビット
big() { for n in $(seq 1 300); do echo "line $n: the quick brown fox jumps over the lazy dog"; done; }
mkdir -p "$R/dir/sub"
big >"$R/big.txt"
echo hello >"$R/dir/a.txt"
echo deep >"$R/dir/sub/b.txt"
printf '#!/bin/sh\necho hi\n' >"$R/run.sh"; chmod +x "$R/run.sh"
g add -A; tick; g commit -q -m c1
for i in 2 3; do echo "extra $i" >>"$R/big.txt"; g add -A; tick; g commit -q -m "c$i"; done
g tag light
tick; g tag -a -m "annotated" v1
V1="$(g rev-parse refs/tags/v1)"
TAG2="$(printf 'object %s\ntype tag\ntag v2\ntagger T <t@example.com> 1700009999 +0000\n\nnested\n' "$V1" | g mktag)"
g update-ref refs/tags/v2 "$TAG2"
test "$(g cat-file -t refs/tags/v2)" = tag
g checkout -q -b topic
echo topic >"$R/topic.txt"; g add -A; tick; g commit -q -m t1
g checkout -q main
echo main4 >>"$R/big.txt"; g add -A; tick; g commit -q -m c4
tick; g merge -q --no-ff -m "merge topic" topic
g fsck --strict --full

adv_both "ブランチとタグ（loose refs）" "object-format=sha256 symref=HEAD:refs/heads/main side-band-64k" "$RP"
# peeled 行がある: v1 と v2 の両方（v2 は tag の tag なので、再帰的に剥がして commit）。軽量タグには無い
norm "$W/adv_upload.bin" >"$W/up.norm"
grep -q 'refs/tags/v1^{}$' "$W/up.norm" || { cat "$W/up.norm"; echo "peeled 行が無い" >&2; exit 1; }
grep -q 'refs/tags/v2^{}$' "$W/up.norm" || { echo "入れ子のタグの peeled 行が無い" >&2; exit 1; }
if grep -q 'refs/tags/light^{}' "$W/up.norm"; then echo "軽量タグに peeled 行がある" >&2; exit 1; fi
test "$(grep 'refs/tags/v2^{}' "$W/up.norm" | cut -d' ' -f1)" = "$(g rev-parse 'refs/tags/v2^{commit}')"
# receive-pack の広告には HEAD も peeled 行も無い
if norm "$W/adv_receive.bin" | grep -q '\^{}\| HEAD$'; then echo "receive-pack の広告に HEAD か peeled 行がある" >&2; exit 1; fi
echo "  peeled 行: v1・v2（入れ子）にあり、軽量タグと receive-pack には無い"

# packed-refs にした状態でも同じ
g pack-refs --all
test ! -e "$R/.git/refs/heads/main"
adv_both "packed-refs" "object-format=sha256 symref=HEAD:refs/heads/main side-band-64k" "$RP"

# 分離 HEAD: symref を広告しない
g checkout -q --detach main
adv_both "分離 HEAD" "$UP_NOSYM" "$RP"
g checkout -q main

# B. wire 専用 pack
echo "--- B. wire 専用 pack ---"
g cat-file --batch-all-objects --batch-check='%(objectname)' | sort >"$W/all.ids"
N="$(wc -l <"$W/all.ids")"
echo "  リポジトリの全 $N オブジェクト（commit・tree・blob・tag）から pack を作る"
run_driver <<'CMDS'
pack:all
CMDS
cat "$W/out.txt"
grep -q '^ok:[0-9]' "$W/out.txt" || { echo "pack の生成に失敗" >&2; exit 1; }
test -s "$W/all.pack"
test "$(head -c 4 "$W/all.pack")" = PACK

# 構造: 版 2、件数、非 delta（種別 1〜4 だけ）、すべての deflate ブロックが stored、末尾は SHA-256
python3 - "$W/all.pack" "$N" <<'PY'
import hashlib, struct, sys, zlib
data = open(sys.argv[1], 'rb').read()
want = int(sys.argv[2])
assert data[:4] == b'PACK'
ver, count = struct.unpack('>II', data[4:12])
assert ver == 2, ver
assert count == want, (count, want)
assert hashlib.sha256(data[:-32]).digest() == data[-32:], 'trailer'
pos = 12
kinds = {}
for _ in range(count):
    b = data[pos]; pos += 1
    typ = (b >> 4) & 7
    size = b & 15
    shift = 4
    while b & 0x80:
        b = data[pos]; pos += 1
        size |= (b & 0x7f) << shift
        shift += 7
    assert typ in (1, 2, 3, 4), 'delta or invalid type %d' % typ
    kinds[typ] = kinds.get(typ, 0) + 1
    assert data[pos] == 0x78 and data[pos+1] == 0x01, 'zlib header'
    p = pos + 2
    while True:
        h = data[p]
        assert (h >> 1) & 3 == 0, 'not a stored block'
        ln, nln = struct.unpack('<HH', data[p+1:p+5])
        assert ln + nln == 0xffff
        p += 5 + ln
        if h & 1:
            break
    p += 4  # Adler-32
    d = zlib.decompressobj()
    out = d.decompress(data[pos:p])
    assert d.eof and not d.unused_data and len(out) == size, 'zlib stream'
    pos = p
assert pos == len(data) - 32
print('  構造: 版 2、%d 件（commit %d・tree %d・blob %d・tag %d）、非 delta、すべて stored、SHA-256 の検査値が一致' % (count, kinds.get(1, 0), kinds.get(2, 0), kinds.get(3, 0), kinds.get(4, 0)))
PY

# 実 Git が受理する: index-pack --strict と unpack-objects --strict、verify-pack、fsck
F="$W/fresh.git"
"$STAGE5_GIT" init --object-format=sha256 --bare -q "$F"
"$STAGE5_GIT" -C "$F" index-pack --stdin --strict <"$W/all.pack" >/dev/null
IDX="objects/pack/$(basename "$(ls "$F"/objects/pack/pack-*.idx)")"
"$STAGE5_GIT" -C "$F" verify-pack -v "$IDX" >"$W/verify.txt"
grep -q "^non delta: $N objects" "$W/verify.txt" || { cat "$W/verify.txt" | tail -5; echo "非 delta として検証されていない" >&2; exit 1; }
if grep -q 'chain length' "$W/verify.txt"; then echo "delta が含まれている" >&2; exit 1; fi
"$STAGE5_GIT" -C "$F" fsck --strict --full --no-dangling
echo "  index-pack --strict・verify-pack（非 delta $N 件）・fsck --strict が成功"
U="$W/unpacked.git"
"$STAGE5_GIT" init --object-format=sha256 --bare -q "$U"
"$STAGE5_GIT" -C "$U" unpack-objects --strict <"$W/all.pack"
test "$("$STAGE5_GIT" -C "$U" cat-file --batch-all-objects --batch-check='%(objectname)' | sort | cmp - "$W/all.ids" && echo same)" = same
echo "  unpack-objects --strict が成功し、全識別子が一致"

# 型・長さ・内容・識別子が一致する（元のリポジトリと受け取った側を比べる）
while read -r id; do
  ty="$(g cat-file -t "$id")"
  test "$("$STAGE5_GIT" -C "$F" cat-file -t "$id")" = "$ty"
  test "$("$STAGE5_GIT" -C "$F" cat-file -s "$id")" = "$(g cat-file -s "$id")"
  a="$(g cat-file "$ty" "$id" | sha256sum | cut -d' ' -f1)"
  b="$("$STAGE5_GIT" -C "$F" cat-file "$ty" "$id" | sha256sum | cut -d' ' -f1)"
  test "$a" = "$b"
done <"$W/all.ids"
echo "  全 $N オブジェクトの型・長さ・内容が一致"

# 部分集合の pack（渡した識別子の集合だけを送る）。閉じた集合（tree とその blob）は --strict でも通り、重複は除かれる
SUBTREE="$(g rev-parse main:dir/sub)"
SUBBLOB="$(g rev-parse main:dir/sub/b.txt)"
{ echo "$SUBTREE"; echo "$SUBBLOB"; echo "$SUBTREE"; } >"$W/sub.ids"
run_driver <<'CMDS'
pack:sub
CMDS
grep -q '^ok:[0-9]' "$W/out.txt"
S="$W/sub.git"
"$STAGE5_GIT" init --object-format=sha256 --bare -q "$S"
"$STAGE5_GIT" -C "$S" index-pack --stdin --strict <"$W/sub.pack" >/dev/null
test "$("$STAGE5_GIT" -C "$S" cat-file --batch-all-objects --batch-check='%(objectname)' | wc -l)" = 2
# 閉じていない集合（commit・その tree・1 つの blob だけ）は、--strict では実 Git が欠けた参照を理由に拒否し、通常は受理する
TIP="$(g rev-parse main)"
{ echo "$TIP"; g rev-parse "$TIP^{tree}"; g rev-parse "$TIP:big.txt"; } >"$W/open.ids"
run_driver <<'CMDS'
pack:open
CMDS
grep -q '^ok:[0-9]' "$W/out.txt"
O="$W/open.git"
"$STAGE5_GIT" init --object-format=sha256 --bare -q "$O"
if "$STAGE5_GIT" -C "$O" index-pack --stdin --strict <"$W/open.pack" >/dev/null 2>&1; then echo "閉じていない集合が --strict で通った" >&2; exit 1; fi
"$STAGE5_GIT" -C "$O" index-pack --stdin <"$W/open.pack" >/dev/null
test "$("$STAGE5_GIT" -C "$O" cat-file --batch-all-objects --batch-check='%(objectname)' | wc -l)" = 3
echo "  部分集合: 閉じた 2 件（重複を除く）は index-pack --strict が成功。閉じていない 3 件は、渡した集合だけを送る（接続の確認は後段の upload-pack の責務）"

# C. 拒否
echo "--- C. 拒否 ---"
echo "1111111111111111111111111111111111111111111111111111111111111111" >"$W/lost.ids"
run_driver <<'CMDS'
pack:lost
CMDS
grep -qx 'error:NotFound' "$W/out.txt"
test ! -e "$W/lost.pack"
python3 -c "print('\n'.join(['$(head -1 "$W/all.ids")'] * 4097))" >"$W/many.ids"
run_driver <<'CMDS'
pack:many
CMDS
grep -qx 'error:LimitExceeded' "$W/out.txt"
test ! -e "$W/many.pack"
python3 -c "print('\n'.join(['$(head -1 "$W/all.ids")'] * 4096))" >"$W/edge.ids"
run_driver <<'CMDS'
pack:edge
CMDS
grep -q '^ok:[0-9]' "$W/out.txt"
echo "  存在しないオブジェクトとオブジェクト数 4097 は pack を作らずに失敗し、4096 は成功"

echo "=== interop_transfer OK ==="
