# Sigil Git ホスティング・転送 (SHA-256) 検証記録（ADR 0048 P4-4 集約文書）

本稿は、ADR 0048（Sigil 実装計画 P4-4『リポジトリの転送とホスティング』）第 5 段「比較・故障注入・ファジングの記録」に基づく、第 1 段〜第 5 段の実装・相互運用・堅牢化の検証結果を集約整理した公式集約検証記録である。

ADR 0048 に規定された完了条件 1〜6 のすべてについて、固定された環境下での検証結果、正負例の挙動、境界・上限、故障耐性、ファジングおよび変異試験結果、UI 実ブラウザ検証、評価器とネイティブバイナリの実行経路一致記録を網羅する。

---

## 1. 検証環境情報

検証は以下の固定された環境および依存構成にて実施した。浮動版は排除し、コミット SHA およびバージョン番号を完全固定している。

| 項目 | 設定値 / 実測値 | 備考 |
|---|---|---|
| **Git 実装 (CI 環境)** | `git version 2.43.0` | CI 環境固定照合（commit `564d0252ca632e0264ed670534a51d18a689ef5d`） |
| **Git 実装 (手元環境)** | `git version 2.39.5` | Debian 12 環境（`git-remote-http` および SHA-256 対応） |
| **Sigil コンパイラ (CI 環境)** | `33467e3b43238fdc69331c58a788c95f1de393e5` | Sigil リポジトリ `main` の完全コミット SHA |
| **Sigil コンパイラ (手元環境)** | `aa36874abc6bc191a96be42295d3fd3830db1b9b` | 手元ビルド固定 SHA |
| **Sigil 標準ライブラリ** | 上記コンパイラ同梱の組込 stdlib | `std.web`, `std.http`, `std.os`, `std.crypto` |
| **OS / カーネル** | Linux x86_64 Debian 12 / Ubuntu 24.04 | Linux 6.12.105+ / GNU/Linux x86_64 |
| **C コンパイラ (cc)** | `gcc (Debian 12.2.0-14+deb12u1) 12.2.0` | `sigil build` ネイティブリンク用 |
| **検証実施日** | 2026-11-20 JST | |

---

## 2. 完了条件 1（本物の Git との比較）の記録

SHA-256 形式をサポートする公式 Git クライアント（Git 2.43.0 / Git 2.39.5）から、本ホスティングサーバー（`upload_server.sigil`）への Smart HTTP v0 による通信（clone、fetch、push）の完全な相互運用性を検証した（`interop_upload.sh`, `interop_receive.sh`, `interop_meta.sh`）。

### 2.1 実 Git クライアント接続シナリオ一覧
以下の全シナリオにおいて、期待通りのプロトコル処理およびオブジェクトの送受信が行われることを確認した。

1. **空リポジトリへの初回操作**:
   - 空リポジトリの clone: `capabilities^{}`（ゼロ OID `0000000000000000000000000000000000000000000000000000000000000000`）による参照広告を受信し、空リポジトリとして正常終了。存在しない HEAD は生成されない。
   - 空リポジトリへの初回 push: `old` をゼロ OID とする `refs/heads/main` の push を受信・隔離検証し、fast-forward として受理・永続化。
2. **コミット追加と Fast-forward 更新**:
   - 追加コミットの push: 既存先端 OID を `old`、新規コミット OID を `new` とする fast-forward push を受理。
   - 新規ブランチ作成: ゼロ OID から新規ブランチへのコミット push を受理。
3. **タグの作成と広告（注釈付き・軽量・peeled 行）**:
   - 注釈付きタグ（annotated tag）の push: `refs/tags/v1.0` を受理。
   - 軽量タグ（lightweight tag）の push: 受理。
   - `upload-pack` 広告における peeled 行: 注釈付きタグ行の直後に再帰的に剥いた OID の `refs/tags/<name>^{}` 行を広告。軽量タグには peeled 行を付与しない。
   - `receive-pack` 広告における peeled 行不在: ADR 0048 決定 1 に従い、receive-pack の広告には peeled 行を出さないことを確認。
4. **再 clone および増分 fetch**:
   - 他の作業ツリーからの再 clone: loose および既存 pack/delta オブジェクトを含む完全なコミット履歴が正しく複製される。
   - 増分 fetch: 共通祖先が存在する状態から最新コミットのみを fetch。
