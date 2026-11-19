# sigil-git

Sigil で書かれたリポジトリ管理の核（goodnasubi/sigil の P4 段階、ADR 0044・ADR 0047）。
純 Sigil（`trust none`）で実装されています。

## 第1段「純粋な核」（ADR 0047 単位1）

ADR 0047 に基づく、Git オブジェクトと参照・パスの純粋なデータモデルおよび検査処理を提供します。

### モジュール構成

- `git/limits.sigil`: ADR 0047 決定5 で定められた各上限値の定義。
- `git/error.sigil`: リポジトリ操作で発生するエラー型（`GitError`）。
- `git/hash.sigil`: SHA-256 識別子計算（ヘッダ＋内容）、hex 相互変換。
- `git/object.sigil`: オブジェクト型（blob, tree, commit, tag）、ヘッダ `<型> <長さ>\0` の復号・検証・符号化、SHA-256 識別子再計算照合。
- `git/tree.sigil`: tree エントリの復号・符号化、並び順比較（ディレクトリ末尾スラッシュ規則）、名前検証、ソート・重複検査。
- `git/commit.sigil`: commit オブジェクトの解析・符号化、tree/parent/author/committer/追加ヘッダ/メッセージの往復。
- `git/tag.sigil`: 注釈付き tag オブジェクトの解析・符号化。
- `git/validate.sigil`: パス検証（全長、構成要素長、深さ、禁止文字・変種）、参照名検証（Git check-ref-format 規則）。
- `git/fixture.sigil`: 本物の Git 2.43.0 (`--object-format=sha256`) が生成したオブジェクト fixture データ。

## 第2段「オブジェクトの保存と参照、init とロック」（ADR 0047 単位2）

SHA-256 形式のリポジトリの作成（`init`）、緩いオブジェクトの書き込みと存在・型・長さの照会、HEAD・ブランチ・軽量タグの作成・更新・削除・一覧を提供します。実 Git（2.43.0）で `git fsck --strict --full` と `git cat-file` が通ることを `interop.sh` で確かめます。

### モジュール構成

- `git/fsio.sigil`: ファイル境界（ADR 0049）の薄い包み。排他作成、同期、rename、親ディレクトリの同期、ロックファイルの作成と公開、ディレクトリ列挙。
- `git/zlib.sigil`: Adler-32 と zlib の stored ブロックの符号化・復号（伸長は `git/inflate.sigil`）。
- `git/repo.sigil`: `init_repo`（通常・bare、最小の設定、HEAD を最後に公開）と `open_repo`（SHA-1・reftable・alternates・shallow・worktrees・.git ファイル・replace・promisor・疎なチェックアウト・分割索引を `UnsupportedFormat` で拒否）。
- `git/odb.sigil`: `odb_write`（一時ファイル→同期→rename→親の同期。既存は内容を検証し、存在だけを信用しない）、`odb_has`、`odb_info`（型と長さ）。
- `git/refs.sigil`: `update_ref`（`<ref>.lock` の排他作成と旧値の比較）、`delete_ref`（`packed-refs.lock` も取り、packed 側を先に消してから緩い参照を消す）、`create_branch`/`create_tag`/`delete_*`/`list_*`、HEAD の読み書き、packed-refs の解析と再出力（ヘッダと `^` の peeled 行を保つ）。

### 制限と範囲

- 新しい上限: 参照 100000、packed-refs 64 MiB、作業メモリ 256 MiB（`git/limits.sigil`）。超過は専用のエラーで、黙って切り詰めません。
- 緩いオブジェクトの内容の取得は第3段の `git/inflate.sigil` で行います（第2段の時点では Huffman 圧縮は `UnsupportedFormat` でした）。
- 古い一時ファイル（`tmp_obj_*`、`*.lock`）は自動では消しません。ロックが残っていれば `Locked` を返します。
- pack の読み取り、index/add/commit、gc/repack、reflog、フックなどは範囲外です。

## 第3段「pack と pack index の読み取り」（ADR 0047 単位3）

実 Git が作る pack（`objects/pack/pack-*.pack`）と pack index v2（`pack-*.idx`）を読みます。pack 全体はメモリに載せず、`File.read_at` で必要な範囲だけを読みます。

