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

**未着手**（2026-07-18 計画策定）。次: P2-T1

---

## タスク分解

- [ ] **P2-T1: Domain — スイング検知・ウィンドウ切り出し（F-W3）**
  - 新規: `Domain/Entities/Swing.swift`（1スイング = id, sessionId, 連番, インパクト時刻, サンプル列）
  - 新規: `Domain/Services/SwingDetector.swift`（純粋ロジック、フレームワーク非依存）
  - `RecordSessionUseCase` を SwingDetector 利用に改修（3g 点記録 → ウィンドウ切り出し）
  - 新規: `TennisAnalyser Watch AppTests/SwingDetectorTests.swift`（ユニットテスト）
  - DoD: テストがシミュレータで PASS、ビルド green
- [ ] **P2-T2: Watch — スイング単位 CSV 永続化（F-W4）**
  - 新規: `Domain/Repositories/SwingRepository.swift`（protocol）
  - 新規: `Infrastructure/SwingRepositoryImpl.swift`（1スイング=1CSV、メタ情報ヘッダー付き）
  - 旧 `SessionRepository`/`SessionRepositoryImpl`（セッション一括CSV）は削除
  - DoD: ビルド green、シミュレータでスイング検知→CSV保存をログ確認
- [ ] **P2-T3: Watch — WCSession 逐次転送（F-W5）**
  - 新規: `Domain/Repositories/SwingTransferRepository.swift`（protocol）
  - 新規: `Infrastructure/WCSessionTransferRepository.swift`
    - スイング保存のたび `WCSession.transferFile`（metadata: sessionId, seq, impactAt）
    - 転送完了コールバックでローカル CSV 削除（F-W5 + ストレージ保護）
    - 未転送分はワークアウト終了時に再送
  - DoD: ビルド green（実機E2EはT7でまとめて）
- [ ] **P2-T4: Watch — 簡易表示の整理（F-W6）**
  - 既存 UI（サンプル数・Hz・ロス率）に **スイング数** と **転送済み数** を追加
  - DoD: ビルド green、シミュレータで表示確認
- [ ] **P2-T5: iOS — 受信ハンドラ（F-I1）**
  - 新規: `TennisAnalyser/Infrastructure/PhoneSessionManager.swift`（WCSessionDelegate、file 受信 → Documents/swings/ へ格納）
  - 新規: `TennisAnalyser/Infrastructure/SwingStore.swift`（受信済みスイングの列挙・CSV パース）
  - DoD: ビルド green
- [ ] **P2-T6: iOS — スイング一覧 + 波形表示（F-I2）**
  - `ContentView.swift` を置き換え: スイング一覧（時刻・連番、新着自動反映）
  - 新規: `SwingDetailView.swift`（Swift Charts で加速度・角速度波形）
  - DoD: ビルド green、シミュレータ（テストCSV注入）で表示確認
- [ ] **P2-T7: 実機 E2E 検証**
  - Watch でスイング → 約10秒以内に iPhone 一覧に出る → 波形表示
  - Watch 側キャッシュが転送後に消えている
  - 結果を Logs/ に記録し、REQUIREMENTS/本ファイルを更新して Phase 2 クローズ
  - DoD: ユーザー実機確認 + ログ記録 + コミット

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
