# Phase 2 実装計画: 練習モード (Practice Mode)

> **このドキュメントの目的**: セッション中断（コンテキスト上限・利用上限・作業中断）後も、
> 本ファイルと `git log`・`Logs/` の最新ログを読めば誰でも（AIでも）作業を再開できる状態を保つ。
>
> **運用ルール**:
> - タスク完了ごとにチェックボックスを更新し、**ビルド green の状態でコミット**する（コミット = チェックポイント）
> - 設計判断・仕様変更はこのファイルの「設計判断」節に追記してからコードを書く
> - 中断時は「現在地」節を必ず更新してからセッションを終える

## ゴール（docs/REQUIREMENTS.md §7 Phase 2）

練習中、スイングを打った**約10秒後に iPhone でスイング波形を確認できる**。

- F-W3: スイングウィンドウ切り出し / F-W4: スイング単位CSV / F-W5: 逐次転送
- F-W6: Watch 簡易表示 / F-I1: iOS 受信 / F-I2: スイング一覧・波形表示

---

## 現在地

**Phase 2 完了**（2026-07-18、実機 E2E 検証済み）🎉

### 既知の課題（Phase 2 スコープ外へ持ち越し）

- **I-1 残課題**: 座標軸ガイドの 3D モデルの初期表示サイズが大きい。
  透明ボックス（黒描画される）→ 極小マーカーで境界拡大、の2案とも効果なし。
  次の一手は明示的な `PerspectiveCamera` の追加（orbit の自動フレーミングに頼らない）。
  メイン機能ではないためユーザー判断でスキップ
- 画面消灯中の計測継続テスト（消灯方法から要調査）
- Watch 側ビルド warning 6件（samplingTask Sendable ×4、不要 await ×2）
- バッテリー消費の実測（1時間で20%以下、NFR）

---

## タスク分解

- [x] **P2-T1: Domain — スイング検知・ウィンドウ切り出し（F-W3）** ✅ 2026-07-18
  - 新規: `Domain/Entities/Swing.swift`（1スイング = id, sessionId, 連番, インパクト時刻, サンプル列）
  - 新規: `Domain/Services/SwingDetector.swift`（純粋ロジック、フレームワーク非依存）
  - 新規: `TennisAnalyser Watch AppTests/SwingDetectorTests.swift`（8テスト、全PASS）
  - DoD: テストがシミュレータで PASS、ビルド green → 達成
- [x] **P2-T2: Watch — スイング単位 CSV 永続化（F-W4）+ UseCase 改修** ✅ 2026-07-18
  - 新規: `Domain/Repositories/SwingRepository.swift`（protocol）
  - 新規: `Infrastructure/SwingRepositoryImpl.swift`（1スイング=1CSV、メタ情報ヘッダー付き）
  - `RecordSessionUseCase` を SwingDetector 利用に改修（3g 点記録 → ウィンドウ切り出し→スイング保存）
  - 旧 `SessionRepository`/`SessionRepositoryImpl`（セッション一括CSV）は削除
  - DoD: ビルド green、シミュレータでスイング検知→CSV保存をログ確認
- [x] **P2-T3: Watch — WCSession 逐次転送（F-W5）** ✅ 2026-07-18
  - 新規: `Domain/Repositories/SwingTransferRepository.swift`（protocol）
  - 新規: `Infrastructure/WCSessionTransferRepository.swift`
    - スイング保存のたび `WCSession.transferFile`（metadata: sessionId, seq, impactAt）
    - 転送完了コールバックでローカル CSV 削除（F-W5 + ストレージ保護）
    - 未転送分はワークアウト終了時に再送
  - DoD: ビルド green（実機E2EはT7でまとめて）
- [x] **P2-T4: Watch — 簡易表示の整理（F-W6）** ✅ 2026-07-18
  - 既存 UI にスイング数・転送状況（転送済み/残）を追加
- [x] **P2-T5: iOS — 受信ハンドラ（F-I1）** ✅ 2026-07-18
  - 新規: `TennisAnalyser/Infrastructure/PhoneSessionManager.swift`（WCSessionDelegate、file 受信 → Documents/swings/ へ格納）
  - 新規: `TennisAnalyser/Infrastructure/SwingStore.swift`（受信済みスイングの列挙・CSV パース）
  - DoD: ビルド green
- [x] **P2-T6: iOS — スイング一覧 + 波形表示（F-I2）** ✅ 2026-07-18
  - `ContentView.swift`: セッション別グループのスイング一覧（連番・時刻・ピークG、スワイプ削除）
  - `SwingDetailView.swift`: Swift Charts で加速度・角速度の3軸波形
    （X=#4269D0/Y=#B45309/Z=#3CA951、dataviz バリデータ両モードPASS、インパクト基準線付き）
- [x] **P2-T7: 実機 E2E 検証** ✅ 2026-07-18
  - スイング → iPhone 一覧反映 → 波形表示 → 転送後キャッシュ削除、すべて確認
  - フィードバック4ラウンド対応（W-1〜W-4 / I-1〜I-5、詳細は Logs/2026-07-18.log）
  - `devicectl` による CLI からの実機インストール・起動手順を確立
    （`devicectl device install app` → `devicectl device process launch`。
    要: iPhone USB 接続 + Watch ロック解除・点灯）

---

## 設計判断

- **SwingDetector のアルゴリズム**（F-W3）:
  - リングバッファに直近 `preSeconds`（デフォルト2秒）のサンプルをタイムスタンプ基準で保持
  - 加速度ベクトル ≥ `threshold`（デフォルト3.0g）でインパクト検知
  - 検知後 `postSeconds`（デフォルト2秒）分のサンプルを収集してウィンドウ確定・emit
  - **ウィンドウ収集中の再インパクトは無視**（ウィンドウは1つのまま継続。ラリーの打球間隔は
    通常2〜3秒以上のため実用上問題なし。分割・結合の高度化は必要になってから）
  - パラメータ（preSeconds/postSeconds/threshold）はすべて init 注入で調整可能（要求 2.2）
- **API 形状**: `feed(_ batch: [MotionSample]) -> [Swing]`（同期・純粋。actor 隔離なし。
  Phase 1 の教訓: @MainActor とセンサーストリームの混在はデッドロックの温床）
- **セッション一括 CSV は廃止**: スイング単位 CSV（F-W4）に一本化。`SwingSession` エンティティは
  セッションID・開始時刻の供給元として残す（samples 蓄積はやめる → メモリも節約）
- **転送メタデータ**: `transferFile(_:metadata:)` に sessionId / seq / impactTimestampMs を持たせ、
  iOS 側はメタデータ + CSV ヘッダーの両方から復元可能にする（冗長性）
- **iOS 保存先**: `Documents/swings/{sessionId}/{seq}.csv`。全量永続保存（NFR）

## 再開手順（新セッション向け）

1. 本ファイルの「現在地」とチェックボックスを確認
2. `git log --oneline -10` で最後のチェックポイントを確認
3. `Logs/` の最新ログで直近の意思決定を確認
4. ビルド確認: `cd TennisAnalyser && xcodebuild -project TennisAnalyser.xcodeproj -scheme "TennisAnalyser Watch App" -destination 'generic/platform=watchOS' build`
5. 未完了の最初のタスクから着手（タスクは独立性が高い順に並んでいる）

## 検証コマンド

- Watch ビルド: 上記 4
- ユニットテスト: `xcodebuild test -project TennisAnalyser.xcodeproj -scheme "TennisAnalyser Watch App" -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)'`
- 実機: Xcode で実行先 `MTS Watch Main` を選び ⌘R