### モジュール構成

- `git/inflate.sigil`: zlib の伸長（stored・固定 Huffman・動的 Huffman）。出力は呼び出し側が与える上限を超えず、Adler-32 を検証し、ストリームが使った長さを返します。
- `git/pack.sigil`: `open_pack`（`.idx` の末尾の検査値と pack の末尾の検査値を検証し、両者が同じ pack を指すことを確認）、`pack_read`/`pack_read_index`（型・内容。復元後に識別子を再計算して `.idx` と照合）、OFS_DELTA/REF_DELTA の解決（連鎖の深さ 64、循環は `Corrupt`、復元後 64 MiB、作業メモリ 256 MiB）。
- `git/odb.sigil`: `odb_read`/`odb_read_in`（緩い形式と pack を同じ入口で読む。緩い形式を先に探す）、`open_packs`。`odb_has`/`odb_write` は pack も見ます。
- `git/walk.sigil`: `git log --topo-order` と同じ並びの履歴、`git ls-tree -r` と同じ並びの展開、`git diff-tree --name-status` と同じ形の差分（名前変更の検出なし）。本物の Git との比較のための読み取り専用の走査です。
- `git/fsio.sigil`: `open_read`/`read_range`/`sha256_range`/`file_size` を追加。

### 判断と制限

- **`crc32` 欄は使いません。** オブジェクトの識別子（SHA-256）を読み取りのたびに再計算して `.idx` と照合するほうが強い検証で、純 Sigil の crc32 を足す理由が無いためです（ADR 0047「前提と持ち越し」4）。
- **未対応は明示的に拒否します。** `.idx` v1・未知の version、SHA-1 形式の `.idx`、`multi-pack-index`、`*.bitmap`、`commit-graph` は `UnsupportedFormat`（`open_repo`/`open_pack`）。本物の Git で `gc` したリポジトリを読むときは、これらを作らない設定（`gc.writeCommitGraph=false`、`repack.writeBitmaps=false`、`core.multiPackIndex=false`）が前提です（`interop_pack.sh` が設定しています）。
- **pack の大きさ・オブジェクト数の上限**（4 GiB・2^24）と **差分の深さ**（64）は `git/limits.sigil`。宣言された大きさは割り当ての前に検査し、offset の加算・乗算の溢れは拒否します。
- **ファイルの大きさ**は標準ライブラリに `File` の大きさを得る API が無いため、位置指定の 1 byte 読み取りで EOF を二分探索して求めています（`fsio.file_size`）。API が入ったら置き換えます。
- pack には圧縮後の長さが書かれていないため、圧縮済みデータは 64 KiB の窓から読み、ストリームが窓の末尾で切れていれば窓を 4 倍にして読み直します。窓の上限は宣言された展開後の大きさから決まる値（大きさ + 1/8 + 256 byte）です。zlib が書く最悪の場合は固定 Huffman の 9 bit/文字（9/8 倍）で、stored でも 5 byte/16 KiB 程度なので、Git が書く zlib はこの範囲に収まります。これを超えて水増しされた zlib ストリームは `Corrupt` になります。
- 読み取りのたびに `.idx`・pack を開き直します。多数を読むときは `open_packs` と `odb_read_in` を使ってください（pack の末尾の検査値の検証は `open_pack` で 1 回だけ行います）。
- pack の書き込み、`repack`/`gc`/`prune`、thin pack（pack 外の基点を持つ REF_DELTA）は範囲外です。

## テストの実行

前提として、Sigil コンパイラ（固定版コミット `a2ccf0e086b4d7043ba89a740c840c550a4616fb`）が利用可能である必要があります。

```bash
# 全体テストの実行（fmt, check, SIR 評価器, ネイティブバイナリビルド＆実行）
./test.sh

# 個別実行
sigil run --root . test_runner.sigil main
```

実 Git との相互運用テスト（Git が必要。バージョンは出力の先頭に記録されます）:

```bash
SIGIL=/path/to/sigil ./interop.sh        # 第2段: init・書き込み・参照
SIGIL=/path/to/sigil ./interop_pack.sh   # 第3段: gc 済みの pack の読み取り（オブジェクト・log --topo-order・ls-tree -r・diff）
```
