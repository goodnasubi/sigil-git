#!/usr/bin/env python3
# ADR 0047 決定 6 変異試験（意図した誤りが検出されるかの測定）。
# 6 つの変異（識別子の検証省略、オブジェクト未同期、参照・索引の未同期、ロック無視、パス検査省略、symlink検査省略）を
# 1 つずつ埋め、試験群が落ちることを確かめる。試験群は Sigil の入口（mutation_runner.sigil）と、
# 電源断の模擬（tests/fault_crash.sh）のようなスクリプトの 2 種類。
# 検出（DETECTED）であることを確認する。許可リスト（ALLOWED_UNDETECTED）は空で、未検出（UNDETECTED）または
# ビルド失敗（BUILD_ERROR）があれば終了コード 1。

import os
import shutil
import subprocess
import sys
import tempfile
import time

# 許可された未検出は無い。object_sync_omitted は、電源断の模擬（tests/fault_crash.sh）で検出できるようになった（Issue #634 (c)）。
ALLOWED_UNDETECTED = set()
M = []
# スクリプトの入口: 変異を入れたソースから interop_ops をビルドし、電源断の模擬だけを走らせる（速い）。
SCRIPT_POWERLOSS = ("script", "tests/fault_crash.sh", {"FAULT_POWERLOSS_ONLY": "1"})

def mut(name, desc, path, old, new, entries):
    M.append(dict(name=name, desc=desc, path=path, old=old, new=new, entries=entries))

# 1. 識別子の検証の省略
mut(
    "id_verification_omitted",
    "オブジェクト読み取り時にハッシュの再計算・照合を省略する",
    "git/object.sigil",
    "if !ct_eq(&actual_id, &expected_id) {",
    "if false && !ct_eq(&actual_id, &expected_id) {",
    ["object", "compat", "fuzz"],
)

# 2. 参照の更新前にオブジェクトを同期しない
mut(
    "object_sync_omitted",
    "オブジェクトファイル書き込み時の fsync (sync_all) 呼び出しを完全に省略する",
    "git/fsio.sigil",
    '      match file.sync_all() {\n        Err(_) => {\n          let _ = file.close();\n          return Err(GitError.Io("failed to sync file"));\n        }\n        Ok(_) => {}\n      }',
    '      // sync_all call omitted',
    # 同一プロセス・OS のページキャッシュのままでは検出できない（直後の読み取りがキャッシュから返る）ので、
    # 未同期のデータを捨てる電源断の模擬（空になったオブジェクトを git fsck が報告する）で検出する。
    ["fault", SCRIPT_POWERLOSS],
)

# 2b. 参照・索引の公開（lock_publish）で内容を同期しない
mut(
    "publish_sync_omitted",
    "参照・索引を公開する書き込み（lock_publish）で fsync (sync_all) を省略する",
    "git/fsio.sigil",
    '  match file.sync_all() {\n    Err(_) => {\n      let _ = file.close();\n      return Err(GitError.Io("failed to sync lock file"));\n    }\n    Ok(_) => {}\n  }',
    '  // sync_all call omitted',
    [SCRIPT_POWERLOSS],
)

# 3. ロックの無視
mut(
    "lock_ignored",
    "ロックファイルが存在しても排他作成せず上書きする",
    "git/fsio.sigil",
    "pub fn lock_create(path: &String) -> Result<File, GitError>\n  intent \"ロックファイル path を排他的に作成して開く。既にあれば Locked（古いロックは自動では消さない）\"\n  requires none\n  ensures none\n  effects fs\n{\n  let opts = fs.open_options().write(true).create_new(true);",
    "pub fn lock_create(path: &String) -> Result<File, GitError>\n  intent \"ロックファイル path を排他的に作成して開く。既にあれば Locked（古いロックは自動では消さない）\"\n  requires none\n  ensures none\n  effects fs\n{\n  let opts = fs.open_options().write(true).create(true).truncate(true);",
    ["fault"],
)

# 4. パス検査の省略
mut(
    "path_validation_omitted",
    "validate_path をバイパスして常に Ok(true) を返す",
    "git/validate.sigil",
    "pub fn validate_path(path: &String) -> Result<Bool, GitError>\n  intent \"ADR 0047 決定4 に従い、パスの安全性を検査する\"\n  requires none\n  ensures none\n  effects none\n{",
    "pub fn validate_path(path: &String) -> Result<Bool, GitError>\n  intent \"ADR 0047 決定4 に従い、パスの安全性を検査する\"\n  requires none\n  ensures none\n  effects none\n{\n  return Ok(true);",
    ["validate", "fuzz"],
)

# 5. symlink の追従・検査省略
mut(
    "symlink_check_omitted",
    "checkout 時に symlink (120000) エントリの拒否検査を省略する",
    "git/checkout.sigil",
    "fn is_unsupported_mode(m: Int) -> Bool\n  intent \"symlink（120000）か gitlink（160000）かを返す\"\n  requires none\n  ensures none\n  effects none\n{\n  return m == 120000 || m == 160000;\n}",
    "fn is_unsupported_mode(m: Int) -> Bool\n  intent \"symlink（120000）か gitlink（160000）かを返す\"\n  requires none\n  ensures none\n  effects none\n{\n  return m == 160000;\n}",
    ["ops"],
)

