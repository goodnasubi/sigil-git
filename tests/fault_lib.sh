#!/usr/bin/env bash
# 障害注入試験（fault_kernel.sh・fault_crash.sh）の共通部分。source して使う。
# 前提: Linux x86_64、gcc、ptrace が使えること。使えなければ失敗する（黙って飛ばさない）。
# 環境変数: SIGIL（コンパイラ）、STAGE5_GIT（実 Git）、OPS_BIN（試験の対象にする interop_ops のバイナリ。
#   省略時は interop_ops.sigil をビルドする。変異試験が変異を入れたバイナリを渡すために使う）

# 環境や準備の不備（試験が走らせられない）。終了コード 2。試験が不変条件の違反を見つけたとき（fl_fail、終了コード 1）と区別する。
fl_die() {
  echo "ERROR: $*" >&2
  exit 2
}

fl_init() {
  : "${SIGIL:=sigil}"
  GIT="${STAGE5_GIT:-git}"
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  cd "$ROOT"
  [ "$(uname -s)" = "Linux" ] && [ "$(uname -m)" = "x86_64" ] || fl_die "この試験は Linux x86_64 専用です（ptrace を使う）"
  command -v gcc >/dev/null 2>&1 || fl_die "gcc がありません（tests/faultinject.c のビルドに必要）"
  FW="${FAULT_WORK:-$ROOT/tmp/fault_work_$1}"
  rm -rf "$FW"
  mkdir -p "$FW"
  [ -n "${KEEP:-}" ] || trap 'rm -rf "$FW"' EXIT
  export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_OPTIONAL_LOCKS=0
  echo "Git version: $("$GIT" --version)"
  "$GIT" init --object-format=sha256 --bare -q "$FW/probe.git" || fl_die "この Git は SHA-256 に対応していません"
  gcc -O2 -Wall -Wextra -o "$FW/faultinject" tests/faultinject.c || fl_die "faultinject.c をビルドできません"
  FI="$FW/faultinject"
  # ptrace が使えるか（使えない環境で黙って通ってしまわないように、先に確かめる）
  "$FI" -m count -l "$FW/probe.log" -- true || fl_die "ptrace が使えません（コンテナの seccomp 等）。この試験は ptrace を要します"
  if [ -n "${OPS_BIN:-}" ]; then
    cp "$OPS_BIN" "$FW/ops_bin"
  else
    $SIGIL build --root . interop_ops.sigil main -o "$FW/ops_bin" || fl_die "interop_ops.sigil をビルドできません"
  fi
  OPS="$FW/ops_bin"
  fl_make_base
  fl_scenarios
}

# 実 Git で土台のリポジトリを作る。main（base）と feature（a.txt を変更・keep.txt を削除・n/new.txt を追加・
# dir/run.sh の実行ビットを外す）、追跡されていない unsaved.txt、作業木の未保存の変更を用意する。
fl_make_base() {
  local b="$FW/base/tmp/interop_ops/repo"
  mkdir -p "$FW/base/tmp/interop_ops"
  "$GIT" init --object-format=sha256 -q -b main "$b"
  (
    cd "$b"
    mkdir -p dir
    printf 'alpha\n' >a.txt
    printf 'keep\n' >keep.txt
    printf 'bravo\n' >dir/b.txt
    printf '#!/bin/sh\necho hi\n' >dir/run.sh
    chmod 755 dir/run.sh
    "$GIT" add -A
    GIT_AUTHOR_DATE="1700000000 +0000" GIT_COMMITTER_DATE="1700000000 +0000" "$GIT" commit -q -m base
    "$GIT" checkout -q -b feature
    printf 'alpha2\n' >a.txt
    "$GIT" rm -q keep.txt
    mkdir -p n
    printf 'new\n' >n/new.txt
    chmod 644 dir/run.sh
    "$GIT" add -A
    GIT_AUTHOR_DATE="1700000100 +0000" GIT_COMMITTER_DATE="1700000100 +0000" "$GIT" commit -q -m feature
    "$GIT" checkout -q main
    printf 'unsaved work\n' >unsaved.txt
  )
  UNSAVED="unsaved work"
  # packed 版（delete_branch 用）
  cp -a "$FW/base" "$FW/base_packed"
  "$GIT" -C "$FW/base_packed/tmp/interop_ops/repo" pack-refs --all
}

# シナリオ: 名前ごとに、使う土台・準備・コマンド・期待を決める。
fl_scenarios() {
  SCENARIOS="add commit checkout delete_branch create_branch"
}

