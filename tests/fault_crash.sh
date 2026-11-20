#!/usr/bin/env bash
# ステップ単位のプロセス強制終了と電源断の模擬（ADR 0047 決定 6-5、Issue #634 の (b)(c)）。
#
# interop_ops の各操作（add・commit・checkout・参照の作成・参照の削除）が行う「ファイルシステムを変える syscall」
# （一時ファイルの作成・書き込み・同期・rename・親ディレクトリの同期・ロックの解放など）に通し番号を付け
# （tests/faultinject.c が ptrace で数える）、全ステップについて次を行う。
#   1. そのステップの実行前（kill-before）と直後（kill-after）に SIGKILL する。決定論的で、sleep は使わない。
#   2. 強制終了した状態で、不変条件を実 Git で確かめる:
#        (b) 応答済みの commit が参照から到達できる、(c) git fsck --strict --full が通り参照先が欠けない、
#        (d) 追跡されていない未保存のファイルや作業木の変更が失われない、索引を実 Git が読める、
#        参照・索引は変更前か変更後のどちらか（途中の状態を見せない）。
#   3. 電源断の模擬: その時点で「同期されていないデータ」を捨てた状態（最後に fsync された長さまで切り詰める）でも
#        同じ不変条件が成り立つ。fsync を省くと壊れたオブジェクトや参照が現れる（変異試験が検出する）。
#   4. 回復: 残ったロックと一時ファイルを消して同じ操作をやり直し、完了できる（checkout は Conflict もあり得る。
#        その場合は実 Git の checkout -f で直せる）。
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/fault_lib.sh"
fl_init crash

total_runs=0
total_steps=0

for FL_SCEN in $SCENARIOS; do
  echo "--- シナリオ $FL_SCEN: ステップの列挙 ---"
  FL_LABEL="$FL_SCEN/prefix-states"
  collect_prefix_states
  FL_LABEL="$FL_SCEN/baseline"
  fl_new_case "$FL_SCEN"
  fl_run -m count -l "$FW/steps.$FL_SCEN.txt" -d "$FW/dur.$FL_SCEN.txt"
  [ "$FL_RC" = 0 ] || fl_fail "baseline の終了コードが $FL_RC"
  grep -q '^error:' "$LOGD/stdout.txt" && fl_fail "baseline が失敗: $(cat "$LOGD/stdout.txt")"
  IDX_AFTER="$(fl_sig_index)"
  TREE_AFTER="$(g rev-parse 'HEAD^{tree}')"
  FL_LABEL="$FL_SCEN/baseline-invariants"
  fl_check_invariants "完了後"
  N="$(grep -c '^[0-9]' "$FW/steps.$FL_SCEN.txt")"
  [ "$N" -gt 0 ] || fl_fail "ステップが 1 つも数えられない"
  echo "    ステップ数: $N（$(cut -f2 "$FW/steps.$FL_SCEN.txt" | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}')）"
  total_steps=$((total_steps + N))

  # 完了後の電源断（最後のステップのあと）
  FL_LABEL="$FL_SCEN/powerloss-after-completion"
  fl_powerloss "$FW/dur.$FL_SCEN.txt"
  fl_check_invariants "完了後の電源断"

  # 変異試験（tests/mutation）は、同期の省略を電源断の模擬だけで検出するので、全ステップの強制終了は飛ばせる。
  [ -z "${FAULT_POWERLOSS_ONLY:-}" ] || continue

  for MODE in kill-before kill-after; do
    echo "--- シナリオ $FL_SCEN: $MODE を全 $N ステップで ---"
    i=1
    while [ "$i" -le "$N" ]; do
      stepline="$(sed -n "${i}p" "$FW/steps.$FL_SCEN.txt" | cut -f2,3 | tr '\t' ' ' | sed "s|$FW/||" | cut -c1-110)"
      FL_LABEL="$FL_SCEN $MODE step $i/$N ($stepline)"
      fl_new_case "$FL_SCEN"
      DUR="$CASE/dur.txt"
      fl_run -m "$MODE" -n "$i" -d "$DUR"
      [ "$FL_RC" = 137 ] || fl_fail "SIGKILL で止まらなかった（終了コード $FL_RC）。ステップ番号が決定論的でない"
      # 強制終了した状態（OS のキャッシュは残る）
      fl_check_invariants "強制終了後"
      check_atomic "強制終了後"
      [ "$FL_SCEN" != checkout ] || fl_check_worktree_files "強制終了後"
      # 電源断の模擬（コピーに対して、未同期のデータを捨てる）
      ORIG_CASE="$CASE"
      CASE2="$FW/cases/pl.$FL_SEQ"
      rm -rf "$CASE2"
      cp -a "$CASE" "$CASE2"
      sed "s|$ORIG_CASE|$CASE2|" "$DUR" >"$CASE2/dur.txt"
      CASE="$CASE2"
      LOGD="$CASE2"
      REPO="$CASE/tmp/interop_ops/repo"
      fl_powerloss "$CASE/dur.txt"
      FL_LABEL="$FL_LABEL + 電源断"
      fl_check_invariants "電源断後"
      check_atomic "電源断後"
      CASE="$ORIG_CASE"
      LOGD="$ORIG_CASE"
      REPO="$CASE/tmp/interop_ops/repo"
      rm -rf "$CASE2"
      FL_LABEL="$FL_SCEN $MODE step $i/$N ($stepline) + 回復"
      recover_and_check "回復"
      total_runs=$((total_runs + 1))
      rm -rf "$CASE"
      i=$((i + 1))
    done
  done
done

echo "強制終了のあとに作業木へ残った一時ファイル（.sigil-tmp-*）を掃除した回数: ${FL_STALE_TMP:-0}"
echo "強制終了 ${total_runs} 回（各ステップの前後）、列挙したステップ ${total_steps} 件"
echo "=== ステップ単位の強制終了・電源断の模擬: 全ケース合格 ==="
