# F-I7 録画継続性 実装計画（Phase 6）

**状態: 未着手**（2026-07-25 作成）
**仕様**: [docs/RECORDING_RELIABILITY_SPEC.md](../RECORDING_RELIABILITY_SPEC.md)
**契機**: 2026-07-21 実機検証で 325スイング中クリップ1件のみ生成される不具合を確認

---

## 方針

原因は「自動ロックで録画が止まり、再開経路が無い」ことだが、
**特定の中断要因だけを塞ぐのではなく、中断一般から復帰できる構造にする**。

理由は2つ。

1. 今回の中断要因は「自動ロックである」と断定できていない。ログが1行も残っておらず、
   ファイル配置からの逆算で「開始4〜29秒後に停止」までしか絞れていない。
2. カメラ撮影を継続できるバックグラウンドモードは iOS に無いため、
   着信等による中断はどのみち発生する。防ぐのではなく復帰させる必要がある。

あわせて **W0（観測性）を最初に片付ける**。実機検証は1時間の実練習が必要で再現コストが高く、
次の検証を無駄にしないため。

---

## Wave 構成

各 Wave は独立してビルド・コミット可能。中断時は Wave 境界で止めるのが望ましい。

| Wave | 内容 | 依存 |
|---|---|---|
| W0 | 観測性の確保（os.Logger + 診断記録の器） | なし |
| W1 | 録画継続（自動ロック抑止 + 中断復帰） | W0 |
| W2 | セグメント分割録画とデータモデル刷新 | W1 |
| W3 | 中間データ削除の安全化 | W2 |
| W4 | 診断記録のUI表示と共有 | W2 |
| W5 | 検出閾値の再評価（**独立・並行可**） | なし |

---

## タスク分解

### W0: 観測性の確保

- [x] **T1: `os.Logger` 基盤の導入** ✅ 2026-07-25
  - `AppLog` を iOS/Watch 各ターゲットに新設。サブシステム `com.spleeing.TennisAnalyser`
    - iOS カテゴリ: `recording` / `clip` / `transfer` / `store` / `session`
    - Watch カテゴリ: `motion` / `swing` / `transfer`
  - `print` を全35箇所置換（iOS 16・Watch 19）。残存 0 件
  - 個人情報を含まないため `privacy: .public` を明示（既定の `.private` だと
    実機ログで値がマスクされ、今回のような事後調査で使えない）
  - `VideoStore.extractClipIfNeeded` の**無言の早期 return 全てにログを追加**。
    今回の不具合を隠していた箇所であり、T1 の主目的
  - ビルド確認: iOS ✅ / Watch ✅（CLI `xcodebuild`）
  - ⚠️ 未実施: ユニットテスト（ディスク容量不足で Simulator が起動せず）、
    Xcode GUI ビルド（Xcode MCP 切断中）、Console.app での実機確認

  > Why not 共有ファイル1つ: 同期グループ構成のためターゲットごとにフォルダが対応する。
  > 共有には project.pbxproj の手編集が必要でリスクが見合わないため、各ターゲットに配置した。

- [ ] **T2: 診断記録の器を作る**
  - `SessionDiagnostics`（Domain）: セグメント・中断・クリップ生成の集計を保持
  - `Documents/diagnostics/{sessionId}.json` に逐次追記保存
  - この時点では記録するだけでよい（UI は W4）
  - テスト: 集計ロジックのユニットテスト（What を記述）

### W1: 録画継続

- [ ] **T3: 自動ロックの抑止**
  - `PracticeVideoRecorder` の録画開始で `UIApplication.shared.isIdleTimerDisabled = true`
  - 録画停止・セッション終了・`deinit` で必ず `false` へ戻す
  - Why not コメント: 常時 true にしない理由（バッテリー）を記載

- [ ] **T4: 中断検知と自動復帰**
  - `AVCaptureSessionWasInterrupted` / `AVCaptureSessionInterruptionEnded` を購読
  - `UIApplication.didBecomeActiveNotification` を購読
  - 「Watch セッションが継続中か」を示す論理状態 `isSessionActive` を導入し、
    `isRecording`（物理状態）と分離する
  - `isSessionActive == true` かつ `isRecording == false` になったら録画を再開
  - `willResignActive` での停止は維持（ファイル破損防止）。停止と再開を対にする
  - 中断の発生と復帰を T2 の診断記録へ記録
  - **この時点で実機の短時間確認を行う**（ホーム画面へ移動→復帰で録画が再開するか）