fl_base_of() {
  case "$1" in
    delete_branch) echo "$FW/base_packed" ;;
    *) echo "$FW/base" ;;
  esac
}

# 準備（作業木の変更）。ケースのディレクトリ $1 を受け取る。
fl_prepare() {
  local c="$1/tmp/interop_ops/repo"
  case "$2" in
    add)
      printf 'staged new\n' >"$c/n1.txt"
      printf 'alpha edited\n' >"$c/a.txt"
      ;;
    commit_big)
      head -c 40000 /dev/urandom >"$c/big.bin"
      printf 'alpha edited\n' >"$c/a.txt"
      ;;
    commit)
      printf 'staged new\n' >"$c/n1.txt"
      printf 'alpha edited\n' >"$c/a.txt"
      ;;
    *) : ;;
  esac
}

fl_cmds() {
  case "$1" in
    add) printf 'add:n1.txt\nadd:a.txt\n' ;;
    commit) printf 'add:n1.txt\nadd:a.txt\ncommit:second\n' ;;
    commit_big) printf 'add:big.bin\nadd:a.txt\ncommit:big\n' ;;
    checkout) printf 'checkout:feature\n' ;;
    delete_branch) printf 'delete_branch:feature\n' ;;
    create_branch) printf 'branch:newb\n' ;;
  esac
}

# 新しいケースのディレクトリを作る（土台のコピー + 準備 + コマンドファイル）。名前は CASE に入る。
fl_new_case() {
  local scen="$1"
  FL_SEQ=$(( ${FL_SEQ:-0} + 1 ))
  CASE="$FW/cases/$scen.$FL_SEQ"
  rm -rf "$CASE"
  mkdir -p "$CASE"
  cp -a "$(fl_base_of "$scen")/." "$CASE/"
  fl_prepare "$CASE" "$scen"
  { echo failfast; fl_cmds "$scen"; } >"$CASE/tmp/interop_ops/cmds.txt"
  REPO="$CASE/tmp/interop_ops/repo"
  LOGD="$CASE"
}

g() { "$GIT" -C "$REPO" "$@"; }

# 状態の署名（HEAD の向き・参照・索引）。
fl_sig() {
  {
    g symbolic-ref -q HEAD || echo detached
    g for-each-ref --format='%(refname) %(objectname)'
    echo "--index"
    g ls-files -s
  } 2>&1
}
fl_sig_head() { { g symbolic-ref -q HEAD || echo detached; g for-each-ref --format='%(refname) %(objectname)'; } 2>&1; }
fl_sig_index() { g ls-files -s 2>&1; }

# 計装つきで interop_ops を走らせる。引数は faultinject へ。標準出力は $LOGD/stdout.txt、終了コードは FL_RC。
fl_run() {
  FL_RC=0
  (cd "$CASE" && timeout 120 "$FI" "$@" -- "$OPS" >"$LOGD/stdout.raw" 2>"$LOGD/stderr.txt") || FL_RC=$?
  # 末尾の戻り値の行（0 / 1）を除く
  sed '${/^[01]$/d}' "$LOGD/stdout.raw" >"$LOGD/stdout.txt"
}

# 失敗した位置の情報（再現手順になる）を付けて失敗する。
fl_fail() {
  echo "FAIL [$FL_LABEL]: $*" >&2
  echo "  再現: KEEP=1 で実行し、ケース $CASE を調べる" >&2
  [ -f "$LOGD/fsck.txt" ] && sed 's/^/  fsck: /' "$LOGD/fsck.txt" | head -8 >&2
  exit 1
}

