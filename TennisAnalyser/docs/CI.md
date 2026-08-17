# Mac の前に座らずにビルド・テスト・配布する

**状態: ビルドとテスト・TestFlight 配布ともに導入済み（2026-08-17）**

## 1. 前提

| 条件 | 値 | 効いてくる点 |
|---|---|---|
| リポジトリの公開範囲 | **public** | GitHub Actions の **macOS runner が無料・無制限** |
| Apple Developer Program | **加入済み** | 実機配布（TestFlight）に必要。追加費用なし |

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

## 3. TestFlight への配布

`.github/workflows/testflight.yml` を **GitHub の画面から手動実行**すると、
アーカイブして App Store Connect へ上げる。
実行はスマートフォンのブラウザからでもできる（Actions → testflight → Run workflow）。

Watch App は iOS アプリに同梱されるため、**アップロードは1回で済む**。
Apple Watch へは iPhone の Watch アプリ経由で入る。

### 手動実行のみにした理由

1. TestFlight のビルドは**90日で失効する**。作り置きしても意味が薄い
2. アップロード後に App Store Connect の処理が数分〜30分かかる。
   「コートに向かう直前にビルド」は成立せず、**前日に回す運用**になる
3. ビルド番号を消費する。巻き戻せない

### 署名

`-allowProvisioningUpdates` と App Store Connect API キーの組み合わせで、
証明書とプロビジョニングプロファイルを **CI 側で発行・取得する**。

> Why not Mac の Keychain から .p12 を書き出して Secrets へ入れる:
> 手順が Mac に依存するうえ、証明書の更新のたびに同じ作業が要る。
> API キーなら発行もブラウザで完結し、更新も不要。
>
> ただし CI 側の自動発行が通らない場合は .p12 方式が確実な代替であり、
> そのときは Mac での書き出しが1回だけ必要になる。

### ビルド番号

プロジェクトの `CURRENT_PROJECT_VERSION` は 1 に固定されている。
TestFlight は同じビルド番号を受け付けず単調増加が必要なため、
**GitHub の実行番号をコマンドラインで上書きする**（ファイルは書き換えない）。

### 輸出コンプライアンス

`INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO` を全ターゲットへ設定した。

未設定だと**アップロードのたびに App Store Connect をブラウザで開いて
暗号化の質問に答える**必要がある。Mac を外したのにブラウザ作業が毎回残るのは
本末転倒なので、申告を先に済ませる。

本アプリは独自の暗号化を実装しておらず、通信も WatchConnectivity のみで
HTTPS 等の免除対象すら使っていないため `NO` が正しい。
**独自の暗号化を入れる場合はこの申告を見直すこと。**

### 必要な Secrets

App Store Connect の「ユーザとアクセス」→「統合」→「App Store Connect API」で
発行する（ブラウザのみで完結。Mac 不要）。権限は App Manager で足りる。

| Secret 名 | 内容 |
|---|---|
| `APP_STORE_CONNECT_KEY_P8` | 発行した `.p8` ファイルの中身をそのまま |
| `APP_STORE_CONNECT_KEY_ID` | キー ID |
| `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID |

`.p8` は**発行時に一度しかダウンロードできない**。紛失したら作り直す。

### 事前に一度だけ必要なこと

* App Store Connect に**アプリのレコードを作る**
  （バンドル ID `com.spleeing.TennisAnalyser`）。ブラウザで完結する
* TestFlight の内部テスターに自分を追加する。内部テスターへの配布は審査不要

---

## 4. Xcode Cloud を採らなかった理由

署名を Apple が管理するため設定は最も少なく、Developer Program に
月25時間ぶんが含まれている。初期設定に Mac が1回必要な点は許容範囲だった。

それでも GitHub Actions を採ったのは、**実行結果をエージェントが読めるため**である。
Xcode Cloud のログは GitHub の API から取れず、失敗のたびに人が画面を見て
内容を伝え直すことになる。ビルドの確認を人手から外すのが目的である以上、
そこが人手に戻る構成は目的と噛み合わない。

ビルドとテストが既に GitHub Actions で動いていたことも大きい。
配布だけ別系統にすると、見る場所が2つに増える。

---

## 5. 実機検証は別問題

CI が担保するのは**ビルドが通ることとユニットテストが通ること**だけである。

本プロジェクトの中核（200Hz のセンサー計測・カメラの連続録画・
Apple Watch と iPhone の通信）は**シミュレータでは確認できない**。
テニスの実練習による実機検証は引き続き必要であり、CI はその前段の
「壊れたまま実機へ持っていく」ことを防ぐ役割にとどまる。

TestFlight のワークフローがアーカイブ前にユニットテストを回すのは、
壊れたビルドをコートへ持って行くと**練習1回ぶん（1時間）が無駄になる**ためである。
