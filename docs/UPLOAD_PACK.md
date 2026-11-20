# upload-pack（転送 第2段、ADR 0048 / Issue #11）

スマート HTTP v0 の upload-pack を、固定の HMAC Bearer 検証（ADR 0037）と最小の固定 ACL の下で提供します。receive-pack・push は含みません。

## 構成

| ファイル | 内容 |
| --- | --- |
| `git/upload.sigil` | 参照広告（`GET /repos/<id>/info/refs?service=git-upload-pack`）、want／have／done、side-band-64k の wire 専用 pack v2 応答、POST の入口（`upload_pack_post`） |
| `git/gzip.sigil`, `git/crc32.sigil` | gzip 要求の復号（単一メンバー、CRC-32／ISIZE、上限）と ADR 0052 の固定理由・HTTP 状態 |
| `git/inflate.sigil` | `inflate_deflate` を追加。後方距離を宣言窓（gzip は 32 KiB、zlib は CINFO）に結びつけた |
| `git/acl.sigil` | 固定 ACL（`repo:sub,sub;repo2:sub`）。本物の ACL ではない |
| `upload_server.sigil` | HTTP サーバー（std.http の `serve_conn` と std.web の Router による認証） |
| `interop_upload.sh` | 実 Git（SHA-256）での clone／fetch と拒否の確認 |

## 動作

- 参照広告: 第 1 段の能力広告を再利用（`# service=git-upload-pack` と flush を前置、全体 1 MiB 以下）。`service` が無い・違う・重複・余分な問い合わせ文字列は 400。
- want は広告した実際の参照の先端だけ（peeled 専用の識別子は不可）。良い want と悪い want が混じれば全体を拒否。have は公開した履歴にあるものだけが共通で、未公開・存在しないものは区別できない同一の応答。
- pack は完全な到達集合（stored の zlib、非 delta、pack v2）。side-band-64k では channel 1 に pack、失敗は channel 3、最後に flush。応答全体が 1 MiB 以下であることを送信前に確認する。
- **ACK／NAK**: `done` の要求では最初の共通 have に ACK、無ければ NAK。`done` の無い要求（have の束＋flush）は、共通があっても **NAK だけ**を返す（下の「所見」）。
- 未対応は明示的に拒否（pack を作らない）: v1／v2 のコマンド、SHA-1、thin pack、shallow／deepen、partial clone／filter、未知の能力。

## 上限

| 項目 | 値 |
| --- | --- |
| pkt-line | 65520 |
| オブジェクト数 | 4096 |
| 累積の inflate | 16 MiB（単体 8 MiB） |
| 応答 | 1 MiB |
| 参照 | 1024 |
| 履歴の探索 | 100000（1 MiB の応答上限の下では実際には到達しない） |
| gzip 要求 | 復号後 1 MiB、符号化後 2 MiB |

## gzip 要求と ADR 0052

POST の `git-upload-pack` だけが `Content-Encoding: gzip` を受理する。認証・認可の後に復号し、全体を検証し終えるまで何も処理しない。

| 入力 | 状態 | 理由 |
| --- | --- | --- |
| 不正な見出し・方式・予約フラグ・CRC／ISIZE 不一致 | 400 | `invalid_compressed_data` |
| 途中で切れた入力 | 400 | `truncated_compressed_data` |
| 事前設定辞書 | 400 | `unsupported_preset_dictionary` |
| 連結メンバー・末尾の余り | 400 | `trailing_compressed_data` |
| 復号後 1 MiB 超（復号の途中）／符号化後 2 MiB 超 | 413 | `compression_limit_exceeded` |
| `x-gzip`・`deflate`・複数／列挙の符号化 | 415 | `unsupported_content_encoding` |

試験: `tests/test_gzip.sigil`（Python で作ったベクタ、全接頭辞の切断、窓の境界）、`interop_upload.sh`（curl での分類確認）。

## 実 Git での確認（git 2.43.0、`interop_upload.sh`）

空リポジトリの clone、最初の clone、新しいコミット後の増分 fetch、注釈付き／軽量タグ、gc 済み（pack・delta）、既定の v2 要求から v0 への戻り、`-c protocol.version=0`、gzip の fetch。いずれも `git fsck --strict`・`log`・`diff` で確認。認証失敗（401）、ACL 外・不明リポジトリ（404）、shallow／filter の拒否、gzip の拒否分類も確認。

gzip の大きさの記録（実 Git が 16 個超の have を送る fetch、`encoded` は符号化後、`decoded` は復号後）:

| 要求 | encoded | decoded |
| --- | --- | --- |
| fetch の第 1 回 | 705 | 1280 |
| fetch の第 2 回 | 698 | 1280 |
| 小さい identity 要求（clone） | 323 | — |

## 評価器とネイティブの照合

`test_runner.sigil` は SIR 評価器とネイティブの両方で同じ試験列を走らせ、結果が一致することを `test.sh` が確認する（評価器: ALL TESTS PASSED、ネイティブ: 下の PR 本文に記録）。

## 所見・制限（Issue #11 へ報告）

- 基本の ACK（multi_ack 無し）の stateless な HTTP では、実 Git の利用側は have の束への ACK を「共通が見つかった」と読み、次の `done` の要求（have を再送しない）の応答の先頭に ACK／NAK が無いものとして pack を読む。そのため `done` の無い要求に ACK を返すと、16 個超の have を送る fetch が `bad band #78` で壊れる。対策として `done` の無い要求には常に NAK を返す（利用側は have を尽くしてから `done` を送る）。
- `open_repo` は commit-graph・ビットマップを持つリポジトリを拒否する（既存の方針）。`git gc` の既定はこれらを書くため、試験では無効にして gc している。
- std.web の `AppRequest` は生の問い合わせ文字列を持たず、Router のハンドラは `fs` 効果を持てない。そのため問い合わせの事前検査と ACL・リポジトリの読み取りはサーバー側で行い、認証だけを Router に通している。
- std.http は本文をハンドラの前に読むため、`with_body`／`with_encoded_body` を 2 MiB／2.06 MiB に上げ、identity の 1 MiB 上限はハンドラで強制している。
- 履歴の探索上限 100000 は、応答 1 MiB・オブジェクト 4096 の下では到達できない。
- 範囲外（修正していない）: receive-pack・隔離受信・push（第 3 段）、metadata／本物の ACL・管理 UI（第 4 段）、比較・故障注入・ファジング（第 5 段）、ADR 0052 適合差分の残り（ローカル loose／pack の 80 MiB 入力上限、pack index の CRC）、新しい標準 API、ローカルの pack 保存／repack／gc。
