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

## テストの実行

前提として、Sigil コンパイラ（固定版コミット `a2ccf0e086b4d7043ba89a740c840c550a4616fb`）が利用可能である必要があります。

```bash
# 全体テストの実行（fmt, check, SIR 評価器, ネイティブバイナリビルド＆実行）
./test.sh

# 個別実行
sigil run --root . test_runner.sigil main
```
