# 仕様モデル（dspec トライアル）

**状態: トライアル導入（2026-07-26）**

[dspec](https://github.com/mizchi/dspec) を使い、仕様のうち**機械が判定できる部分**を
型付きモデル（Pkl）として持つ試み。散文の仕様書は
[RECORDING_RELIABILITY_SPEC.md](../RECORDING_RELIABILITY_SPEC.md)（F-I7）と
[ANNOTATION_SPEC.md](../ANNOTATION_SPEC.md)（F-I8）が引き続き正典であり、
本モデルはそこから id・実装参照・用語だけを取り出した層。

## 導入の目的

仕様書が実装ファイル名の変更に追随できず、参照切れを検知できないこと。
`drift` はモデルが指す実装ファイルとシンボルの実在を検査するため、
ファイルを移動・改名すると失敗する。

## 前提

| ツール | 用途 | 導入 |
|---|---|---|
| Pkl 0.32 以上 | モデルの評価 | `brew install pkl` |
| Node.js 24 以上 | dspec CLI | 導入済み |
| pnpm | dspec の取得 | 導入済み |

dspec は npm に公開されていないため、GitHub から devDependency として取得する。

```bash
pnpm install
```

## 使い方

**リポジトリルートから実行すること。** 実装参照の path はモデルファイルではなく
カレントディレクトリを基準に解決される。

```bash
pnpm spec
```

| コマンド | 内容 |
|---|---|
| `pnpm spec:check` | モデルの構造検証（id の重複、用語の未定義参照、ロケール欠落） |
| `pnpm spec:drift` | 実装参照の解決。ファイルとシンボルが実在するか |
| `pnpm spec:coverage` | `approved` の規則が自動チェックを持つか |
| `pnpm spec:render` | 日本語の自然言語レンダリング |

## pre-commit フック

`.githooks/pre-commit` が `dspec coverage` を実行し、実装参照が切れた状態での
コミットを止める。`coverage` は内部で `drift` を、`drift` は `check` を呼ぶため、
1コマンドで3つ分の検査になる（約0.2秒）。

`core.hooksPath` はリポジトリのローカル設定で clone に含まれないため、
**新しい環境では一度だけ有効化する**。

```bash
pnpm hooks:install
```

| 状況 | 挙動 |
|---|---|
| 参照が全て解決する | 通過 |
| 参照が切れている | コミットを中止し、切れた規則と参照先を表示 |
| node / pkl / node_modules が無い | **通過**。理由と復旧方法を表示するだけ |
| 迂回したい | `git commit --no-verify` |

ツールチェーンが無い環境でコミットを止めないのは、トライアル中の道具のために
別端末での作業を妨げないため。

GUI クライアント（Xcode の Source Control 等）から commit するとログインシェルの
PATH が引き継がれないため、フック内で mise shims・Homebrew・pnpm の場所を PATH へ足している。

## トライアルで判明した制約

### 1. Swift のシンボル検査は `class` にしか効かない

dspec のシンボル判定は `function|class|typealias|const|let|var` の正規表現。
Swift の `struct` / `enum` / `func` / `actor` / `protocol` は一致しない。

そのため実装参照は次の方針とした。

- `class` 宣言（`PracticeVideoRecorder`・`VideoStore`・`DiagnosticsStore`）は
  シンボル付きで参照し、改名を検知させる
- `struct` / `enum` 中心のファイル（`RecordingSession`・`SessionDiagnostics`・
  `SessionAnnotation`）は**パスのみ**で参照し、移動・削除だけを検知させる

### 2. Swift のテストを自動チェックとして登録できない

`checks` のバックエンドは node / playwright / lean / tla / alloy / rego / cue / pkl /
runtime / manual のみで、XCTest・swift-testing に対応するものが無い。
`manual` は `drift` で常にエラーになる（machine-verifiable でないため）。

よって Swift のテストは `implementedBy` の `kind = "test"` として参照し、
**存在検査だけ**を受けている。`coverage` は `approved` の規則のみを見るため、
現在は 0/0 で通る。実機検証が完了して規則を `approved` へ上げた時点で
「自動チェックが無い」と報告されるようになる。それが正しい姿であり、
その時に xcodebuild の結果を食わせる方法を考える。

### 3. pnpm 経由では `dspec` コマンドが無言で終了する

`src/cli.mjs` の実行判定が `resolve(process.argv[1]) === fileURLToPath(import.meta.url)`
であり、pnpm のシンボリックリンク構成では両者が一致せず、
**何も出力せず終了コード 0 を返す**（成功と見分けがつかない）。

`package.json` の `dspec` スクリプトで `node --preserve-symlinks-main` 経由で
起動して回避している。`node_modules/.bin/dspec` を直接呼ばないこと。

## 規則の状態

実機検証が未了のため、全ての規則は `review` または `draft` に置いている。
受け入れ基準を実測できた規則から `approved` へ上げる。

| 状態 | 意味 |
|---|---|
| `draft` | 受け入れ基準そのもの。実測が未実施 |
| `review` | 実装済み・実機未検証 |
| `approved` | 実機で確認済み（現在なし） |