def sh(cmd, cwd, timeout=300):
    t0 = time.time()
    try:
        r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout + r.stderr, time.time() - t0
    except subprocess.TimeoutExpired:
        return 124, "timeout", time.time() - t0

def main():
    if len(sys.argv) < 3:
        print("Usage: mutations.py <repo_root> <sigil_binary>", file=sys.stderr)
        sys.exit(2)

    root = os.path.abspath(sys.argv[1])
    sigil = os.path.abspath(sys.argv[2])

    print("=== 変異試験の実行（ADR 0047 決定 6 末尾）===")
    results = []
    has_build_error = False

    for m in M:
        work = tempfile.mkdtemp(prefix="sigil_git_mut_")
        try:
            # ソースツリーをコピー
            for d in ("git", "tests", "fixtures"):
                src_d = os.path.join(root, d)
                if os.path.exists(src_d):
                    shutil.copytree(src_d, os.path.join(work, d))
            shutil.copy(os.path.join(root, "mutation_runner.sigil"), work)
            shutil.copy(os.path.join(root, "interop_ops.sigil"), work)

            target_file = os.path.join(work, m["path"])
            with open(target_file, "r") as f:
                content = f.read()

            if content.count(m["old"]) != 1:
                results.append((m["name"], m["desc"], "ERROR", f"置換対象が一意でない (count={content.count(m['old'])})", 0))
                has_build_error = True
                continue

            content = content.replace(m["old"], m["new"])
            with open(target_file, "w") as f:
                f.write(content)

            status = "UNDETECTED"
            note = "試験通過 (未検出)"
            total_time = 0.0

            for entry in m["entries"]:
                if isinstance(entry, tuple):
                    # スクリプトの入口: 変異を入れた作業ツリーの中で、そのスクリプトを走らせる
                    _, script, extra_env = entry
                    env = dict(os.environ)
                    env.update(extra_env)
                    env["SIGIL"] = sigil
                    env["KEEP"] = ""
                    t0 = time.time()
                    try:
                        r = subprocess.run(["bash", script], cwd=work, capture_output=True, text=True, timeout=300, env=env)
                        rc, out = r.returncode, r.stdout + r.stderr
                    except subprocess.TimeoutExpired:
                        rc, out = 124, "timeout"
                    total_time += time.time() - t0
                    if rc == 0:
                        continue
                    # 終了コード 1 で、試験が不変条件の違反を報告した（"FAIL [...]"）ときだけを検出とする。
                    # 構文エラー・準備の不備（終了コード 2）・タイムアウトなどは、変異を検出したことにしない。
                    if rc == 1 and "FAIL [" in out:
                        status = "DETECTED"
                        note = f"試験失敗 (script {os.path.basename(script)})"
                        break
                    status = "BUILD_ERROR"
                    note = f"スクリプトが想定外の終了 (rc={rc}, script {os.path.basename(script)})"
                    has_build_error = True
                    print(f"[{m['name']}] {script} の出力の末尾:\n" + "\n".join(out.splitlines()[-8:]), file=sys.stderr)
                    break
                bin_path = os.path.join(work, "mut_bin")
                rc, out, dt = sh([sigil, "build", "--root", ".", "mutation_runner.sigil", entry, "-o", bin_path], work, 120)
                total_time += dt
                if rc != 0:
                    status = "BUILD_ERROR"
                    note = f"ビルド失敗 (entry {entry})"
                    has_build_error = True
                    break

                rc, out, dt = sh([bin_path], work, 120)
                total_time += dt
                # 戻り値 1 以上、または出力末尾が 0 でなければ検出
                lines = out.strip().splitlines()
                last_line = lines[-1] if lines else ""
                if rc != 0 or last_line != "0":
                    status = "DETECTED"
                    note = f"試験失敗 (entry {entry})"
                    break

            results.append((m["name"], m["desc"], status, note, total_time))
        finally:
            shutil.rmtree(work, ignore_errors=True)

    print("\n| 変異名 | 説明 | 結果 | 検出契機 | 所要秒 |")
    print("|---|---|---|---|---|")
    for name, desc, status, note, dt in results:
        print(f"| {name} | {desc} | **{status}** | {note} | {dt:.1f}s |")

    if has_build_error:
        print("\nSome mutations encountered unexpected BUILD_ERROR!", file=sys.stderr)
        sys.exit(1)

    detected_count = sum(1 for _, _, s, _, _ in results if s == "DETECTED")
    undetected_count = sum(1 for _, _, s, _, _ in results if s == "UNDETECTED")
    print(f"\n変異試験集計: {detected_count} DETECTED, {undetected_count} UNDETECTED")

    unexpected_undetected = [name for name, _, s, _, _ in results if s == "UNDETECTED" and name not in ALLOWED_UNDETECTED]
    if unexpected_undetected:
        print(f"\nエラー: 許可されていない未検出の変異が存在します: {unexpected_undetected}", file=sys.stderr)
        sys.exit(1)

    sys.exit(0)

if __name__ == "__main__":
    main()
