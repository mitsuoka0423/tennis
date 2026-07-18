# F-I6 動画同期 実装計画（Phase 5 を前倒し）

**状態: 完了**（2026-07-18 v2）— 実機フィードバックを受けてアーキテクチャを刷新済み。
実機検証（下記チェックリスト）はユーザー側で今後の練習時に実施

## 改訂の経緯

初版（v1）は「セッション中連続録画 + 詳細画面で壁時計時刻マッチング」だった。
実機確認後、ユーザーから以下の要望が出た。

- I-1: 動画は音声なしに（→ 確認したところ既にマイク入力を追加しておらず対応済み）
- I-2: 録画ボタンの手動操作をなくしたい／動画とセンサー値をシンクしたい／
  **データはスイング単位で持ちたい**
- I-3: シークバーで細かく再生位置を指定したい
- I-4: 動画の再生位置と波形グラフの横軸を同期したい

I-2 の「スイング単位で持ちたい」が本質的な設計変更を要求している。
CSV が `F-W4: 1スイング=1ファイル` なのと対称的に、**動画も1スイング=1クリップ**にする。

## 新アーキテクチャ

### トリガー（I-2: 手動ボタン廃止）

- Watch: `RecordSessionUseCase.startSession()/stopSession()` のタイミングで
  `WCSession.updateApplicationContext` により iPhone へセッション開始/終了 + sessionId を通知
- iPhone: `PhoneSessionManager` が受信し `PracticeVideoRecorder` の録画を自動開始/停止
- iPhone 側の「録画」タブはカメラプレビュー+状態表示のみ（開始/停止ボタンは廃止）

### データモデル（I-2: スイング単位）

- **継続録画（内部の中間データ）**: `Documents/video_sources/{sessionId}.mov` + `.json`
  （Watch の sessionId をそのまま使う。壁時計時刻マッチングが不要になる）
- **スイング単位クリップ（最終データ、ユーザーに見せる）**: `Documents/videos/{sessionId}/{sequence}.mov`
  （CSV の `Documents/swings/{sessionId}/{sequence}.csv` と対称なレイアウト）
- スイングの CSV が iPhone に届くたびに、対応する継続録画から
  **`AVAssetExportSession` でインパクト前後2秒を切り出して**クリップを自動生成する
- 継続録画（中間データ）はセッション終了通知から一定時間（未転送分の到着を待つ猶予）後に削除

### 同期方式が大幅に単純化

クリップの長さ＝スイングウィンドウ（前後2秒）と一致するため、
**クリップ内の再生位置がそのままインパクトからの相対時間**になる
（`relativeTimeSec = playerTime - preRollSeconds`）。壁時計マッチングは
「どの継続録画から切り出すか」の1回だけで済む。

### I-3/I-4（シークバー・グラフ同期）

- `VideoSyncPlayerView` にシークバー（`Slider`）を追加。クリップ全体（短い）を対象に
  細かく再生位置を指定できる
- 再生位置を `relativeTimeSec`（インパクトからの相対秒）としてバインディング経由で
  `SwingDetailView` へ通知し、波形グラフに再生位置を示す `RuleMark`（縦線）を重ねる

## タスク分解（v2）

- [x] **T6: Watch — セッション開始/終了通知** ✅ 2026-07-18
  - `SwingTransferRepository` に `notifySessionStarted(sessionId:)`/`notifySessionEnded(sessionId:)` を追加
  - `WCSessionTransferRepository`: `updateApplicationContext` で通知
  - `WorkoutViewModel`: start/stop 時に呼び出す（stop時はセッション終了前にIDを退避）

- [x] **T7: iOS — 録画の自動トリガー化** ✅ 2026-07-18
  - `PhoneSessionManager` に `didReceiveApplicationContext` を実装し `PracticeVideoRecorder` を制御
  - `PracticeVideoRecorder.startRecording(sessionId:)` に変更（sessionId をそのまま動画IDに使う）
  - `RecordingCameraView`: 手動ボタンを削除、状態表示（自動録画中/待機中）のみに

- [x] **T8: iOS — スイング単位クリップ自動生成** ✅ 2026-07-18
  - `VideoStore`: 継続録画（video_sources/{sessionId}.mov+json）とクリップ
    （videos/{sessionId}/{sequence}.mov）を分離
  - `extractClipIfNeeded(sessionId:sequence:detectedAt:)`: `AVAssetExportSession.export(to:as:)`
    （新しい async API）で前後2秒を切り出し
  - `SwingStore.onIngested` フックを新設し、スイング受信のたびにクリップ生成をキック
    （App 側で配線。SwingStore/VideoStore の疎結合を維持）
  - `PhoneSessionManager`: セッション終了通知から60秒後に未処理スイングを処理してから
    継続録画を削除（F-W5 の転送目安10秒に対し十分な猶予）

- [x] **T9: iOS — VideoSyncPlayerView 刷新（I-3/I-4）** ✅ 2026-07-18
  - クリップ直再生（壁時計シーク不要、0秒始まり・クリップ全体をループ）
  - シークバー（Slider、editingChanged でスクラブ中は自動ループ用の再生を止める）
  - 再生位置を `relativeTimeSec`（インパクトからの相対秒）としてバインディングで公開
  - `SwingDetailView`: 波形グラフに再生位置のオレンジ `RuleMark` を重ねる

  Why not（設計変更の理由）: v1 は継続録画をスイング詳細表示のたびに壁時計時刻で検索していたが、
  Watch の sessionId が iPhone にも伝わるようになった（T6）ため、クリップを
  `{sessionId}/{sequence}.mov` の固定パスに保存する方式に変更。CSV と対称的なレイアウトにより
  検索ロジックが不要になり、クリップの再生開始位置（0秒）がそのままインパクト前2秒の
  ウィンドウ開始と一致するため、シーク計算も不要になった。

- [x] **T10: ドキュメント更新** ✅ 2026-07-18

## 再開手順

1. 本ファイルのチェックボックスを確認 → `git log --oneline -10`
2. ビルド確認（iOS/Watch 両方）
3. 未完了の最初のタスクから着手

## 実機検証項目（T6〜T10 完了後、未実施）

- Watch で計測開始 → iPhone のカメラが自動で録画開始（ボタン操作なし）
- スイング → 該当スイングの詳細画面で数秒後にはクリップが生成され再生できる
  （初回はクリップ生成が非同期のため、一覧の「再読み込み」または少し待ってから詳細を開く）
- シークバーで細かく操作できる
- 再生位置に応じて波形グラフに縦線が動く
- Watch で計測停止 → iPhone の録画も自動停止、継続録画は60秒後に削除される
- （持ち越し）音声: マイク入力を追加していないため録音されない設計だが、実機で無音確認
