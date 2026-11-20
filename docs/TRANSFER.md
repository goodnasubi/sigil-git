# 転送 第1段「転送 codec と wire 専用 pack 出力」の検証記録（ADR 0048）

Issue: goodnasubi/sigil-git#8（P4-4 実装 第1段）。範囲は、pkt-line の符号化・復号、能力広告の生成、wire 専用 pack v2 の出力、固定上限、対応表の未対応の明記。clone／fetch／push の接続試験は後続の段。

## 1. 構成

| モジュール | 内容 |
|---|---|
| `git/pktline.sigil` | `pkt_encode`・`pkt_flush`・`pkt_read`・`pkt_decode_section` |
| `git/transfer.sigil` | `advertise_upload_pack`・`advertise_receive_pack`・`collect_adv_set`（リポジトリから参照を集める）・対応表（`check_transfer_feature`・`check_requested_capabilities`） |
| `git/wirepack.sigil` | `wire_pack_build`（識別子の集合から pack v2） |
| `git/limits.sigil` | 追加した固定上限 |

標準 API の追加はありません（`File`・`Bytes`・`Sha256` など既存のものだけ）。圧縮は既存の `git/zlib.sigil` の `zlib_stored` を再利用し、新しい圧縮実装は足していません。

## 2. 仕様の要点

### pkt-line（プロトコル v0）
- 長さは 4 桁の小文字 hex で、長さ自身の 4 byte を含みます。`0000` は flush。1 つの pkt-line は 65520 byte まで（超えると `LimitExceeded`。自動分割はしません）。
- 拒否（固定の理由）: 桁が足りない・hex でない・大文字 hex・`0003`・`0004`（内容が空）・内容が足りない・flush が無い・flush の後の余剰データは `Corrupt`。`0001`（delimiter）と `0002`（response-end）は v0 に無いので `UnsupportedFormat`。
- 内容が空の pkt-line（`0004`）は Git では読めますが、v0 の広告・要求では使われないため、この実装では拒否しています。

### 能力広告
- upload-pack: `object-format=sha256`、`symref=HEAD:refs/heads/<default>`（HEAD が生まれていて、指すブランチがあるときだけ）、`side-band-64k`。HEAD を先頭に、参照を名前の昇順に並べ、注釈付きタグ（`refs/tags/*`）の直後に、タグを再帰的に剥いだ非 tag オブジェクトの peeled 行（`^{}`）を置きます。軽量タグには付けません。
- receive-pack: `object-format=sha256`、`report-status`、`ofs-delta`。HEAD・symref・peeled 行は出しません。
- 空のリポジトリ（参照が無い）は、ゼロ識別子と `capabilities^{}` の行に能力を載せます。
- 実装していない能力（`multi_ack`・`thin-pack`・`shallow`・`deepen*`・`filter`・`no-done`・`include-tag`・`agent` など）は広告しません。
- 広告に渡す参照は、名前（`refs/heads/`・`refs/tags/` 以下で check-ref-format を満たす）・識別子・昇順かつ重複なしを検査し、違えば `Corrupt`／`InvalidRefName`。peeled はタグだけ。
- `collect_adv_set` は、各参照が指すオブジェクトが存在し（0047 の核で識別子を再計算して検証）、ブランチは commit であることを確かめます（違えば `TypeMismatch`）。分離 HEAD は HEAD 行だけで symref は付けません。

### wire 専用 pack v2
- 先頭 `PACK`・版 2・件数・オブジェクト群・全体の SHA-256。種別 1〜4（commit・tree・blob・tag）だけで、delta は出しません。各オブジェクトの zlib は stored ブロックだけです。
- 重複は除き、与えた順に並べます。決定的です（同じ入力は同じバイト列）。
- 渡された識別子ごとに、0047 の核で読んで識別子を再計算して検証し、型ごとに内容を解読します（commit・tree・tag）。参照するオブジェクト（commit の tree と親、tree のエントリ（gitlink を除く）、tag の対象）の**存在**を確かめ、tag は対象の**型**も宣言と一致するか読んで確かめます。無ければ `NotFound`、型が違えば `TypeMismatch`。
- 応答の大きさは、作る前に見積もります。1 MiB を超える見込みなら、何も作らず `LimitExceeded` です。
- 転送の応答専用です。ローカルへの保存・repack・gc には使いません。

## 3. 固定上限（ADR 0048 決定 2）と、直下・一致・超過の確認

| 上限 | 値 | 直下／一致 | 超過 |
|---|---|---|---|
| 1 pkt-line | 65520 byte | 65520 を符号化・復号できる | 65521 を符号化できず、宣言 65521 を復号できない（`LimitExceeded`） |
| オブジェクト数 | 4096 | 4096 個（重複）が通る | 4097 個は pack を作らず `LimitExceeded` |
| 応答 | 1 MiB（1048576 byte） | pack がちょうど 1048576 byte（blob 1048442 byte）／広告がちょうど 1048576 byte が通る | pack で 1 byte 超（blob 1048443 byte）／広告で 1 byte 超は `LimitExceeded` で、何も返さない |
| 広告する参照 | 1024 | 1024（HEAD 込みなら 1023 ＋ HEAD） | 1025 は `LimitExceeded`（receive-pack も同じ） |
| グラフ走査 | 100000 件 | 予算ちょうど（commit 2 件・tree 2 件・tag 1 件・タグを剥がす 5 件）が通る | 1 件足りないと `LimitExceeded` |

