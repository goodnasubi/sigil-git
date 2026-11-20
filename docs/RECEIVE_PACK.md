# receive-pack（転送 第3段「隔離受信と単一参照 push」、ADR 0048 / Issue #13）

スマート HTTP v0 の receive-pack です。1 要求で 1 つの参照（`refs/heads/*` か `refs/tags/*`）だけを更新します。

## 構成

- `git/recvpack.sigil`: pack の隔離検証。ヘッダ（"PACK"・版 2・件数）、SHA-256 の末尾検査値、各エントリの zlib（宣言された大きさと一致すること）、OFS／REF_DELTA の解決（0047 の `apply_delta`・`max_delta_depth`）、識別子の再計算、重複の除去。リポジトリには触れない。
- `git/receive.sigil`: 要求の解読、方針、閉包の検証、排他の下の再検査と公開、report-status、受信広告。
- `git/acl.sigil`: 書き込み権限 `can_write`（仕様は `repo:sub,sub=rw;repo2:sub`。`=rw` が付いた項目は read＋write、付かない項目は read のみ）。
- `upload_server.sigil`: `GET /repos/<id>/info/refs?service=git-receive-pack` と `POST /repos/<id>/git-receive-pack`。環境変数 `SIGIL_GIT_ACL_FILE` があれば要求ごとに ACL を読み直す。

## 動作

1. **広告**: 第1段の能力（`object-format=sha256`・`report-status`・`ofs-delta`）。peeled 行なし、HEAD・symref なし。空のリポジトリはゼロ識別子＋`capabilities^{}`。`service` が無い・重複・余分な query・別 service は 400。
2. **要求の解読**: 1 行のコマンド `old new ref\0 caps`（実 Git は能力の前に空白を 1 つ置く）→ flush → pack。能力は `report-status` が必須。`atomic`・`push-options`・`side-band-64k`・`agent`・`quiet`・SHA-1 の `object-format`、`shallow`／`push-cert` 行は未対応として `ERR`。2 つ目のコマンドがあれば複数参照として全体を拒否。
3. **方針**（pack を読む前）: `refs/heads/*`・`refs/tags/*` 以外、不正な参照名、削除、タグの上書き（old がゼロ以外のタグ）を `ng`。
4. **隔離検証**: pack を `sigil-staging/<乱数>.pack` に私的に置き、`recv_pack_parse` で検証する。thin pack の外部基底は `thin_pack`。`new` から辿る閉包が「受信集合＋リポジトリの検証済みオブジェクト」で完結していること（欠落は `missing_objects`、型の不正は `bad_object`）、branch の先端が commit であること（`not_a_commit`）、既存 branch は `old` が `new` の祖先であること（`non_fast_forward`）。検証中のオブジェクトはリポジトリの loose／pack に無いので upload-pack からは読めない（`odb_has` で確認）。到達する受信オブジェクトだけを公開の対象にする。
5. **公開**: リポジトリの排他（`sigil-receive.lock`）を取り、最新の ACL（403／404）・方針・旧値の CAS（違えば 409）を再検査してから、到達オブジェクトを `odb_write`（loose、同期・原子的、親ディレクトリも同期）、その後にだけ単一参照を `update_ref`（`.lock`、同期、rename、ディレクトリ同期）する。DB の WAL は強制しない。
6. **report-status**: `unpack ok` ＋ `ok <ref>` は、オブジェクトの同期→参照の同期の後にだけ返す。拒否は参照を変えない。方針の拒否は `unpack skipped` ＋ `ng <ref> <理由>`、pack の失敗は `unpack <理由>` ＋ `ng <ref> unpack_failed`、検証後の拒否は `unpack ok` ＋ `ng <ref> <理由>`。
7. **保存の失敗**: HTTP 500 とし、`sigil-quarantine` を置いてそのリポジトリの使用を止める（以後の要求は 503 `repository_unavailable`）。復旧の検証が済むまで再開しない。参照の公開前に拒否・失敗したときに保存済みの到達不能オブジェクトは、容量に数え、安全に消去したとは主張しない。
8. 応答の消失は「結果不明」であり、旧値の不一致を成功として扱うことはない（再送は 409）。

## 固定理由と HTTP 状態の対応

