# Mac の前に座らずにビルド・テスト・配布する

**状態: ビルドとテストは導入済み（2026-08-17）。実機配布は未導入**

## 1. 前提

| 条件 | 値 | 効いてくる点 |
|---|---|---|
| リポジトリの公開範囲 | **public** | GitHub Actions の **macOS runner が無料・無制限** |
| Apple Developer Program | **未加入** | 実機配布（TestFlight）に必要。年 $99 |

private リポジトリでは macOS runner の消費が 10倍換算になり、
無料枠 2,000分は実質 200分/月しかない。**public であることが前提を大きく変えている。**

---

## 2. できるようになったこと: ビルドとユニットテスト

`.github/workflows/build.yml` が push のたびに iOS と watchOS を
シミュレータでビルドしてユニットテストを回す。

* **Mac 不要**。GitHub 上で完結する
* **署名不要**。シミュレータでは `CODE_SIGNING_ALLOWED=NO` で通るため、
  証明書を CI へ置く必要がない
* **無料**。public リポジトリの macOS runner は課金対象外

これで AGENTS.md ルール5（コードを変更したらビルドが通ることを確認する）を
Mac に座らずに満たせる。

### 設計上の判断

* **Xcode のバージョンを固定しない。** runner にある最新を選ぶ。
  固定すると runner イメージの更新で「存在しない Xcode」を指して落ちる
* **シミュレータの機種名を固定しない。** `.github/scripts/pick-simulator.sh` が
  実在するものから選ぶ。`iPhone 16` のような固定名は将来必ず落ちる
* **UITests は回さない。** 起動待ちが長く CI では不安定なため、
  `-only-testing:` でユニットテストだけを対象にする
* **watchOS はシミュレータを先に起動する。** `xcodebuild` の自動起動に任せると
  `Unknown application display identifier` で落ちることがある
  （2026-07-26 の知見。ビルド自体は成功しており、アプリの起動だけが失敗する）

### 回らないもの

`pnpm spec`（dspec の仕様検証）は CI に入れていない。pkl の導入が必要で
実行時間に対して得られるものが小さい。pre-commit フックが手元で担保している。

---

## 3. まだできないこと: 実機へのインストール

**Apple Developer Program（年 $99）への加入が必要。** 無料の Apple ID では、
プロビジョニングプロファイルが7日で失効し、インストール自体にも Mac が要るため成立しない。

加入した場合の選択肢は2つ。

### 3.1 GitHub Actions → TestFlight（推奨）

CI が archive して App Store Connect へアップロードし、
iPhone の TestFlight アプリから入れる。**Watch App は iPhone アプリに同梱される**ため、
iPhone の Watch アプリ経由で Apple Watch へ入る。

必要なもの:

| 用意するもの | 置き場所 |
|---|---|
| App Store Connect API キー（.p8） | リポジトリの Secrets |
| キー ID・Issuer ID | 同上 |

`xcodebuild` の `-allowProvisioningUpdates` と
`-authenticationKeyPath` / `-authenticationKeyID` / `-authenticationKeyIssuerID` を使えば、
**証明書とプロファイルを CI 側で自動発行できる**。
Mac の Keychain から証明書を書き出して Secrets へ入れる手順が要らない。

> Why not fastlane match: 証明書を別リポジトリで共有する仕組みであり、
> 開発者が1人なら管理対象が増えるだけになる。
> App Store Connect API による自動発行で足りる。

留意点:

* TestFlight のビルドは**90日で失効する**。継続して使うなら定期的に上げ直す
* アップロード後、App Store Connect の処理に数分かかる
* 内部テスター（自分だけ）への配布は審査不要

### 3.2 Xcode Cloud

Apple 純正の CI。署名を Apple が管理するため設定が最も少ない。
月25時間まで無料（Developer Program に含まれる）。

**ただしワークフローの初期設定は Xcode から行うのが基本であり、一度は Mac に座る必要がある。**
「Mac の前に座りたくない」が動機なら、3.1 のほうが目的に合う。

### 3.3 採らない選択肢

| 方法 | 採らない理由 |
|---|---|
| 無料 Apple ID + Xcode で直接インストール | 7日で失効し、インストールに Mac が要る |
| Ad-hoc 配布（itms-services://） | IPA と manifest を HTTPS でホストする必要があり、TestFlight より手間が多い |

---

## 4. 実機検証は別問題

CI が担保するのは**ビルドが通ることとユニットテストが通ること**だけである。

本プロジェクトの中核（200Hz のセンサー計測・カメラの連続録画・
Apple Watch と iPhone の通信）は**シミュレータでは確認できない**。
テニスの実練習による実機検証は引き続き必要であり、CI はその前段の
「壊れたまま実機へ持っていく」ことを防ぐ役割にとどまる。
