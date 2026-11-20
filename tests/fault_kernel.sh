#!/usr/bin/env bash
# カーネルが返すエラーを注入する試験（ADR 0047 決定 6-5、Issue #634 の (a)）。
#
# 1. システムコール単位の注入（tests/faultinject.c が ptrace で、ファイルシステムを変える syscall に通し番号を付けて、
#    N 番目で失敗させる。カーネルがその errno を返したのと同じに見える）。各操作の全ステップについて:
#      - EIO（その 1 回だけ失敗。同期の失敗も含む）
#      - ENOSPC（そのステップ以降ずっと失敗 = ディスクが満杯になった）
#      - short write（そのステップの write を 1 byte / 半分に縮める。カーネルが本当に短く書いて短い戻り値を返す。
#        正しいプログラムは残りを書き続けるので、結果は注入なしと同一でなければならない）
# 2. 本物の ENOSPC: 容量を絞った tmpfs の上で commit し、容量をいろいろに変えて、カーネル自身が返す ENOSPC を
#    さまざまな位置で受ける。失敗後に容量を増やして同じ操作をやり直せることも確かめる。
# 各ケースで、実 Git の git fsck --strict --full、応答済み commit の到達可能性、参照先オブジェクトの欠落なし、
# 未保存の変更の保持、参照・索引が途中の状態でないこと、異常終了（パニック）でないことを確かめる。
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/fault_lib.sh"
fl_init kernel

# --- 1. システムコール単位の注入 ---
declare -A COUNT_FAULTS
COUNT_FAULTS=([eio]=0 [enospc]=0 [short]=0)
SILENT_OK=0       # 失敗を注入したのに、エラーを返さず ok で終わった件数（報告用）
SILENT_LIST=""

for FL_SCEN in $SCENARIOS; do
  echo "--- シナリオ $FL_SCEN ---"
  FL_LABEL="$FL_SCEN/prefix-states"
  collect_prefix_states
  FL_LABEL="$FL_SCEN/baseline"
  fl_new_case "$FL_SCEN"
  fl_run -m count -l "$FW/steps.$FL_SCEN.txt"
  [ "$FL_RC" = 0 ] || fl_fail "baseline の終了コードが $FL_RC"
  grep -q '^error:' "$LOGD/stdout.txt" && fl_fail "baseline が失敗: $(cat "$LOGD/stdout.txt")"
  BASE_OUT="$(cat "$LOGD/stdout.txt")"
  BASE_HEAD="$(fl_sig_head)"
  BASE_IDX="$(fl_sig_index)"
  IDX_AFTER="$BASE_IDX"
  TREE_AFTER="$(g rev-parse 'HEAD^{tree}')"
  N="$(grep -c '^[0-9]' "$FW/steps.$FL_SCEN.txt")"
  echo "    ステップ数: $N"

  i=1
  while [ "$i" -le "$N" ]; do
    stepline="$(sed -n "${i}p" "$FW/steps.$FL_SCEN.txt" | cut -f2,3 | tr '\t' ' ' | sed "s|$FW/||" | cut -c1-100)"
    stepname="$(sed -n "${i}p" "$FW/steps.$FL_SCEN.txt" | cut -f2)"

    # EIO（1 回）と ENOSPC（以降ずっと）
    for kind in eio enospc; do
      FL_LABEL="$FL_SCEN $kind step $i/$N ($stepline)"
      fl_new_case "$FL_SCEN"
      if [ "$kind" = eio ]; then fl_run -m error -n "$i" -e EIO; else fl_run -m error -n "$i" -e ENOSPC -s; fi
      fl_check_exit "注入後"
      fl_check_invariants "注入後"
      check_atomic "注入後"
      [ "$FL_SCEN" != checkout ] || fl_check_worktree_files "注入後"
      if ! grep -q '^error:' "$LOGD/stdout.txt"; then
        SILENT_OK=$((SILENT_OK + 1))
        SILENT_LIST="$SILENT_LIST\n  $FL_SCEN $kind step $i ($stepline)"
      fi
      # 回復: 失敗は一時的なので、掃除してやり直せば完了する
      recover_and_check "回復"
      COUNT_FAULTS[$kind]=$(( ${COUNT_FAULTS[$kind]} + 1 ))
      rm -rf "$CASE"
    done

    # short write（write のステップだけ）
    if [ "$stepname" = write ] || [ "$stepname" = pwrite ]; then
      for b in 1 2; do
        FL_LABEL="$FL_SCEN short-write($b) step $i/$N ($stepline)"
        fl_new_case "$FL_SCEN"
        len="$(sed -n "${i}p" "$FW/steps.$FL_SCEN.txt" | sed -n 's/.*len=\([0-9]*\)$/\1/p')"
        bytes=1
        [ "$b" = 2 ] && bytes=$(( len / 2 > 0 ? len / 2 : 1 ))
        fl_run -m short -n "$i" -b "$bytes" -l "$FW/short.log"
        grep -q 'shortened' "$FW/short.log" || { rm -rf "$CASE"; continue; }   # 縮める余地がない（長さ 1 以下）
        [ "$FL_RC" = 0 ] || fl_fail "short write で終了コードが $FL_RC"
        [ "$(cat "$LOGD/stdout.txt")" = "$BASE_OUT" ] || fl_fail "short write で結果が注入なしと違う: $(cat "$LOGD/stdout.txt")"
        fl_check_invariants "short write 後"
        [ "$(fl_sig_head)" = "$BASE_HEAD" ] || fl_fail "short write で参照が注入なしと違う"
        [ "$(fl_sig_index)" = "$BASE_IDX" ] || fl_fail "short write で索引が注入なしと違う"
        COUNT_FAULTS[short]=$(( ${COUNT_FAULTS[short]} + 1 ))
        rm -rf "$CASE"
      done
    fi
    i=$((i + 1))
  done
