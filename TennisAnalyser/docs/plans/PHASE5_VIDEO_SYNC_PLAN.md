# F-I6 動画同期 実装計画（Phase 5 を前倒し）

**状態: 完了（2026-07-18）** — 実機検証（下記チェックリスト）はユーザー側で今後の練習時に実施

> **このドキュメントの目的**: セッション中断後も本ファイルと `git log`・`Logs/` を読めば再開できる状態を保つ。
> 運用ルールは `docs/plans/PHASE2_PLAN.md` と同じ（タスク完了ごとにビルド green でコミット）。

## Context（なぜ Phase 5 を前倒しするか）

Phase 3 Wave 1（アノテーション基盤）は完成したが、**実データを集め始めると
「どのスイング記録が実際のどのショットか分からない」**という問題が起きる。
CSV波形だけでは見分けがつかないため、アノテーション（F-I3）の精度が落ちる。

解決策として、要求2.2・F-I6（スロー動画と波形の同期表示、本来は Phase 5）を前倒しする。
動画があれば「このスイングはフォアハンドだった」と確実にラベル付けでき、
Wave 2（Core ML 学習）の学習データ品質が上がる。目的は Phase 3 Wave 1 の成果を実用化すること。

## スコープの絞り込み（意思決定）

- **撮影**: iPhone を三脚固定し、練習セッション中**連続で動画を録画**する
  （1スイングごとに撮り直すのではなく、Watch のセッションと同様に開始〜終了で1本）
- **同期方式**: 動画開始時刻（壁時計 `Date`）とスイングの `detectedAt`（壁時計）の差分で
  動画内の再生位置を計算する。Watch と iPhone は別デバイスのため数百ms程度のズレは起こりうるが、
  目視でショットを識別する用途では十分（フレーム単位の精度は不要）
- **「スロー」の実現方法**: 高フレームレート撮影（960/240fps 等）は機種依存が大きく、
  実機無しでの検証リスクが高いため見送る。**通常撮影 + AVPlayer の再生速度を落とす**
  （0.25x/0.5x トグル）方式を採用する。将来的に高fps撮影に変更しても同期ロジックは流用できる
- **音声**: 記録しない（フォーム分析に不要、プライバシー・容量の観点でも不要）
- **UI構成**: タブを追加し「スイング」（既存）と「録画」（新規、カメラプレビュー+開始/停止）を切り替える。
  詳細画面は要求通り「上部に動画・下部に波形」を1画面に統合する

## タスク分解

- [x] **T1: Domain — PracticeVideo エンティティ + VideoStore** ✅ 2026-07-18
  - `PracticeVideo`（Codable, startedAt/endedAt/fileName）+ `VideoStore`
    （Documents/videos/{uuid}.mov + {uuid}.json サイドカー）
  - ユニットテスト5件（contains/offsetSeconds の境界値含む）、全PASS

- [x] **T2: Infrastructure — カメラ録画（AVFoundation）** ✅ 2026-07-18
  - `PracticeVideoRecorder`: `AVCaptureSession`（背面カメラ・音声無し）+
    `AVCaptureMovieFileOutput`、権限要求（`CameraPermissionState`）
  - `didStartRecordingTo` で実録画開始時刻を記録（ボタン押下との起動ラグを除くため）
  - `willResignActiveNotification` で自動停止（バックグラウンド遷移時のファイル破損防止）
  - 実機カメラ動作は T3（UI結線）後に確認

- [x] **T3: Presentation — 録画タブ** ✅ 2026-07-18
  - `RecordingCameraView`: `CameraPreviewView`（AVCaptureVideoPreviewLayer の
    UIViewRepresentable）+ 録画ボタン + 経過時間バッジ + 権限拒否時の設定誘導
  - `TennisAnalyserApp`: `TabView`（スイング/録画）に変更。`PracticeVideoRecorder` は
    App 側で1つだけ生成し `videoStore` と同一インスタンスを共有（環境注入）
  - 設計修正: `RecordingCameraView.init()` 内で仮の `VideoStore` を生成する初期実装は、
    environmentObject の `videoStore` と別インスタンスになり保存した動画が一覧に
    反映されないバグだったため、App 側で一元生成する方式に直した

- [x] **T4: Presentation — 詳細画面への動画統合（F-I6 本体）** ✅ 2026-07-18
  - `VideoSyncPlayerView`: `AVPlayer` をインパクト前後±2秒でシーク・その区間をループ再生。
    再生/一時停止、速度切り替え（0.25x/0.5x/1.0x）
  - `SwingDetailView`: `matchedVideo(for:)` で `record.detectedAt` を含む動画を検索し、
    見つかれば動画をヘッダー直下・波形の上に表示（要求通り「上部に動画・下部に波形」）
  - 見つからない場合は「対応する動画がありません」の軽い表示（エラーにしない）
  - Why not 正確なウィンドウ幅: pre/post 秒数は Watch 側で調整可能だが、動画同期は目視確認用途の
    ため既定値（前後2秒）の近似で十分と判断（コード内コメント参照）

- [x] **T5: ドキュメント更新** ✅ 2026-07-18
  - REQUIREMENTS.md: F-I6 の TBD（同期方式）を解消、Phase 5 マイルストーンに完了マーク
  - Logs 追記

## 再開手順

1. 本ファイルのチェックボックスを確認 → `git log --oneline -10`
2. ビルド確認:
   `xcodebuild -project TennisAnalyser.xcodeproj -scheme "TennisAnalyser" -destination 'generic/platform=iOS' build`
3. 未完了の最初のタスクから着手

## 実機検証項目（T1〜T5 完了後）

- カメラ権限ダイアログが出て許可できる
- 録画開始→数分後に停止→ファイルが保存される
- 同じセッション中に記録されたスイングの詳細画面で、動画が該当タイミング付近にシークされて表示される
- スロー再生トグルが機能する
