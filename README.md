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
- `git/zlib.sigil`: Adler-32 と zlib の stored ブロックの符号化・復号（Huffman 圧縮は未対応）。
- `git/repo.sigil`: `init_repo`（通常・bare、最小の設定、HEAD を最後に公開）と `open_repo`（SHA-1・reftable・alternates・shallow・worktrees・.git ファイル・replace・promisor・疎なチェックアウト・分割索引を `UnsupportedFormat` で拒否）。
- `git/odb.sigil`: `odb_write`（一時ファイル→同期→rename→親の同期。既存は内容を検証し、存在だけを信用しない）、`odb_has`、`odb_info`（型と長さ）。
- `git/refs.sigil`: `update_ref`（`<ref>.lock` の排他作成と旧値の比較）、`delete_ref`（`packed-refs.lock` も取り、packed 側を先に消してから緩い参照を消す）、`create_branch`/`create_tag`/`delete_*`/`list_*`、HEAD の読み書き、packed-refs の解析と再出力（ヘッダと `^` の peeled 行を保つ）。

### 制限と範囲

- 新しい上限: 参照 100000、packed-refs 64 MiB、作業メモリ 256 MiB（`git/limits.sigil`）。超過は専用のエラーで、黙って切り詰めません。
- 緩いオブジェクトの内容の取得（inflate）は範囲外です。実 Git が書く Huffman 圧縮のオブジェクトは、存在の確認はできますが、型と長さの照会、重複書き込みの判定、ブランチ作成時の commit 確認は `UnsupportedFormat` になります（inflate の後続 Issue まで）。
- 古い一時ファイル（`tmp_obj_*`、`*.lock`）は自動では消しません。ロックが残っていれば `Locked` を返します。
- pack の読み取り、index/add/commit、gc/repack、reflog、フックなどは範囲外です。

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
SIGIL=/path/to/sigil ./interop.sh
```