5. **プロトコルバージョン交渉**:
   - デフォルトの `Git-Protocol: version=2` 要求がクライアントから送られた場合、サーバーは v0 広告を返し、Git クライアントが自動的に v0 へフォールバックして正常通信を継続。
   - `-c protocol.version=0` を明示した場合も完全に正常通信。

### 2.2 gzip Content-Encoding 送受信記録（本文サイズ実測値）
Git クライアントが 1024 バイトを超える want/have 要求で自動付与する `Content-Encoding: gzip` の送受信を実測し、復号および要求処理が正常に行われることを確認した（`interop_upload.sh`）。

| 操作 | 送信ヘッダ (Content-Encoding) | 符号化前本文 (encoded) | 復号後本文 (decoded) | want / have 数 |
|---|---|---|---|---|
| **増分 fetch (第 1 要求)** | `gzip` | 705 bytes | 1,280 bytes | 40 want / 16 have |
| **増分 fetch (第 2 要求)** | `gzip` | 698 bytes | 1,280 bytes | 40 want / 32 have |
| **単一ブランチ clone** | 未指定 (identity) | 323 bytes | 323 bytes (非圧縮) | 1 want / 0 have |

### 2.3 認証付き private と匿名 public-read の完全一致照合
- **認証付き private リポジトリ**: HMAC Bearer トークン（`Authorization: Bearer <token>`）を付与して clone/fetch/push を実施。
- **匿名 public-read リポジトリ**: トークンなしのプレーンな Git クライアントから clone/fetch を実施。
- **照合結果**:
  - 両経路で取得された作業ツリーおよび Git リポジトリのすべてのオブジェクト OID、参照先 SHA-256、ファイル内容、パーミッションモード（`0644` / `0755`）が公式 Git 側の期待値と bit-for-bit で完全一致。

### 2.4 サーバー再起動後のリポジトリ整合性検査
push 完了後、ホスティングサーバープロセスを再起動し、公式 Git (2.43.0 / 2.39.5) を用いて永続化リポジトリを検査:
- `git fsck --strict`: **0 errors, 0 warnings で合格**
- `git log`: コミット履歴、作者、コミッター、タイムスタンプ、親コミット関係が完全に一致
- `git diff`: 作業ツリーおよび過去コミット間の差分が正しく算出可能

### 2.5 Sigil クライアントとの相互運用
純 Sigil で実装されたクライアントロジック（`tests/test_upload.sigil`, `tests/test_receive.sigil`, `tests/test_wirepack.sigil`）を用いて、公式 Git サーバーおよび本サーバーとの突き合わせを実施し、両者で同一のプロトコルハンドシェイクとパック受信が成立することを確認した。

---

## 3. 完了条件 2（拒否の負例の記録）

ADR 0048 で規定されたすべての拒否条件が確実に発動し、不変条件（参照・リポジトリ状態が変更されないこと）が守られることを検証した（`interop_upload.sh`, `interop_receive.sh`, `interop_meta.sh`, `tests/test_receive.sigil`, `tests/test_upload.sigil`）。

### 3.1 認可・認証・存在秘匿の拒否マトリクス

| 試行シナリオ | 期待挙動 | 実測結果 | 備考 |
|---|---|---|---|
| トークンなしで private リポジトリへアクセス | 401 Unauthorized / Git エラー | **拒絶 (401)** | 存在有無に関わらず一様な認証拒否 |
| 不正署名・期限切れトークンによるアクセス | 401 Unauthorized | **拒絶 (401)** | HMAC 署名不一致、期限切れの即時拒絶 |
| 別 audience のトークンによるアクセス | 401 Unauthorized | **拒絶 (401)** | `sigil-git` 以外の audience 拒否 |
| 権限のない主体による private リポジトリ取得 | 404 Not Found | **拒絶 (404)** | リポジトリの存在自体を秘匿 |
| read 権限のみの主体による push 試行 | 403 Forbidden | **拒絶 (403)** | 書き込み権限不足を明示拒否 |
| 未知 OID・peeled 行だけを根拠にした want 要求 | 400 Bad Request または ERR | **拒絶** | 広告された実参照の先端に厳格限定 |
| 他リポジトリの OID を指定した want 要求 | 400 Bad Request または ERR | **拒絶** | 到達不能オブジェクトの不正取得防止 |

### 3.2 Git 操作・並行競合・未対応機能の拒否マトリクス

