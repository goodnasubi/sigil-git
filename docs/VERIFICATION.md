# Sigil Git (SHA-256) 検証記録（ADR 0047 単位 6 集約文書）

本稿は、ADR 0047（Sigil 実装計画 P4-3『Git 相互運用と基本操作』）第 6 段（単位 6: 障害注入・ファジング・Git との比較・互換 fixture の検証記録）に基づく、第 1 段〜第 6 段の検証結果および持ち越し事項を整理した公式検証記録である。

---

## 1. 検証環境情報

検証は以下の固定された環境および依存構成にて実施した。浮動版は排除し、コミット SHA およびバージョン番号を完全固定している。

| 項目 | 設定値 / 実測値 | 備考 |
|---|---|---|
| **Git 実装** | `git version 2.43.0` | `STAGE5_GIT` / `STAGE5_GIT_VERSION: 2.43.0` で固定照合 |
| **Sigil コンパイラ** | `33467e3b43238fdc69331c58a788c95f1de393e5` | Sigil リポジトリ `main` の完全コミット SHA |
| **Sigil 標準ライブラリ** | 上記コンパイラ同梱の組込 stdlib | `runtime/core`, `runtime/os` |
| **OS / カーネル** | Linux x86_64 (Debian 12, GNU/Linux) | クラウド実行環境 |
| **C コンパイラ (cc)** | `gcc (Debian 12.2.0-14) 12.2.0` | `sigil build` ネイティブリンク用 |
| **検証実施日** | 2026-11-20 JST | |

---

## 2. 第 1 段〜第 6 段 Git 比較マトリクス

本プロジェクトでは、公式 Git (version 2.43.0, SHA-256 オブジェクト形式) との厳格な byte-for-byte 相互運用性を各段ごとに段階的に検証した。

| 開発段 (Stage) | 主な対象機能 | 公式 Git 比較内容 | 相互運用検証スクリプト | 判定 |
|---|---|---|---|---|
| **第 1 段** | 暗号プリミティブ・基本構造 | SHA-256 計算、オブジェクトヘッダ形式、基本 I/O | `tests/test_object.sigil`, `test_validate.sigil` | **合格** |
| **第 2 段** | ルーズオブジェクト・Refs | loose blob/tree/commit/tag の読み書き、`git cat-file`、`git hash-object`、HEAD/ブランチ解決 | `interop.sh` | **合格** |
| **第 3 段** | Pack 形式・トポロジカル走査 | Pack v2 / Index v2 解析、OBJ_OFS_DELTA / OBJ_REF_DELTA 復号、`git rev-list` 同等の log 走査 | `interop_pack.sh` | **合格** |
| **第 4 段** | Index・作業ツリー・基本操作 | DIRC v2 インデックス、`git add`、`git commit`、`git checkout`、悪意あるパス拒絶 | `interop_ops.sh` | **合格** |
| **第 5 段** | 差分・適用・3-way マージ | Tree 差分計算、パッチ適用、共通祖先に基づく 3-way マージ、衝突検出 | `interop_history.sh` | **合格** |
| **第 6 段** | 障害耐性・ファジング・互換性 | 障害注入 (Durable Model & 実 FS 中断)、構造認識ファジング、互換 fixture、実行経路一致、変異試験 | `test.sh`, `tests/fault_interop.sh` | **合格（一部持ち越しあり）** |

---

## 3. 障害注入と永続化モデル（Durable Model）検証

クラッシュ・電源遮断・I/O 障害が発生しても、Git リポジトリの永続状態が一貫性を保ち、破損や巻き戻り・ゴーストオブジェクトが発生しないことを検証した（`tests/test_fault.sigil`, `tests/fault_interop.sh`）。

### 3.1 永続化モデル（Durable Model）シミュレーション (`tests/test_fault.sigil`)
OS キャッシュとディスクの同期境界（fsync）の振る舞いをモデル検査器でシミュレートし、以下のシナリオを検証:
1. **オブジェクト書き込み中の中断 (Unflushed write loss vs sync persistence)**: `model_write` による未同期バッファは電源断（クラッシュ）で喪失（0 byte / 未同期）し、`model_sync`（fsync）を実行した後に初めてディスク上の永続データとして確定する。
2. **参照更新ロックの同期バリア (Ref lock ordering barrier)**: `<ref>.lock` の作成・書き込みにおいて、未同期状態では参照が確定せず、旧参照の不変条件が維持される。