# 不変条件（ADR 0047 決定 6-5）: (b) 応答済みの commit が参照から到達できる、(c) 参照先のオブジェクトが欠けず
# git fsck --strict --full が通る、(d) ユーザーの未保存の変更が失われない。加えて索引が実 Git に読める。
fl_check_invariants() {
  local what="$1"
  g fsck --strict --full >"$LOGD/fsck.txt" 2>&1 || fl_fail "$what: git fsck --strict --full が失敗"
  g rev-parse --verify -q 'HEAD^{commit}' >/dev/null 2>&1 || fl_fail "$what: HEAD が commit を指さない"
  g ls-files -s >/dev/null 2>"$LOGD/ls.txt" || fl_fail "$what: 索引を実 Git が読めない"
  [ "$(cat "$REPO/unsaved.txt" 2>/dev/null)" = "$UNSAVED" ] || fl_fail "$what: 追跡されていない未保存のファイルが変わった"
  # 応答済み（標準出力に ok:<64 桁>）の commit は、HEAD から到達できる
  local l id
  while IFS= read -r l; do
    if [[ "$l" =~ ^ok:([0-9a-f]{64})$ ]]; then
      id="${BASH_REMATCH[1]}"
      g cat-file -e "$id^{commit}" 2>/dev/null || fl_fail "$what: 応答済みの commit $id が無い"
      case "$FL_SCEN" in
        commit|commit_big|checkout)
          g merge-base --is-ancestor "$id" HEAD 2>/dev/null || fl_fail "$what: 応答済みの commit $id が HEAD から到達できない"
          ;;
      esac
    fi
  done <"$LOGD/stdout.txt"
  # 参照が指すものがすべて実在する（fsck が見るが、念のため明示）
  while read -r ref obj; do
    g cat-file -e "$obj" 2>/dev/null || fl_fail "$what: 参照 $ref の先 $obj が無い"
  done < <(g for-each-ref --format='%(refname) %(objectname)')
}

# 作業木の追跡ファイルが、古い内容か新しい内容のどちらかで（途中の内容ではなく）ある。
fl_check_worktree_files() {
  local what="$1" p old new cur
  for p in a.txt keep.txt dir/b.txt dir/run.sh n/new.txt; do
    old="$(g cat-file -p "main:$p" 2>/dev/null || echo __absent__)"
    new="$(g cat-file -p "feature:$p" 2>/dev/null || echo __absent__)"
    if [ -e "$REPO/$p" ]; then cur="$(cat "$REPO/$p")"; else cur="__absent__"; fi
    if [ "$cur" != "$old" ] && [ "$cur" != "$new" ]; then
      fl_fail "$what: $p の内容が古い版でも新しい版でもない（'$cur'）"
    fi
  done
}

# 異常終了（パニックなど）でないこと。0 と 1 以外の終了コードは異常（強制終了を除く）。
fl_check_exit() {
  local what="$1"
  case "$FL_RC" in
    0|1) ;;
    *) fl_fail "$what: 異常終了（終了コード $FL_RC）: $(head -c 300 "$LOGD/stderr.txt")" ;;
  esac
}