| 場面 | HTTP | 本体 |
|---|---|---|
| 認証失敗 | 401 | （std.web） |
| 非公開で read 権限なし／存在しない | 404 | `not found` |
| read はあるが write なし | 403 | `forbidden` |
| `Content-Encoding` が identity 以外（gzip を含む）／`Content-Type` 違い | 415 | `unsupported_content_encoding`／`unsupported_media_type` |
| 本文 1 MiB 超 | 413 | `request_too_large` |
| 旧値の不一致・ロック競合・既存参照の新規作成 | 409 | `conflict` |
| 要求の形式不正・query の不正 | 400 | 固定理由 |
| 保存の失敗 | 500 | `storage_failure`（以後 503） |
| 使用停止中のリポジトリ | 503 | `repository_unavailable` |
| 開始後の拒否（Git 応答） | 200 | `ERR …` または `ng <ref> <理由>` |

`ng` の理由: `unsupported_ref`・`invalid_ref`・`delete_not_allowed`・`tag_exists`・`multiple_refs`・`not_a_commit`・`non_fast_forward`・`missing_objects`・`bad_object`・`walk_limit_exceeded`・`unpack_failed`（unpack 行に `bad_pack`・`thin_pack`・`unsupported_pack`・`pack_limit_exceeded`）。

## 固定上限

要求本文 1 MiB、応答 1 MiB、pkt-line 65520、オブジェクト 4096、展開累計 16 MiB、単体 8 MiB、参照 1024、グラフ走査 100000、差分の深さ 64（0047）。Git 処理の同時実行は全体 2・リポジトリごと 1 だが、サーバーは接続を 1 つずつ順に処理するため満たされ、プロセス間はリポジトリのファイルロックで排他される。超過は自動分割・再試行・検証の省略をせず、明示的に失敗する。

## 未対応の機能（明示的に拒否）

v1／v2 コマンド、SHA-1、SSH、dumb HTTP、thin pack、shallow／deepen、partial／filter、複数参照、atomic push、参照の削除、force push（非 ff・タグ上書き）、push-options、signed push、LFS、submodule の再帰、hook。

## 試験

- 単体: `tests/test_receive.sigil`（要求の解読・方針、pack の検証、広告、push の成功と拒否、HTTP 層と上限の直下／一致／超過、隔離・ロック・ACL の再検査・CAS）。
- 実 Git: `interop_receive.sh`（git 2.43.0、SHA-256）。初回 push、fast-forward、新規ブランチ、軽量・注釈付きタグ、clone 後の push、`-c protocol.version=0` の各後に公開側で `fsck --strict`・`log`・`diff`。拒否（削除・タグ上書き・非 ff・複数参照・atomic・SHA-1・未知の能力・thin pack・旧値不一致・gzip）の後に参照が不変であること。401／403／404、ACL の変更との競合、本文 1 MiB 超・4096 超のオブジェクトの拒否と、上限の下の成功。
- 評価器とネイティブの照合: 受信テストを SIR 評価器とネイティブの両方で走らせ、出力（各区分の進行と結果 0）が一致することを記録した。

## 所見・制限（Issue #13 へ報告）

- **実 Git は既定で thin pack を送る**: 差分になる更新（大きいファイルの一部変更など）の増分 push は `thin_pack` で拒否される（Issue の仕様どおり）。Git 2.43 は HTTP で `--no-thin` を効かせず（`pack-objects --thin` のまま）、利用側で避けるには差分の探索を切る（`-c pack.window=0`）しかない。受信側の既存オブジェクトを基底に取る（`index-pack --fix-thin` 相当）かどうかは、仕様の変更を伴うので判断を仰ぎたい。
- 評価器で、リストの要素をそのまま関数の戻り値にすると別名が残り、値が壊れる事象があった（`v` → `v + 0` で回避、`git/recvpack.sigil`）。言語処理系側の確認が要る。
- 同時実行の上限は逐次処理で満たしており、並行処理の実装は第 4 段以降。ACL はファイルを要求ごとに読み直す固定の表で、本格的な ACL・メタデータ・管理 UI は第 4 段。
- 範囲外（修正していない）: upload-pack（第 2 段）、metadata／ACL／管理 UI（第 4 段）、比較・故障注入・ファジング（第 5 段）、新しい標準 API、ローカルの pack 保存／repack／gc。