### 3.2 実ファイルシステム障害注入 (`tests/test_fault.sigil`)
実ファイルシステム上での異常状態の注入と防御動作を検証:
- **孤立一時オブジェクト (`tmp_obj_*`)**: 書き込み中断で残された一時ファイルが存在しても、`odb_read` で正規オブジェクトとして誤認されず、後続の `odb_write` / `odb_read` を阻害しない。
- **孤立参照ロック (`<ref>.lock`)**: クラッシュで残ったロックファイルに対して、強制上書きを行わず `GitError::Locked` で安全に拒絶。失敗の前後で `refs/heads/main` の参照値（コミット ID）および HEAD が一切変化しないことを照合。
- **孤立インデックスロック (`index.lock`)**: コミットや追加処理がロック検出で `Locked` となり、作業ツリー内の未保存変更ファイル（`dirty.txt`）を破壊・変更しない。
- **削除済み参照の復活防止**: `topic` ブランチ削除後、`read_ref` が `Ok(None)` を返し、過去の参照値が復活しないことを確認。

### 3.3 孤立ファイル残存・ロック競合・Sigil 参照削除の実 Git 整合性検証 (`tests/fault_interop.sh`)
実 Git (2.43.0) を用いて、孤立ファイル・ロック残存および Sigil による `packed-refs` 削除後のリポジトリを `git fsck --strict --full` で検証:
- **シナリオ A (孤立 tmp_obj_* 残存時の耐性)**: `tmp_obj_*` が残存しても `git fsck --strict --full` が成功し、応答済みコミットが HEAD から完全に到達可能。
- **シナリオ B (孤立 <ref>.lock 残存時の排他保護と HEAD 不変)**: 孤立ロック下でのコミット試行が安全に拒絶され、実 Git の `git rev-parse HEAD` および `git fsck --strict --full` が正常パス。
- **シナリオ C (孤立 index.lock 残存時の未保存変更保護)**: 未コミットの変更ファイルおよび作業ツリーの変更（`hello.txt`, `unsaved.txt`）が完全に保持され、`git fsck --strict --full` が成功。
- **シナリオ D (packed-refs 参照削除の中断・非復活確認)**:
  - Git 2.43.0 `pack-refs --all` 後のリポジトリに対し、`packed-refs.lock` 残存時は Sigil の `delete_branch` が `Locked` で中断し参照が保護されること。
  - 本実装の `delete_branch` による削除実行後、`packed-refs` および loose refs から完全に消去され、実 Git の再起動・`rev-parse` で再浮上せず `git fsck --strict --full` が成功することを確認。
- **シナリオ E (障害・中断後の不変条件検証)**:
  - ADR 0047 決定 6-5 に従い、操作中断後における (b) 応答済みコミット到達可能性、(c) オブジェクト非欠落（`git fsck --strict --full`）、(d) ユーザー未保存変更保持（作業木・未コミット変更）を実証。

> [!NOTE]
> **持ち越し事項（障害注入）**:
> 1. **カーネル空間 I/O 障害注入**: システムコール中間での短小書き込み（short write）や `ENOSPC`, `EIO` などのカーネルレベルのエラー注入は、専用の故障注入ファイルシステム（dm-flakey 等）を要するため持ち越し。
> 2. **ステップ単位のプロセス強制終了**: オブジェクト書込・参照更新・索引更新・チェックアウト・参照削除の各ステップ（一時ファイル作成・書込・同期・rename・親同期・ロック解放）の前後での決定論的プロセス中断は、コアエンジンへの同期フック未組込のため持ち越し。

---

## 4. ファジング検証（Fuzzing & Boundary Regression）

乱数および構造認識変異によるロバストネス検証を実施した（`tests/test_fuzz.sigil`）。