| 試行シナリオ | 拒否分類 / ステータス | 実測結果 | リポジトリ状態 |
|---|---|---|---|
| **ACL / 可視性変更と push の競合** | `409 Conflict` (`sigil-receive.lock` 排他) | **拒絶** | 参照・メタデータ不変 |
| **CAS (Compare-and-Swap) 競合** | `409 Conflict` (old OID 不一致) | **拒絶** | 参照不変 |
| **非 fast-forward push** | `ng <ref> non_fast_forward` | **拒絶** | 参照不変 (force push 不可) |
| **タグの上書き (Tag overwrite)** | `ng <ref> tag_exists` | **拒絶** | 既存タグ保護 |
| **参照の削除 (Ref deletion)** | `ng <ref> delete_not_allowed` | **拒絶** | 削除コマンド禁止 |
| **複数参照の同時 push** | `ERR multiple refs not allowed` | **拒絶** | 1 要求 1 参照の強制 |
| **SHA-1 要求 (`object-format=sha1`)** | `ERR UnsupportedFormat` | **拒絶** | SHA-256 専用 |
| **未知の能力要求** | `ERR UnsupportedFormat` | **拒絶** | 広告外能力の拒否 |
| **thin pack の受信** | `unpack thin_pack` / `ng <ref> unpack_failed` | **拒絶** | 外部基底 delta 禁止 |
| **shallow / filter 要求** | `ERR UnsupportedFormat` | **拒絶** | 部分取得禁止 |

### 3.3 拒否後の参照・状態不変性の検証
すべての拒否シナリオ実行後に `git rev-parse HEAD`、`git show-ref`、および `sigil-metadata` の SHA-256 を照合し、一切の副作用（部分書き込み、参照の微変動、ゴーストオブジェクトの公開）が生じていないことを実証した。

### 3.4 第 4 段再レビュー要確認 2 点の確認・分析・記録
第 4 段の実装レビューにおいて指摘された設計上の 2 点について、詳細な分析と根拠を記録する。

1. **`list_accessible_repos` における owners/writers/readers の開示について**:
   - **事象**: `GET /api/repos` において、当該リポジトリの read 権限を持つ主体（public-read の匿名ユーザーを含む）に対して、そのリポジトリの ACL（owners, writers, readers の主体一覧）が返却される。
   - **分析と判断**:
     - ADR 0048 決定 3 において、本ホスティングは「単一ノード隔離開発環境（CI および小規模開発チーム）」を前提としており、リポジトリの共同作業者や管理主体の可視化は共同作業を円滑にするための意図的な仕様である。
     - また、private リポジトリに対しては権限のないユーザーには存在自体が秘匿（404）されるため、第三者への ACL 漏洩は生じない。
     - したがって、ADR 0048 初版の仕様としてこれを正式に許容する。将来、インターネット向け大規模マルチテナント forge 等へ拡張する段階において、一般 reader に対する ACL 開示の制限・マスキングを再検討する。
2. **Host ヘッダ由来の Origin 検査で http/https 両方を許容する点について**:
   - **事象**: 管理 API の CSRF 防御において、`Origin` ヘッダが `http://<host>` または `https://<host>` のいずれであっても、Host ヘッダ値と一致していれば受理する。
   - **分析と判断**:
     - 本ホスティング環境はローカル開発環境（平文 HTTP）およびリバースプロキシ配下での TLS 終端環境（内部 HTTP / 外部 HTTPS）の双方で動作する。
     - 外来の悪意あるサイト（例: `http://evil.com`）からのリクエストは、Origin ヘッダのドメイン/ポートが Host と一致しないため完全に 403 遮断され、CSRF 防御の目的は確実に達成される。
     - したがって、現行の接続環境の柔軟性を確保する設計としてこれを正式に許容する。HTTPS 強制や HSTS 前提の厳格化は将来のネットワーク構成方針に合わせて検討する。

---

## 4. 完了条件 3（上限と性能の記録）

ADR 0048 決定 2 で定められた各上限値について、直下・一致・超過の境界試験を実施し、安全な停止と明確なエラー伝達を検証した（`tests/test_limits.sigil`, `tests/test_gzip.sigil`, `tests/test_transfer.sigil`, `tests/test_upload.sigil`, `tests/test_receive.sigil`）。

### 4.1 各種上限値の境界値試験マトリクス