注意: **グラフ走査の 100000 件は、1 MiB の応答の上限があるので、wire pack では実際には到達しません**（1 MiB の stored pack に入る参照は 3 万件程度）。小さい予算を渡せる `wire_pack_build_limited`／`collect_adv_set_limited` で境界を試しています。固定の 100000 は防御的な上限として置いてあります。

オブジェクト数 4096 は、与えた識別子の件数（重複を含む）で判定します。重複を除く前に判定するので、4097 個の重複だけの入力も拒否されます（上限を避けて分けて処理しない、という決定どおり）。

## 4. 対応表（既定は拒否）

`check_transfer_feature` は、対応している機能（`protocol-v0`・`object-format=sha256`・`side-band-64k`・`symref`・`report-status`・`ofs-delta`・`peeled-tag`・`pack-v2`）だけを通し、それ以外は未対応と明記したものも未知のものも `UnsupportedFormat` で拒否します（黙って成功させない）。未対応の明記:

v1／v2 の専用コマンド（`protocol-v1`・`protocol-v2`・`command=ls-refs`・`command=fetch`）、SHA-1（`object-format=sha1`）、SSH、dumb HTTP、thin pack、shallow／deepen（`deepen-since`・`deepen-not`・`deepen-relative`）、partial clone／filter、任意 OID の取得（`allow-tip-sha1-in-want`・`allow-reachable-sha1-in-want`）、複数参照 push、atomic push、参照削除、force push、push-options、署名 push（`push-cert`）、LFS、サブモジュールの再帰取得、hooks。ほかに、実装していない v0 の能力（`multi_ack`・`multi_ack_detailed`・`no-done`・`side-band`・`include-tag`・`no-progress`・`agent`）も未対応です。

`check_requested_capabilities` は、クライアントが要求する能力が、そのサービスの広告にあるものだけかを検査します（広告に無いもの、`symref` を含む、は `UnsupportedFormat`）。

## 5. 検証と結果

| 確認 | 方法 | 結果 |
|---|---|---|
| pkt-line・広告・対応表・上限 | `tests/test_transfer.sigil`（正常例・不正例・境界） | 全合格 |
| wire pack・リポジトリからの広告 | `tests/test_wirepack.sigil` | 全合格 |
| 実 Git との広告の一致 | `interop_transfer.sh` A: 空・loose refs・packed-refs・分離 HEAD で、`git upload-pack --advertise-refs`・`git receive-pack --advertise-refs` の参照行（HEAD・ブランチ・タグ・peeled 行）と完全に一致。私たちの能力は実 Git が広告する能力の部分集合で、期待する文字列と等しい。実 Git の広告を私たちの pkt-line の復号が受理する | 全合格（Git 2.43.0） |
| 実 Git が pack を受理 | `interop_transfer.sh` B: 24 オブジェクト（commit 6・tree 8・blob 8・tag 2、入れ子のタグを含む）の pack を `index-pack --stdin --strict`・`unpack-objects --strict`・`verify-pack -v`（非 delta 24 件、delta なし）・`fsck --strict --full` が受理。全オブジェクトの型・長さ・内容が一致。python で版 2・件数・種別 1〜4・すべて stored・SHA-256 の検査値を確認 | 全合格 |
| 拒否 | `interop_transfer.sh` C: 存在しないオブジェクトと 4097 個は pack を作らず失敗、4096 個は成功 | 合格 |
| 0047 の核との突き合わせ | `tests/test_xcheck_transfer.sigil`: 決定論的な操作列・エラー・上限の結果を 1 つのダイジェストにし、SIR 評価器とネイティブと固定した期待値（`3fde4e5e…3485`）が一致。`test.sh` の 6b。これとは別に、`test_runner.sigil` 全体も評価器とネイティブの両方で実行される | 3 者一致 |

## 6. 限界と所見（修正はしていません）

- 参照先の**型**の確認は tag の対象だけです。commit の tree・親、tree のエントリは存在だけを確かめます（型は、そのオブジェクトを pack に含めるときに検査されます）。接続（閉じた集合かどうか）の確認は、渡す集合を決める後段（upload-pack の交渉）の責務です。閉じていない集合は、実 Git の `index-pack --strict` が拒否し、通常の `index-pack` は受理することを確認しました。
- `sideband` の枠づけ、`service=` の前置き、`want`／`have`／`done`、gzip・CRC-32 は範囲外（第2段以降）です。応答 1 MiB は、この段では pack 本体と広告本体の大きさに適用しています。後段が枠づけを足したときに、枠づけを含めた大きさで再確認が要ります。
- 評価器での実行時間: `tests/test_wirepack.sigil` は 1 MiB のオブジェクトを数回扱うため、評価器で 40 秒ほどかかります（`adler32` が 1 byte ずつの繰り返しのため）。圧縮は本段の範囲外なので手を入れていません。
- 能力の文字列に `agent=` は付けていません（実 Git は付けますが、広告するのは実装した能力だけという方針のため）。
- pkt-line の `0004`（内容が空）は拒否しています（上記）。実 Git のクライアントがこれを送ることは通常ありません。

## 7. 後段への引き継ぎ（この段では未着手）

- 第2段（upload-pack）の開始前に、圧縮の契約 ADR の起票・決定が必要（Issue #8 に記載のとおり）。gzip の受理と CRC-32 は第2段。
- `service=git-upload-pack` の前置き行（smart HTTP）は、広告本体の前に置く転送層の責務として、この段では作っていません。