- **擬似乱数シード**: `20261120`（完全再現可能な決定的 PRNG）
- **ファジング対象 12 領域（各 100 反復、計 1,200 回試行）**:
  1. `fuzz_headers`: 巨大サイズ（オーバーフロー）、負のサイズ、数字以外の文字、終端ヌル欠落、空サイズ、ランダム列
  2. `fuzz_trees`: 切り詰められた SHA-256（32バイト未満）、ファイル名内の NUL バイト、順不同（未ソート）エントリ、モード欠落、ランダム列
  3. `fuzz_commits`: 必須 `tree` ヘッダ欠落、不正な親コミット ID、メッセージ前の空行欠落、切り詰め author/committer、ランダム列
  4. `fuzz_tags`: 不正な object ID（非 hex）、未対応の object type、切り詰め PGP 署名ブロック、tagger 欠落、ランダム列
  5. `fuzz_inflate`: zlib ヘッダ直後の破損データ、Adler-32 チェックサム不一致、未知の圧縮方式ヘッダ、ランダム列
  6. `fuzz_index`: DIRC 未対応バージョン（ver 3）、宣言エントリ数過大＋切り詰めボディ、マジックヘッダ不一致、ランダム列
  7. `fuzz_packed_refs`: 不正な剥離（peeled `^`）構文、非 64 桁ハッシュ行、改行なし切り詰め、ランダム列
  8. `fuzz_delta`: ソース長不一致、copy オペコードのオフセット超過（offset > base 長）、復元後サイズ超過、ランダム列
  9. `fuzz_config`: 閉じ括弧のないセクション、未終了の引用符付きサブセクション、等号のないキー行、ランダム列
  10. `fuzz_paths_and_refs`: ランダムバイト列によるパスおよび参照名検証の網羅的投入
  11. `fuzz_pack_index`: pack index v2（マジック `\xfftOc` 破損、非対応バージョン、非単調 fanout テーブル、切り詰めテーブル、SHA-256 チェックサム破損）
  12. `fuzz_pack_file`: pack v2（`PACK` マジック破損、非対応バージョン、インデックスとのオブジェクト数不一致、切り詰めエントリ、チェックサム破損）