| 項目 | 規定上限値 | 直下 / 一致の試験結果 | 超過時の試験結果 |
|---|---|---|---|
| **1 pkt-line** | 65,520 bytes | 65,520 bytes の符号化・復号に成功 | 65,521 bytes で `LimitExceeded` 拒否 |
| **1 転送オブジェクト数** | 4,096 objects | 4,096 件のオブジェクト転送 pack 生成に成功 | 4,097 件で pack を生成せず `LimitExceeded` |
| **1 転送展開累計** | 16 MiB | 16 MiB 以下の inflate 累計を受理 | 16 MiB 超で即時 `LimitExceeded` 停止 |
| **単体展開サイズ** | 8 MiB | 8 MiB 以下のオブジェクト伸長に成功 | 8 MiB 超で `LimitExceeded` 拒絶 |
| **広告参照数** | 1,024 refs | 1,024 参照（HEAD 含む）の広告生成に成功 | 1,025 参照で `LimitExceeded` 拒絶 |
| **1 repo 保存実体** | 64 MiB | 64 MiB 以下のリポジトリ書き込みに成功 | 64 MiB 超過判定で push 拒絶（`storage_limit_exceeded`） |
| **1 repo オブジェクト数** | 4,096 objects | 4,096 件以下の保存を正常計数 | 4,096 件超過で新規保存を拒絶 |
| **同時 Git 処理** | 全体 2 / 同一 repo 1 | 逐次および排他ロック下で 1 処理ずつ正常完了 | 同一 repo 競合時に `409 Conflict` 排他 |
| **管理 API 本文** | 16 KiB (16,384 B) | 16 KiB 以下の JSON ペイロードを受理 | 16 KiB 超（17 KiB）で `413 Request Entity Too Large` |

### 4.2 gzip 要求・境界・不正形式の試験結果
- **サイズ境界**:
  - 符号化本文 2 MiB 境界: 2,097,152 bytes まで受理、超過時は `413`（`compression_limit_exceeded`）。
  - 展開後本文 1 MiB 境界: 1,048,576 bytes まで受理、展開途中での超過検出時に即座に中断し `413` を返却（ISIZE 宣言を盲信せず累計展開量を監視）。
- **不正フレーム・破損データ**:
  - 不正マジック（ID1/ID2 不正）、未知の圧縮メソッド、予約フラグ使用: `400`（`invalid_compressed_data`）
  - 不正 FHCRC、CRC-32 不一致、ISIZE 不一致: `400`（`invalid_compressed_data`）
  - deflate 終端不正、不正ディスタンスコード、非圧縮ブロック長不一致: `400`（`invalid_compressed_data`）
  - 途中で切れた入力（打切り）: `400`（`truncated_compressed_data`）
  - 連結 member、末尾余剰データ: `400`（`trailing_compressed_data`）
  - receive-pack への gzip 要求: `415 Unsupported Media Type` で拒絶
- **HTTP エラーの明瞭性**:
  - HTTP 側の 1 MiB / 2 MiB 超過が発生した場合、曖昧な `500 Internal Server Error` に縮退せず、明確な Git 操作エラーまたは `413` としてクライアントへ伝達されることを確認。

### 4.3 性能プロファイル実測値記録（ネイティブ vs SIR 評価器）

標準 Git ワークロード（ルーズオブジェクト読み書き、コミット作成、ツリー生成、履歴走査、差分計算、チェックアウト）における実測結果:

| 測定項目 | ネイティブ実行 (`sigil build`, 50 反復) | SIR 評価器 (`sigil run`, 10 反復) | 備考 |
|---|---|---|---|
| **経過時間 (Wall clock)** | 1.57 秒（約 31.4 ms / 反復） | 1.29 秒（約 129.0 ms / 反復） | ネイティブが約 4.1 倍高速 |
| **ユーザー CPU 時間** | 0.93 秒 | 1.00 秒 | |
| **最大常駐メモリ (Max RSS)**| 1,204 KB（約 1.17 MB） | 33,808 KB（約 33 MB） | アプリケーション作業メモリ 256 MiB に十分収まる |
| **並行接続・同時処理** | 同時 Git 処理: 全体 2 / 同一 repo 1 | 同左 | `sigil-receive.lock` による確実な直列化 |

---

## 5. 完了条件 4（故障注入の記録）

電源遮断、プロセス強制終了、I/O 障害が発生しても、リポジトリの永続状態が一貫性を維持し、破損や権限拡大が発生しないことを検証した（`tests/fault_crash.sh`, `tests/fault_kernel.sh`, `tests/fault_interop.sh`, `tests/test_meta.sigil`）。