done
echo "注入した件数: EIO=${COUNT_FAULTS[eio]} ENOSPC=${COUNT_FAULTS[enospc]} short write=${COUNT_FAULTS[short]}"
if [ "$SILENT_OK" -gt 0 ]; then
  echo "注意: 失敗を注入したのにエラーを返さなかった件数: $SILENT_OK（後始末の失敗など、結果に影響しない最終の手順）"
  printf '%b\n' "$SILENT_LIST" | sed -n '1,40p'
fi

# --- 2. 本物の ENOSPC（容量を絞った tmpfs） ---
echo "--- 本物の ENOSPC: 容量を絞った tmpfs ---"
fl_mount() { # fl_mount SIZE DIR
  if [ "$(id -u)" = 0 ]; then mount -t tmpfs -o "size=$1" tmpfs "$2"
  else sudo -n mount -t tmpfs -o "size=$1" tmpfs "$2"; fi
}
fl_remount() {
  if [ "$(id -u)" = 0 ]; then mount -o "remount,size=$1" tmpfs "$2"
  else sudo -n mount -o "remount,size=$1" tmpfs "$2"; fi
}
fl_umount() {
  if [ "$(id -u)" = 0 ]; then umount "$1"; else sudo -n umount "$1"; fi
}
MNT="$FW/mnt"
mkdir -p "$MNT"
if ! fl_mount 1m "$MNT" 2>/dev/null; then
  if [ "${FAULT_ALLOW_NO_MOUNT:-}" = 1 ]; then
    echo "警告: tmpfs をマウントできないため、本物の ENOSPC の試験を飛ばします（FAULT_ALLOW_NO_MOUNT=1）" >&2
    echo "=== カーネルエラー注入: システムコール単位は全ケース合格（tmpfs は未実施） ==="
    exit 0
  fi
  fl_die "tmpfs をマウントできません（root または sudo -n が必要）。飛ばすなら FAULT_ALLOW_NO_MOUNT=1"
fi
fl_umount "$MNT"

FL_SCEN=commit_big
# 準備のあと（big.bin を置いたあと）の使用量を、十分大きな tmpfs で一度測る。
fl_mount 8m "$MNT"
CASE="$MNT/case"; mkdir -p "$CASE"
cp -a "$FW/base/." "$CASE/"
fl_prepare "$CASE" commit_big
sync
used_kb="$(df -k "$MNT" | awk 'NR==2 {print $3}')"
fl_umount "$MNT"
hit=0; ok_runs=0; runs=0
# 使用量に足す余裕を変えて、ENOSPC がさまざまな位置で起きるようにする（小さすぎると準備自体が入らない）
for extra in $(seq 0 4 160); do
  size_kb=$(( used_kb + extra ))
  FL_LABEL="tmpfs ENOSPC size=${size_kb}k (余裕 ${extra}k)"
  fl_mount "${size_kb}k" "$MNT"
  CASE="$MNT/case"
  mkdir -p "$CASE"
  LOGD="$FW/log_tmpfs"
  rm -rf "$LOGD"; mkdir -p "$LOGD"
  cp -a "$FW/base/." "$CASE/"
  REPO="$CASE/tmp/interop_ops/repo"
  fl_prepare "$CASE" commit_big 2>/dev/null || true
  { echo failfast; fl_cmds commit_big; } >"$CASE/tmp/interop_ops/cmds.txt" 2>/dev/null || true
  [ -s "$CASE/tmp/interop_ops/cmds.txt" ] || { fl_umount "$MNT"; continue; }
  [ "$(wc -c <"$REPO/big.bin")" = 40000 ] || { fl_umount "$MNT"; continue; }
  fl_run -m count
  fl_check_exit "tmpfs ENOSPC"
  fl_check_invariants "tmpfs ENOSPC 後"
  runs=$((runs + 1))
  if grep -q '^error:' "$LOGD/stdout.txt"; then
    hit=$((hit + 1))
    # 容量を増やしてやり直せる
    fl_remount "$(( size_kb + 4096 ))k" "$MNT"
    fl_cleanup_stale
    fl_run -m count
    grep -q '^error:' "$LOGD/stdout.txt" && fl_fail "容量を増やしてもやり直せない: $(cat "$LOGD/stdout.txt")"
    fl_check_invariants "容量を増やして完了後"
    g cat-file -p HEAD:big.bin >/dev/null 2>&1 || fl_fail "やり直した commit に big.bin が無い"
  else
    ok_runs=$((ok_runs + 1))
  fi
  fl_umount "$MNT"
done
[ "$hit" -gt 0 ] || fl_die "どの容量でも ENOSPC に当たらなかった（試験が効いていない）"
[ "$ok_runs" -gt 0 ] || fl_die "どの容量でも成功しなかった（容量の範囲が小さすぎる）"
echo "tmpfs: ${runs} 通りの容量、ENOSPC に当たった ${hit} 件（すべて fsck 成功・やり直し成功）、成功 ${ok_runs} 件"
echo "=== カーネルエラー注入（EIO・ENOSPC・short write・本物の ENOSPC）: 全ケース合格 ==="
