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

## 第4段「索引・add・commit・checkout・作業木の書き込み」（ADR 0047 単位4）

SHA-256 のリポジトリで、`add` → `commit` → `checkout` の一連が動きます。環境変数・設定・時計・フック・`.gitignore` は読みません。

### モジュール構成

- `git/index.sigil`: 索引 v2 の読み書き（最小）。stat 情報は信用せず（書くときは 0）、内容で判断します。検査値（SHA-256）・順序・段階（stage）・拡張フラグ・必須の拡張（小文字始まり）を検証し、拡張のうち大文字始まり（`TREE` など）は読み飛ばします。
- `git/worktree.sigil`: 作業木の読み書き。パスは書く直前に成分ごとに検査し、ディレクトリは `O_NOFOLLOW` で開き、symlink をたどりません。ファイルは一時名（`.sigil-tmp-*`、`create_new`）に書いてから rename し、実行ビットは `File.set_mode`（0644／0755 のみ）で付けます。
- `git/ops.sigil`: `add_paths`（明示したパス。ディレクトリは再帰、`.gitignore` なし、symlink は対象外）、`write_tree`、`commit`（索引 → tree → commit → 現在のブランチの更新。作者・コミッター・時刻・tz は引数、メッセージはバイト列のまま）。オブジェクトを先に永続化し、参照は `<ref>.lock` を使った compare-and-swap で更新します。`index.lock` は add/commit の間ずっと保持します。
- `git/checkout.sigil`: `checkout`（commit の識別子またはブランチ名）。変更されるパスごとに HEAD・索引・作業木・切り替え先を比べ、（a）作業木が索引と違う、（b）索引が HEAD と違う、（c）追跡外のファイルが上書きされる、のいずれかがあれば何も変えずに `Conflict`。symlink（120000）・gitlink（160000）が切り替え先にあれば、何も書く前に `UnsupportedEntry`。書き込みの順は 削除 → 置き換えるディレクトリの片付け → 書き込み → 索引 → HEAD。強制する指定はありません。

### 判断と制限

- パスの検査（`.`・`..`・空・`/`・NUL・`.git` の変種・絶対パス・バックスラッシュ・UTF-8 でない名前）は `validate_path` を作業木への書き込みの直前にも使います。上限は ADR 0047 決定 5（パス 4096・成分 255・深さ 128、索引 100000、1 回の add は 100000 ファイル、オブジェクト 64 MiB）。
- 空のディレクトリは作りません。SHA-1 のリポジトリ・bare リポジトリは `UnsupportedFormat`、分離 HEAD への `commit` も `UnsupportedFormat` です。
- `add` に symlink を明示すると `UnsupportedEntry`、ディレクトリを再帰するときの symlink・特殊ファイルは読み飛ばします。
- 実 Git との確認は `interop_ops.sh`（fsck・log・ls-tree・diff・cat-file、実 Git の clone/checkout、衝突、悪意のある tree）。

## 第5段「log・diff・merge・スナップショット」（ADR 0047 単位5）

- `git.walk.log` はコミット ID から到達可能な履歴を位相順で返します。
- `git.diff.diff_trees`／`diff_commits`／`diff_worktree` は変更パス、Git と同じ状態コード（A・D・M・T）、変更前後のモード、統一差分を返します。バイナリ差分には本文がありません。作業木差分は索引で追跡しているパスを対象にします。
- `git.apply.apply_patch` はコミットに対する Git の統一差分を読み、変更パスと結果の内容・モードを適用順に返します。削除はモード 0 です。種別変更は削除と追加になります。`apply_file_patch` はファイル単位の適用で、パスは呼び出し元が指定します。
- `git.merge.merge` は指定コミットを現在のブランチに三方向併合します。併合が成立したら二親コミットを書き、作業木・索引・参照を更新します。すでに取り込み済みなら `AlreadyUpToDate`、交差する最良共通祖先があれば `MultipleMergeBases` を返します。内容の衝突ではパスと種類を返し、作業木・索引・参照・オブジェクトを変更しません。
- `git.snapshot.snapshot` はコミットの木のパス・モード・blob ID を `git ls-tree -r` 順に返します。`read_snapshot_blob` は選んだ blob を読みます。どちらも作業木への書き込みはありません。

| 条件 | 動作 |
|---|---|
| 改名と編集が競合する | 改名前のパスを削除／変更の衝突として返す。Git が改名検出で併合できる場合がある |
| バイナリ差分 | 差異を報告し、本文の生成・適用は対象外 |
| 作業木上の symlink | `UnsupportedEntry`。リンク文字列を読む標準ライブラリ API は goodnasubi/sigil#632 |
| コミット木上の symlink | 種別変更と読み取りは対応。併合による作業木への展開は第4段の checkout の規則を適用 |
| 履歴・木の走査、パッチ、行単位併合が作業メモリを超える | `LimitExceeded`。行単位併合は最長共通部分列の表を使用し、表を確保する前に大きさを検査 |

第5段で使用した Sigil コンパイラの固定 SHA は `33467e3b43238fdc69331c58a788c95f1de393e5` です。相互運用の比較版は Git **2.43.0** です。`interop_history.sh` は履歴・木・blob・差分の比較、テキストパッチの双方向適用、併合の木、衝突時の無変更、および上限エラーを検査します。

## 転送 第1段「転送 codec と wire 専用 pack 出力」（ADR 0048）

転送（clone／fetch／push）の土台になる、符号化・復号と pack 出力です。upload-pack の要求処理、隔離受信、push は後続の段で扱います。詳細は [docs/TRANSFER.md](docs/TRANSFER.md)。

- `git/pktline.sigil`: pkt-line の符号化・復号（プロトコル v0。4 桁の小文字 hex、`0000` flush、1 つ 65520 byte まで。delimiter／response-end は拒否）。
- `git/transfer.sigil`: 能力広告（upload-pack は `object-format=sha256`・`symref`・`side-band-64k`、receive-pack は `object-format=sha256`・`report-status`・`ofs-delta`）、注釈付きタグの peeled 行、空リポジトリの `capabilities^{}`、対応表（既定は拒否）。
- `git/wirepack.sigil`: 明示した識別子の集合から、非 thin・非 delta・zlib stored の pack v2 を作ります（転送の応答専用。ローカルへは保存しません）。
- 上限（`git/limits.sigil`）: pkt-line 65520 byte、オブジェクト 4096、応答 1 MiB、広告する参照 1024、グラフ走査 100000 件。超えるときは自動分割も再試行もせず `LimitExceeded` です。

## 転送 第2段「upload-pack」（ADR 0048、Issue #11）

スマート HTTP v0 の upload-pack（参照広告、want／have／done、wire 専用 pack v2 応答、gzip 要求）です。詳細は [docs/UPLOAD_PACK.md](docs/UPLOAD_PACK.md)。

- `git/upload.sigil`、`git/gzip.sigil`、`git/crc32.sigil`、`git/acl.sigil`、`upload_server.sigil`（HMAC Bearer・固定 ACL の HTTP サーバー）。
- 実 Git の確認: `SIGIL=... STAGE5_GIT=... ./interop_upload.sh`

## テストの実行

前提として、Sigil コンパイラ（固定版コミット `33467e3b43238fdc69331c58a788c95f1de393e5`）が利用可能である必要があります。

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
SIGIL=/path/to/sigil STAGE5_GIT=/path/to/git ./interop_history.sh  # 第5段
SIGIL=/path/to/sigil STAGE5_GIT=/path/to/git ./interop_transfer.sh  # 転送 第1段: 広告を実 Git と比較、pack を index-pack --strict・verify-pack・fsck で検証
```