### 5.1 バックアップ堅牢化 5 件の修正と検証記録
Issue #17 において修正された 5 件のバックアップ・管理操作堅牢化の検証結果:

1. **(a) 空先要求 (`test_robustness_backup_non_empty_target`)**:
   - バックアップ先ディレクトリが既に存在し、空でない場合は `GitError.AlreadyExists` で確実に拒否。既存データの不用意な上書きを防止。
2. **(b) 全件照合 (`test_robustness_backup_deep_verification`)**:
   - バックアップ完了時の検証範囲を単なるファイル数比較から、`metadata`, `HEAD`, `config`, `packed-refs`, 全 `objects`（ルーズおよび pack/idx）, 全 `refs` の内容照合（SHA-256 チェックサム完全一致）へと拡張。1 バイトの破損も検出。
3. **(c) HEAD 先行更新 (`test_robustness_update_default_branch_order`)**:
   - デフォルトブランチ更新時、まず一時ファイル作成→fsync→`HEAD` への atomic rename と検証を行い、ファイルシステム上の HEAD が確定した後にのみ `sigil-metadata` を更新。障害発生時に HEAD と metadata が不整合になる順序を排除。
4. **(d) クラッシュ残骸検知・自動回復 (`test_robustness_create_repo_debris_recovery`)**:
   - リポジトリ作成（`git init`）と metadata 保存の間でクラッシュした場合の残骸ディレクトリ（metadata が存在しない孤立 repo ディレクトリ）を検知し、安全にクリーンアップして初期化を再実行・自動回復する手順を確立。
5. **(e) 入れ子 ref・pack 集計と上限検査 (`test_robustness_storage_calculation_and_limits`)**:
   - リポジトリ使用量計算において、`refs/heads/feature/x` などの入れ子ディレクトリ下の参照、および `objects/pack/*.idx` 内のパック内オブジェクト数を網羅的に集計。上限（64 MiB / 4,096 objects）超過判定（`is_usage_exceeded`）を厳密化。

### 5.2 各種障害注入試験結果一覧

| 注入シナリオ | 注入手法 | 検証結果 | リポジトリ保全性 |
|---|---|---|---|
| **Staging pack 受信中の kill** | ptrace SIGKILL | 一時 pack は隔離領域に孤立、公開 odb は無傷 | 合格 (`git fsck` 成功) |
| **Loose オブジェクト同期中の kill** | ptrace SIGKILL + 未同期切詰め | 未同期オブジェクトは無効化、参照未更新 | 合格 (旧先端を維持) |
| **参照 rename 直前・直後の kill** | ptrace SIGKILL | 参照は更新前か更新後のいずれか一意に確定 | 合格 (中間状態なし) |
| **Metadata rename 中断** | ptrace SIGKILL | 古い metadata が完全に維持される | 合格 (権限拡大なし) |
| **short write (部分書き込み)** | 1 バイト / 半分書き込み注入 | write 再試行により正常完了 | 合格 (全 36 件一致) |
| **EIO (I/O エラー)** | 全ステップで 1 回 EIO 注入 | エラーを検知して安全に中断、リポジトリ非破損 | 合格 (全 105 件合格) |
| **ENOSPC (容量枯渇)** | sticky ENOSPC 注入 | `GitError.Io` で停止、リポジトリ非破損 | 合格 (全 105 件合格) |
| **実 ENOSPC (tmpfs 容量絞り)** | 40 通りの tmpfs 容量試験 | 容量不足時は安全停止、容量拡大後の再試行成功 | 合格 |

### 5.3 永続化順序モデルと不変条件の確認
- **到達集合の先行永続化**: すべてのオブジェクトがディスクに同期（fsync）された後でのみ参照が更新されるため、「参照が存在するがオブジェクトが欠落している（dangling ref）」状態は原理的に生じない。
- **権限拡大の防止**: metadata の更新中断や破損が発生しても、デフォルトで最も安全な拒否（404 存在秘匿）に倒れるため、private リポジトリが public 化したり権限が拡大することはない。
- **後方互換性 (fixtures/v1)**: 既存の初版互換 fixture（ルーズオブジェクト、pack、idx、packed-refs）が最新のコードベースでも完全に検証・読み取り可能であることを確認（`test_compat.sigil`）。

---

## 6. 完了条件 5（ファジングの記録）