# 強制終了や失敗のあとの掃除（人間が行う手順に相当）: 残った *.lock・一時ファイルを消す。
fl_cleanup_stale() {
  find "$REPO/.git" \( -name '*.lock' -o -name 'tmp_obj_*' -o -name '*.tmp-*' \) -type f -delete 2>/dev/null || true
  local n
  n="$(find "$REPO" -name '.sigil-tmp-*' -type f -not -path "$REPO/.git/*" -print -delete 2>/dev/null | wc -l)"
  FL_STALE_TMP=$(( ${FL_STALE_TMP:-0} + n ))
}

# 電源断の模擬: faultinject の -d が書いた「未同期のデータを持つファイル」を、最後に同期された長さまで切り詰める。
# （ディレクトリエントリの永続性までは模擬しない。ファイルの内容の永続性だけを見る。）
fl_powerloss() {
  local dur="$1" len path n=0
  [ -f "$dur" ] || return 0
  while IFS=$'\t' read -r len path; do
    [ -n "$path" ] || continue
    # 同期済みの長さより長いときだけ切り詰める（短いファイルを 0 埋めで伸ばさない）
    if [ -f "$path" ] && [ "$(stat -c %s "$path")" -gt "$len" ]; then
      truncate -s "$len" "$path"
      n=$((n + 1))
    fi
  done <"$dur"
  FL_LOST=$n
}

# 署名のハッシュ（複数行の署名を 1 行で比べる）。
sh_of() { sha256sum | cut -d' ' -f1; }

# コマンドの接頭辞（先頭の k 個）だけを実行したときの、参照と索引の署名のハッシュを集める。
# 強制終了後の状態は、これらのどれかでなければならない（途中の状態を見せない）。
collect_prefix_states() {
  local k nlines
  nlines="$(fl_cmds "$FL_SCEN" | wc -l)"
  HEAD_SET=""
  IDX_SET=""
  for k in $(seq 0 "$nlines"); do
    fl_new_case "$FL_SCEN"
    if [ "$k" -gt 0 ]; then
      { echo failfast; fl_cmds "$FL_SCEN" | head -n "$k"; } >"$CASE/tmp/interop_ops/cmds.txt"
      fl_run -m count
      [ "$FL_RC" = 0 ] || fl_fail "接頭辞 $k の実行が失敗"
      grep -q '^error:' "$LOGD/stdout.txt" && fl_fail "接頭辞 $k の実行が失敗: $(cat "$LOGD/stdout.txt")"
    fi
    HEAD_SET="$HEAD_SET $(fl_sig_head | sh_of)"
    IDX_SET="$IDX_SET $(fl_sig_index | sh_of)"
    if [ "$k" = 0 ]; then HEAD_BEFORE_H="$(fl_sig_head | sh_of)"; fi
    IDX_FINAL_H="$(fl_sig_index | sh_of)"
    rm -rf "$CASE"
  done
}

# 参照・HEAD は変更前か変更後、索引は途中のどれか。HEAD・参照が変更後なら索引は最終の状態（索引を先に公開する）。
check_atomic() {
  local what="$1" hh ih
  hh="$(fl_sig_head | sh_of)"
  ih="$(fl_sig_index | sh_of)"
  case " $HEAD_SET " in *" $hh "*) ;; *) fl_fail "$what: 参照・HEAD が既知のどの状態でもない（途中の状態が見える）: $(fl_sig_head | tr '\n' ' ')" ;; esac
  case " $IDX_SET " in *" $ih "*) ;; *) fl_fail "$what: 索引が既知のどの状態でもない（途中の状態が見える）" ;; esac
  if [ "$hh" != "$HEAD_BEFORE_H" ] && [ "$ih" != "$IDX_FINAL_H" ]; then
    fl_fail "$what: HEAD・参照が変更後なのに、索引が最終の状態でない"
  fi
}

# 強制終了後の回復。
recover_and_check() {
  local what="$1"
  fl_cleanup_stale
  fl_run -m count
  fl_check_exit "$what（回復）"
  case "$FL_SCEN" in
    add)
      grep -q '^error:' "$LOGD/stdout.txt" && fl_fail "$what: 回復の add が失敗: $(cat "$LOGD/stdout.txt")"
      [ "$(fl_sig_index)" = "$IDX_AFTER" ] || fl_fail "$what: 回復後の索引が期待と違う"
      ;;
    commit|commit_big)
      grep -q '^error:' "$LOGD/stdout.txt" && fl_fail "$what: 回復の commit が失敗: $(cat "$LOGD/stdout.txt")"
      [ "$(g rev-parse 'HEAD^{tree}')" = "$TREE_AFTER" ] || fl_fail "$what: 回復後の tree が期待と違う"
      ;;
    checkout)
      if grep -q '^error:' "$LOGD/stdout.txt"; then
        grep -qx 'error:Conflict' "$LOGD/stdout.txt" || fl_fail "$what: 回復の checkout が Conflict 以外で失敗: $(cat "$LOGD/stdout.txt")"
        g checkout -q -f feature || fl_fail "$what: 実 Git の checkout -f でも直せない"
      fi
      [ "$(g symbolic-ref HEAD)" = "refs/heads/feature" ] || fl_fail "$what: 回復後に HEAD が feature でない"
      [ "$(g status --porcelain)" = "?? unsaved.txt" ] || fl_fail "$what: 回復後の status が clean でない: $(g status --porcelain | tr '\n' ' ')"
      ;;
    delete_branch)
      if grep -q '^error:' "$LOGD/stdout.txt"; then
        grep -qx 'error:NotFound' "$LOGD/stdout.txt" || fl_fail "$what: 回復の delete が NotFound 以外で失敗: $(cat "$LOGD/stdout.txt")"
      fi
      ! g rev-parse -q --verify refs/heads/feature >/dev/null || fl_fail "$what: 削除した参照が復活した"
      ;;
    create_branch)
      if grep -q '^error:' "$LOGD/stdout.txt"; then
        # 参照が既にある（ExpectOld.Absent の比較交換が失敗する）のは正しい動き
        grep -qx 'error:RefMismatch' "$LOGD/stdout.txt" || fl_fail "$what: 回復の branch が RefMismatch 以外で失敗: $(cat "$LOGD/stdout.txt")"
      fi
      g rev-parse -q --verify refs/heads/newb >/dev/null || fl_fail "$what: 回復後に newb が無い"
      ;;
  esac
  g fsck --strict --full >"$LOGD/fsck.txt" 2>&1 || fl_fail "$what: 回復後の fsck が失敗"
}