### W2: セグメント分割録画

- [ ] **T5: データモデルの刷新**
  - `PracticeVideo` を `RecordingSession` + `RecordingSegment` へ置換（仕様書 4章）
  - `Documents/video_sources/{sessionId}/manifest.json` + `{index}.mov`
  - 旧形式ファイルが残っていれば起動時に削除（移行処理は作らない。実データ無しのため）
  - テスト: `detectedAt` からセグメントとオフセットを解決するロジック

- [ ] **T6: `VideoStore` のセグメント対応**
  - `extractClipIfNeeded` を「`detectedAt` を含むセグメントを検索 → 該当セグメント内の
    オフセットで切り出し」に変更
  - セグメント境界に落ちたスイングは生成不可として診断記録へ記録
  - 既存の `videoComposition(withPropertiesOf:)` による向き保持は維持する
    （F-I6 で解決済みのため壊さないこと）

- [ ] **T7: 最大セグメント長**
  - `AVCaptureMovieFileOutput.maxRecordedDuration` を 10分に設定
  - 到達時の `didFinishRecordingTo` で即座に次セグメントを開始
  - 継ぎ目のギャップは既知の制約として診断記録に残す

### W3: 中間データ削除の安全化

- [ ] **T8: 削除条件の変更**
  - `scheduleSourceCleanup` の無条件削除を廃止
  - セグメント単位で「時間範囲内の全スイングがクリップ化済み」を判定して削除
  - 未処理が残る場合はセグメントを保持
  - 保持上限7日を超えたものは起動時に削除

- [ ] **T9: クリップ生成の再試行**
  - 未生成スイングをApp内で一覧し、手動で再試行できる導線

### W4: 診断のUI

- [ ] **T10: セッション診断画面**
  - カバー率・セグメント数・中断回数・クリップ成功/失敗を表示
  - 診断JSONを共有シートで書き出せるようにする
  - カバー率が閾値を下回った場合にセッション終了時警告

### W5: 検出閾値の再評価（独立）

- [ ] **T11: 保全データでの閾値分析**
  - 対象: 2026-07-21 セッションの 325件（吸い出し済み。下記「保全データ」参照）
  - 閾値を変えた場合の検出数の変化をシミュレートする解析スクリプトを作成
  - ラベル付けと突き合わせて誤検知率を推定
  - `SwingDetector.threshold` の既定値を変更（現行 3.0g）
  - **実装変更前に、分析結果をユーザーへ提示して合意を取ること**

---

## 保全データ

2026-07-21 の実機検証データは吸い出し済み。**端末側の中間データ（映像）は既に削除されており復元不可。**

保全先: `~/Documents/TennisAnalyser-FieldData/2026-07-21/`（2026-07-25 退避済み）

```
pull_swings/                   # 328 CSV（2セッション分。破損0件で検証済み）
container_listing.txt          # アプリコンテナの全ファイル一覧（421件）
clip1.mov                      # 唯一生成されたクリップ（4.00秒 / 1920x1080）
analyze.py                     # メタデータ解析スクリプト
README.md                      # データの由来と内容
```

> リポジトリ外に置いている（24MB のバイナリを含むため）。
> W5 の閾値分析はこのデータで実施できる。失うと1時間の実練習をやり直すことになる。

---

## 再開手順

1. 本ファイルのチェックボックスで進捗を確認する
2. `git log --oneline -10` で直近のコミットを確認する
3. `Logs/{最新日付}.log` のネクストアクションを読む
4. ビルド確認（iOS/Watch 両方。AGENTS.md ルール5）
5. 未完了の最初のタスクから着手する

Wave の途中で中断した場合は、そのWaveの完了済みタスクまででビルドが通る状態に
してからコミットすること（AGENTS.md 方針1）。

---

## 実機検証項目（W4 完了後）

仕様書「5. 受け入れ基準」に従う。検証前に以下を必ず実施すること。

1. 短時間の実機テストで中断→復帰を確認（1時間の実練習を無駄にしないため）
2. 診断記録がApp内で読めることを確認
3. **検証後、アプリを起動する前にコンテナを吸い出す**

```bash
xcrun devicectl device copy from --device <UUID> --domain-type appDataContainer \
  --domain-identifier com.spleeing.TennisAnalyser --user mobile \
  --source Documents --destination ./pull
```