- **悪意ある入力・境界回帰コーパス**:
  - パストラバーサル (`../escaped`, `a/../../b`, `\`)
  - NTFS 代替ストリーム (`.git::$DATA`)、`.git/config`、`a/.git/hooks`、絶対パス (`/absolute/path`)
  - 長大パス: 単一構成要素 260 文字（上限 255 超過）、合計長 4100 文字（上限 4096 超過）
  - 不正参照名: `refs/heads/..`, `refs/heads/foo.lock`, `refs/heads/foo@{bar`, `//`, `?`, `*`, `@`, 先頭/末尾スラッシュ
  - 長大参照名: 1050 文字（上限 1024 超過）
  - 壊れたオブジェクト構造: SHA-256 欠落 tree、tree 欠落 commit、非 hex ID tag、不正ハッシュ packed-refs、範囲外 copy delta
- **検証結果**:
  - 総試行回数: 1,200 反復 + 回帰コーパス
  - 所要時間: 約 1.3 秒
  - 異常終了（パニック/クラッシュ）: **0 件**（すべての破損・不正入力に対し安全に処理され、適切な `GitError` で拒絶または制御下で処理されることを確認）

---

## 5. 互換 fixture（v1）の検証

初版仕様に基づいて生成・保管された永続データが、将来のバージョンや新しい reader で互換性を保って読み取れることを検証した（`fixtures/v1/`, `tests/test_compat.sigil`）。

- **来歴および再現手順 (Provenance & Reproduction)**:
  - 公式 Git 2.43.0（`--object-format=sha256`）および Sigil 初版相互運用ツールを用いて生成。
  - 再現手順:
    ```bash
    git init --object-format=sha256 repo
    printf "hello world\n" > repo/file.txt && git -C repo add file.txt
    GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com GIT_AUTHOR_DATE="1700000000 +0000" \
    GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com GIT_COMMITTER_DATE="1700000000 +0000" \
    git -C repo commit -m "initial commit"
    GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com GIT_COMMITTER_DATE="1700000000 +0000" \
    git -C repo tag -a -m "v1.0" v1.0 HEAD
    git -C repo pack-refs --all
    git -C repo repack -a -d
    ```
  - `git fsck --strict --full` で受理確認済み。
- **保管 fixture (`fixtures/v1/`)**:
  - `blob.obj`: ルーズ blob（オブジェクト ID: `2cf8d83d9ee29543b34a87727421fdecb7e3f3a183d337639025de576db9ebb4`、ファイル SHA-256: `f619a4e2af93fa7a910cdcf963722a0cdb06e0e3bb9620d6fc7ec06808e73e1d`）
  - `tree.obj`: ルーズ tree（オブジェクト ID: `ea3b6ce0df88dc227083adba05c43d15da3a824a98da9bcaaf1930277fb07f30`、ファイル SHA-256: `3d0ae9ecbb8e36c8074f41827c46f910c01a7c54247925ff7c4f2af50be2dd33`）
  - `commit.obj`: ルーズ commit（オブジェクト ID: `b1e071267937c1c2a8baa1a9ee2c6a448dc9e35685da97521b1f019e9d3e5fe6`、ファイル SHA-256: `553787eaaf2aff86decb2ff33a2b1177fa47d5dd74303b70b4c29f0deb48d3b4`）
  - `tag.obj`: ルーズ tag（オブジェクト ID: `ffa044a306d0cebaa2987aadd19bd5de0aa1cdc6bf5bfc18e4f76094d3cb16b0`、ファイル SHA-256: `4e8af5f359365b638c19f6fe3712c0ce32ad985799e79ee80f86dcc8105fc69b`）
  - `sample.pack`: Packfile v2（ファイル SHA-256: `e282df7ee43e4eaaa10c9494fbac01d165dd2bb0f21205e3f4fef39b207dceaf`）
  - `sample.idx`: Index v2（ファイル SHA-256: `92411c77e447f6a3cb7b3024f0026da5249b5f24be5b63d2aaee22cf9439e2de`）
  - `packed-refs`: packed-refs ファイル（ファイル SHA-256: `7f920260ee89bbb26b7c4ed16ba98e88dc4ac6c47a84a5a83af179bf24944cc3`）
  - `manifest.txt`: 上記オブジェクト ID、全ファイルの SHA-256 チェックサムおよび生成手順を記録。`test.sh` にて `sha256sum -c` による自動照合を実施。
- **検証結果**:
  - `tests/test_compat.sigil` において、全 v1 オブジェクト・インデックス・パックファイル・参照ファイルが最新の reader 実装から完全にパース・検証可能であることを確認。また `test.sh` にて fixture ファイル自体のチェックサム固定一致を確認。

---

## 6. 実行経路一致の検証（Execution Path Equivalence）

Sigil の 2 つの実行基盤である「SIR 評価器（インタープリタ: `sigil run`）」と「ネイティブ実行（コンパイル: `sigil build`）」において、セマンティクスおよび結果がビット単位で完全一致することを検証した（`tests/test_xcheck.sigil`）。

- **トレースダイジェスト算出内容 (`compute_trace_digest`)**:
  - 失敗を握りつぶさず、全操作の成功値およびエラー種別（`error_kind_name`）をタグ付きで畳み込み。
  - **正常操作**: blob 符号化/検証、tree 符号化/復号、commit 符号化/復号、tag 符号化/復号、zlib stored 圧縮および inflate 伸長
  - **エラー経路**: 壊れた tree エントリ、tree 欠落 commit、不正 object ID tag、破損 zlib ストリーム、パストラバーサル (`../secret`)、不正参照名 (`@{`)
  - **上限検査**: パス構成要素長 255 超過、参照名長 1024 超過
- **算出ダイジェスト値**:
  - **固定期待値 (`expected_trace_digest()`)**: `ebce0bdaaee7081c671596c80c526ab634eaacb2d0dcd4c1b5b0787a69f227f6`
  - **SIR 評価器 (`sigil run`)**: `ebce0bdaaee7081c671596c80c526ab634eaacb2d0dcd4c1b5b0787a69f227f6`
  - **ネイティブ実行 (`sigil build`)**: `ebce0bdaaee7081c671596c80c526ab634eaacb2d0dcd4c1b5b0787a69f227f6`
  - **判定**: **完全一致（固定値・SIR・ネイティブの 3 者一致）**
- **fs 信頼差分の監査結果との結び付け**:
  - `test_xcheck` は純粋論理層（コーデック、上限、バリデーション、inflate）を対象とし、評価器とネイティブの間で意味論の乖離がないことを実証。
  - ファイルシステム I/O（`std.os.fs`）に依存する操作は、実ファイルシステム試験（`tests/fault_interop.sh`, `interop*.sh`）により実 Git との相互運用性として担保。

---

## 7. 性能プロファイル記録（Performance Profile）

標準的な Git ワークロードにおける時間およびメモリ消費量を測定した（`perf_runner.sigil`）。

- **測定対象ワークロード**:
  - ルーズオブジェクト書き込み（ハッシュ計算・zlib 圧縮・同期付き書き込み）
  - ルーズオブジェクト読み出し（解凍・ヘッダ検証・SHA-256 整合性チェック）
  - コミット作成・インデックス更新・ツリー生成
  - コミット履歴走査（log walk）
  - 作業ツリー差分計算（diff_worktree）
  - 作業ツリーのチェックアウト
- **実測結果**:
  - **ネイティブ実行 (`sigil build`, 50 反復)**:
    - 経過時間 (Wall clock): 1.57 秒（反復あたり約 31.4 ms）
    - ユーザー CPU 時間: 0.93 秒
    - 最大常駐メモリサイズ (Max RSS): 1,204 KB（約 1.17 MB）
  - **SIR 評価器 (`sigil run`, 10 反復)**:
    - 経過時間 (Wall clock): 1.29 秒（反復あたり約 129.0 ms）
    - ユーザー CPU 時間: 1.00 秒
    - 最大常駐メモリサイズ (Max RSS): 33,808 KB（約 33 MB）
  - **注意（反復数の相違について）**:
    - SIR 評価器はインタープリタ実行のオーバーヘッドがあるため 10 反復、ネイティブ実行は 50 反復で測定している。1 反復あたりの所要時間はネイティブが約 31.4 ms に対し SIR 評価器が約 129 ms であり、ネイティブ実行は約 4.1 倍高速である。

- **再現手順**:
  ```bash
  # ネイティブ実行の測定
  sigil build --root . perf_runner.sigil main -o target/perf_runner
  /usr/bin/time -v ./target/perf_runner

  # SIR 評価器の測定
  /usr/bin/time -v sigil run --root . perf_runner.sigil small
  ```

---

## 8. 変異テスト（Mutation Testing）結果

テストスイートが重大なバグ・セキュリティ脆弱性の混入を確実に検出できるかを検証するため、本体コードに対する変異試験を実施した（`tests/mutation/run.sh`）。

| 変異体 ID | 変異内容の概要 | 注入箇所（本体コード） | 検出結果 | 検出契機・備考 | 所要時間 |
|---|---|---|---|---|---|
| `id_verification_omitted` | オブジェクト読み取り時にハッシュの再計算・照合を省略する | `git/object.sigil` | **DETECTED** | 試験失敗 (entry object) | 0.6s |
| `object_sync_omitted` | オブジェクトファイル書き込み時の fsync (sync_all) 呼び出しを完全に省略する | `git/fsio.sigil` | **UNDETECTED** | 試験通過 (未検出・持ち越し) | 1.0s |
| `lock_ignored` | ロックファイルが存在しても排他作成せず上書きする | `git/fsio.sigil` | **DETECTED** | 試験失敗 (entry fault) | 1.0s |
| `path_validation_omitted` | `validate_path` をバイパスして常に Ok(true) を返す | `git/validate.sigil` | **DETECTED** | 試験失敗 (entry validate) | 0.6s |
| `symlink_check_omitted` | checkout 時に symlink (120000) エントリの拒否検査を省略する | `git/checkout.sigil` | **DETECTED** | 試験失敗 (entry ops) | 2.1s |

- **変異検出結果**: **4 DETECTED / 1 UNDETECTED**
- **UNDETECTED 変異の扱いとホワイトリスト判定**:
  - `mutations.py` に `ALLOWED_UNDETECTED = {"object_sync_omitted"}` を導入し、意図した持ち越し以外の未検出が発生した場合は即座に exit 1 で異常終了するよう制御。
  - `object_sync_omitted` は同一プロセス・OS ページキャッシュ環境下では直後の読み取りがキャッシュからヒットするため未検出となります。
  - ADR 0047「検出されない変異を検証済みとしない」の定めに従い、本項目は検証済みとせず、電源断・クラッシュシミュレーション環境での検証課題として**持ち越し**と記録します。

---

## 9. 結論と持ち越し

本第 6 段の実装および検証において:
- 孤立ファイル残存・ロック競合・Sigil による `packed-refs` 削除時のリポジトリ健全性（`git fsck --strict --full` 成功、未保存変更の保持、削除済み参照の非復活）を実証。
- 12 領域の構造認識ファジング（1,200 反復、pack/index を含む）および回帰コーパスによるロバスト性を確認。
- 初版互換 fixture (v1) の読み取りと来歴・チェックサムの固定（`test.sh` による自動検証）を完了。
- SIR 評価器とネイティブ実行の動作一致（固定期待値 `ebce0bda...` との 3 者一致）を実証。
- 本体コードに対する変異試験を実施し、4 件の検出および 1 件の持ち越し（ホワイトリスト管理）を明記。

### 持ち越し事項 (Carried Over)
1. **カーネルレベルの I/O 障害注入**: `ENOSPC`, `EIO`, short write mid-syscall などのハードウェア/カーネルレベルの障害注入（dm-flakey 等を要する試験）。
2. **ステップ単位のプロセス強制終了**: オブジェクト書込・参照更新・索引更新・チェックアウト・参照削除の各ステップ（一時ファイル作成・書込・同期・rename・親同期・ロック解放）の前後での決定論的プロセス強制終了試験。
3. **変異 `object_sync_omitted` の検証**: 電源断や OS クラッシュを伴う環境における未同期データ喪失の検出性再検証。