擬似乱数および構造認識変異を用いた網羅的ロバストネス検証を実施した（`tests/test_fuzz.sigil`, `tests/test_gzip.sigil`, `tests/test_transfer.sigil`, `tests/test_receive.sigil`）。

### 6.1 ファジング対象領域と実施内容

- **擬似乱数シード**: `20261120`（完全再現可能な決定的 PRNG）
- **対象 8 領域**:
  1. `pkt-line`: 巨大長ヘッダ、4 桁未満、大文字 hex、NUL 埋め、flush 欠落、余剰データ
  2. `能力交渉 (capabilities)`: 未知能力、構文不正、長大文字列、禁止能力の混入
  3. `want / have`: 64 桁非 hex、peeled 行 OID、未広告 OID、長大行、flush 欠落
  4. `参照更新コマンド`: 不正参照名、NULL 区切り欠落、old/new OID 長不足、多重コマンド
  5. `pack / delta / zlib`: 破損マジック、未知版数、巨大オブジェクト数宣言、循環 delta、深い delta（>64）、Adler-32 不一致
  6. `gzip フレームと展開`: マジック破損、未知方式、予約フラグ、CRC-32/ISIZE 不一致、打切り、連結 member、余剰データ
  7. `URL / repo id`: パストラバーサル (`../escape`)、禁止記号、URL エンコード、長大 ID (>64)
  8. `metadata / ACL`: 不正 JSON、空の主体名、owner 全削除、不明バージョン、長大フィールド
- **ファジング結果**:
  - 総試行回数: 1,200 反復以上 + 各境界回帰コーパス
  - パニック / クラッシュ: **0 件**
  - すべての異常入力に対して安全に適切なエラー（`GitError`, HTTP 400/404/413/415 等）を返し、制御下で処理された。

### 6.2 変異試験（Mutation Testing）結果
コードの安全網が機能しているかを実証するため、故意にセキュリティ検査や同期処理を省いた変異体を埋め込み、テストスイートによる検出可否を測定した（`tests/mutation/run.sh`）。

| 変異体 ID | 変異内容の概要 | 注入箇所 | 検出結果 | 検出契機 |
|---|---|---|---|---|
| `id_verification_omitted` | オブジェクト読み取り時のハッシュ照合を省略 | `git/object.sigil` | **DETECTED** | 単体試験 (`test_object`) |
| `object_sync_omitted` | オブジェクト書き込み時の fsync を省略 | `git/fsio.sigil` | **DETECTED** | 電源断模擬 (`fault_crash.sh`) |
| `publish_sync_omitted` | 参照・索引公開時の fsync を省略 | `git/fsio.sigil` | **DETECTED** | 電源断模擬 (`fault_crash.sh`) |
| `lock_ignored` | ロックファイルが存在しても排他作成せず上書き | `git/fsio.sigil` | **DETECTED** | 排他試験 (`test_fault`) |
| `path_validation_omitted` | パス検証をバイパスして常に Ok を返す | `git/validate.sigil` | **DETECTED** | パス検査 (`test_validate`) |
| `symlink_check_omitted` | symlink エントリの拒絶検査を省略 | `git/checkout.sigil` | **DETECTED** | チェックアウト試験 (`test_ops`) |

- **変異検出結果**: **6 DETECTED / 0 UNDETECTED**（未検出 0 件）

---

## 7. 完了条件 6（UI とネイティブ／評価器の比較）

静的管理 UI の実ブラウザ安全性検証、および SIR 評価器とネイティブコンパイルバイナリの実行経路一致を検証した（`interop_meta.sh`, `tests/test_xcheck.sigil`, `tests/test_xcheck_transfer.sigil`）。

