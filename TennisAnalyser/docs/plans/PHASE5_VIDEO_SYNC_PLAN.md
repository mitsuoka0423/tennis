# F-I6 動画同期 実装計画（Phase 5 を前倒し）

**状態: 改訂中**（2026-07-18 v2）— 実機フィードバックを受けてアーキテクチャを刷新

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

- [ ] **T7: iOS — 録画の自動トリガー化**
  - `PhoneSessionManager` に `didReceiveApplicationContext` を実装し `PracticeVideoRecorder` を制御
  - `PracticeVideoRecorder.startRecording(sessionId:)` に変更（sessionId をそのまま動画IDに使う）
  - `RecordingCameraView`: 手動ボタンを削除、状態表示（自動録画中/待機中）のみに

- [ ] **T8: iOS — スイング単位クリップ自動生成**
  - `VideoStore`: 継続録画（video_sources）とクリップ（videos/{sessionId}/{sequence}.mov）を分離
  - `extractClipIfNeeded(sessionId:sequence:detectedAt:)`: `AVAssetExportSession` で前後2秒を切り出し
  - `PhoneSessionManager.didReceive file:` でスイング受信のたびにクリップ生成をキック
  - セッション終了通知から猶予後に継続録画を削除

- [ ] **T9: iOS — VideoSyncPlayerView 刷新（I-3/I-4）**
  - クリップ直再生（壁時計シーク不要、0秒始まり・クリップ全体をループ）
  - シークバー（Slider）追加
  - 再生位置を `relativeTimeSec` としてバインディングで公開
  - `SwingDetailView`: 波形グラフに再生位置の `RuleMark` を重ねる

- [ ] **T10: ドキュメント更新**

## 再開手順

1. 本ファイルのチェックボックスを確認 → `git log --oneline -10`
2. ビルド確認（iOS/Watch 両方）
3. 未完了の最初のタスクから着手

## 実機検証項目（T6〜T10 完了後）

- Watch で計測開始 → iPhone のカメラが自動で録画開始（ボタン操作なし）
- スイング → 該当スイングの詳細画面で数秒後にはクリップが生成され再生できる
- シークバーで細かく操作できる
- 再生位置に応じて波形グラフに縦線が動く
- Watch で計測停止 → iPhone の録画も自動停止、継続録画は猶予後に削除される
