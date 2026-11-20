#!/usr/bin/env python3
# ADR 0047 決定 6 変異試験（意図した誤りが検出されるかの測定）。
# 5 つの変異（識別子の検証省略、オブジェクト未同期、ロック無視、パス検査省略、symlink検査省略）を
# 1 つずつ埋め、試験群（mutation_runner.sigil）が落ちることを確かめる。
# 全変異が DETECTED となれば終了コード 0、未検出（UNDETECTED）があれば終了コード 1。

import os
import shutil
import subprocess
import sys
import tempfile
import time

M = []

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
    "参照の更新・永続化前にオブジェクトの同期（model_sync）を省略する",
    "tests/test_fault.sigil",
    "          new_files.push(ModelFile { path: f.path.clone(), durable_data: f.unflushed_data.clone(), unflushed_data: f.unflushed_data.clone(), synced: true });",
    "          new_files.push(ModelFile { path: f.path.clone(), durable_data: f.durable_data.clone(), unflushed_data: f.unflushed_data.clone(), synced: false });",
    ["fault"],
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
    all_detected = True
    results = []

    for m in M:
        work = tempfile.mkdtemp(prefix="sigil_git_mut_")
        try:
            # ソースツリーをコピー
            for d in ("git", "tests", "fixtures"):
                src_d = os.path.join(root, d)
                if os.path.exists(src_d):
                    shutil.copytree(src_d, os.path.join(work, d))
            shutil.copy(os.path.join(root, "mutation_runner.sigil"), work)

            target_file = os.path.join(work, m["path"])
            with open(target_file, "r") as f:
                content = f.read()

            if content.count(m["old"]) != 1:
                results.append((m["name"], m["desc"], "ERROR", f"置換対象が一意でない (count={content.count(m['old'])})", 0))
                all_detected = False
                continue

            content = content.replace(m["old"], m["new"])
            with open(target_file, "w") as f:
                f.write(content)

            status = "UNDETECTED"
            note = ""
            total_time = 0.0

            for entry in m["entries"]:
                bin_path = os.path.join(work, "mut_bin")
                rc, out, dt = sh([sigil, "build", "--root", ".", "mutation_runner.sigil", entry, "-o", bin_path], work, 120)
                total_time += dt
                if rc != 0:
                    status = "DETECTED"
                    note = f"ビルド失敗 (entry {entry})"
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

            if status != "DETECTED":
                all_detected = False

            results.append((m["name"], m["desc"], status, note, total_time))
        finally:
            shutil.rmtree(work, ignore_errors=True)

    print("\n| 変異名 | 説明 | 結果 | 検出契機 | 所要秒 |")
    print("|---|---|---|---|---|")
    for name, desc, status, note, dt in results:
        print(f"| {name} | {desc} | **{status}** | {note} | {dt:.1f}s |")

    if all_detected:
        print("\nAll mutations DETECTED successfully!")
        sys.exit(0)
    else:
        print("\nSome mutations were UNDETECTED or ERRORED!", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