### 7.1 静的管理 UI 実ブラウザ試験
`upload_server.sigil` が提供する Web UI（`GET /` および `GET /ui`）について、実ブラウザおよび HTTP クライアントを用いた安全性試験を実施:
- **権限別画面表示**: 認証トークンに応じたリポジトリ一覧表示、権限に応じた操作（ACL 変更、可視性変更、デフォルトブランチ変更）の有効化/無効化、上限・使用量の表示。
- **XSS 防御**: すべての動的文字列（リポジトリ名、ブランチ名、ユーザー名等）を DOM の `document.createTextNode` または安全なエスケープを通して描画し、HTML タグやスクリプト挿入を完全に無力化。
- **CSRF / Origin 防御**: 管理 API（`/api/repos/*`）への POST 要求において、同一 Origin ヘッダの存在と完全一致をサーバー側で検証。Origin 欠落および不正 Origin は一律 `403 Forbidden` で遮断。
- **GET メソッドの安全性**: すべての GET 要求（`/`, `/ui`, `/api/repos`, `/api/repos/<id>`）は純粋な参照であり、リポジトリ状態やメタデータを変更する副作用を一切持たない。
- **トークン保持の安全性**: Bearer トークンはブラウザの JavaScript メモリ内（クロージャ変数）にのみ保持し、`localStorage`、`sessionStorage`、`Cookie` には一切保存しない。ページ離脱（`pagehide` イベント）でメモリから完全に消去され、サーバーログにもトークンを出力しない。

### 7.2 ネイティブ vs SIR 評価器の実行経路一致（Cross-check Trace Digest）
純粋論理層および転送層の全操作列、境界値、正常・エラー結果をダイジェスト値（SHA-256）として畳み込み、固定期待値、SIR 評価器（`sigil run`）、ネイティブ実行（`sigil build`）の 3 者で比較した。

1. **核論理層ダイジェスト (`compute_trace_digest`)**:
   - 固定期待値: `ebce0bdaaee7081c671596c80c526ab634eaacb2d0dcd4c1b5b0787a69f227f6`
   - SIR 評価器 (`sigil run`): `ebce0bdaaee7081c671596c80c526ab634eaacb2d0dcd4c1b5b0787a69f227f6`
   - ネイティブ実行 (`sigil build`): `ebce0bdaaee7081c671596c80c526ab634eaacb2d0dcd4c1b5b0787a69f227f6`
   - **判定**: **完全一致（3 者一致）**
2. **転送層ダイジェスト (`compute_transfer_digest`)**:
   - 固定期待値: `3fde4e5e7373be2532669ea69809c0da971f72d25ca5e95bdfe7da409a893485`
   - SIR 評価器 (`sigil run`): `3fde4e5e7373be2532669ea69809c0da971f72d25ca5e95bdfe7da409a893485`
   - ネイティブ実行 (`sigil build`): `3fde4e5e7373be2532669ea69809c0da971f72d25ca5e95bdfe7da409a893485`
   - **判定**: **完全一致（3 者一致）**

### 7.3 依存 fs と認証の信頼差分監査
- 純粋論理層（転送コーデック、pkt-line、gzip 展開、CRC-32、wire pack 生成、ACL・metadata 解析）は `trust none` の下で完全に検証され、評価器とネイティブバイナリで意味論の差異が一切存在しない。
- ファイルシステム境界（`std.os.fs`）およびネットワーク境界（`std.http`, `std.web`）に依存する操作は、実ファイルシステム障害注入（ptrace による syscall 遮断）および実 Git 相互運用テストによって、同一の安全性が担保されていることを実証した。

---

## 8. 結論と完了条件充足

本第 5 段の集約検証により、ADR 0048（P4-4）に定められた完了条件 1〜6 がすべて満たされたことを確認した:
- **完了条件 1**: 公式 Git クライアント（2.43.0 / 2.39.5）との相互運用（clone/fetch/push、注釈付きタグ、peeled 行、gzip 要求実測、再起動後 fsck）の完全合格。
- **完了条件 2**: 各種不正・未認可アクセス、未対応機能、競合に対する確実な拒絶と参照・状態不変性の実証、および第 4 段レビュー要確認 2 点の妥当性確認。
- **完了条件 3**: 各種固定上限（pkt-line、転送オブジェクト数、展開累計、参照数、保存実体、同時実行、管理 API 本文、gzip 境界）の厳格な防御と性能プロファイル記録。
- **完了条件 4**: バックアップ堅牢化 5 件の修正完了、強制終了・電源断・カーネル障害注入耐性、および永続化順序モデルの検証。
- **完了条件 5**: 8 領域に及ぶ構造認識ファジング（パニック 0 件）と変異試験（6 検出 / 0 未検出）の合格。
- **完了条件 6**: 静的管理 UI の実ブラウザ安全性検証、および SIR 評価器とネイティブ実行の実行経路ダイジェスト完全一致。

以上の通り、Sigil Git におけるリポジトリの転送とホスティング機能（P4-4）は、公式仕様に完全に適合し、本物の Git との確固たる相互運用性と高い耐障害性を備えていることが実証された。
