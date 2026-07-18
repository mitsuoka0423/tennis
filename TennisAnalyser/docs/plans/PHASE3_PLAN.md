# Phase 3 実装計画: Core ML Integration（分類）

> **このドキュメントの目的**: セッション中断（コンテキスト上限・利用上限・作業中断）後も、
> 本ファイルと `git log`・`Logs/` の最新ログを読めば誰でも（AIでも）作業を再開できる状態を保つ。
> 運用ルールは `docs/plans/PHASE2_PLAN.md` と同じ（タスク完了ごとにビルド green でコミット）。

## ゴール（docs/REQUIREMENTS.md §7 Phase 3）

> アノテーション機能（F-I3）で学習データを作成し、Create ML によるショット分類モデル（F-W7）を搭載。
> 解析エンジン（F-I4）の基礎実装。学習データ収集・アノテーション方針・精度目標を本フェーズ開始時に定義。

## 現在地

**P3-T1〜T4 完了**（2026-07-19）。次: P3-T5
- T2（アノテーションUI）と T3（フィルタ）は `ContentView.swift` を同時に触るため1コミットにまとめた
- T4（解析エンジン）は `SwingDetailView` のヘッダー実装（T2）と合わせて実装したため先に完了

## 前提となる意思決定（TBD の解消）

REQUIREMENTS.md の F-W7 は「学習データ収集・アノテーション方針・精度目標は Phase 3 開始時に定義」と
TBD になっていた。以下の通り定義する。

### ショット分類（6分類、要求 2.3 に合わせて拡張）

Watch 側 `MotionSample.ShotClass` は現状 `FOREHAND/BACKHAND/SERVE/OTHER` の4分類だが、
要求 2.3（試合モードの分析: ストローク/ボレーをフォア・バックで区別）と F-W7 の記述
（ストローク フォア/バック、ボレー フォア/バック、サーブ、その他）に合わせ **6分類**に拡張する。

| rawValue | 表示名 |
|---|---|
| `STROKE_FOREHAND` | ストローク(フォア) |
| `STROKE_BACKHAND` | ストローク(バック) |
| `VOLLEY_FOREHAND` | ボレー(フォア) |
| `VOLLEY_BACKHAND` | ボレー(バック) |
| `SERVE` | サーブ |
| `OTHER` | その他 |

既存コードでの `.forehand`/`.backhand` 等の利用箇所なし（grep 確認済み）のため破壊的変更が安全に可能。

### アノテーション方針

- **誰が**: 自分（開発者本人）が iPhone 上で手動タグ付け（F-I3）
- **いつ**: 練習後（またはその場）に一覧からスイングを選び、ショット種別を選択
- **粒度**: 1スイング = 1ラベル（ウィンドウ全体に同一ラベル。Create ML Activity Classifier の
  一般的な入力形式に合わせる）
- **効率化**: ラリー中は同じショットが連続することが多いため、**複数選択して一括タグ付け**できるようにする
- **永続化**: CSV のメタ情報ヘッダーに `# ShotClass: <rawValue>` を追加し、全データ行の
  `ShotClass` 列にも同じ値を書き込む（メタ情報は一覧表示の軽量パース用、データ行は
  Create ML 学習時にそのまま使える形にするための冗長化）

### 学習データ量の目安（精度目標の前段）

実データはまだほぼ収集されていない（Phase 1/2 の実機検証はテスト用の素振りが数十本のみ）。
量が集まるまでモデル学習・統合（F-W7 本体）は行わず、以下をチェックポイントとする。

- 各クラス **50本**: 最初の学習実験が可能な最低ライン
- 各クラス **150本以上**: 実用に足る精度を狙える目安（Create ML Activity Classifier の一般的な経験則）
- 精度目標の数値（例: 90%以上）は、上記データが集まり実際に学習・評価してから確定する
  （データが無い段階で数値目標を決めても検証できないため）

### Phase 3 のスコープ分割

実データが無い現時点で「モデルを学習して Watch に統合する」(F-W7 本体) は着手できない。
そのため Phase 3 を2段階に分ける。

- **Wave 1（今回実施）**: アノテーション基盤 + 解析エンジンの基礎 + 学習データのエクスポート経路
  - データを集め始められる状態にすることがゴール
- **Wave 2（データが集まってから着手）**: 実際の Create ML 学習・オンデバイス統合（F-W7 本体）
  - 上記データ量の目安に達したら再開する。学習パイプラインの詳細（Create ML の
    Activity Classifier に必要な正確なスキーマ調査を含む）は Wave 2 開始時に設計する

---

## タスク分解（Wave 1）

- [x] **P3-T1: ShotClass の6分類化 + CSV 往復** ✅ 2026-07-19
  - Watch/iOS 双方に6分類 ShotClass（rawValue 一致）
  - `writeShotClass`: メタ行（`# ShotClass:`）とデータ行末尾を書き換え、順序（メタ→ヘッダー→データ）を保持
  - ユニットテスト: Watch 2件 + iOS 3件、全PASS

- [x] **P3-T2: iOS — アノテーション UI（F-I3）** ✅ 2026-07-19
  - `SwingDetailView`: `record` を `SwingStore` 経由の算出プロパティに変更（`recordId` 保持）し、
    タグ付け直後に表示へ即反映されるようにした。ショット種別メニュー（Capsule ボタン）を追加
  - `ContentView`: `List(selection:)` + `EditMode` で複数選択モードを実装、
    選択中はツールバーに「一括タグ付け」メニュー
  - `SwingRow` にラベルチップを追加（未設定時は非表示）

- [x] **P3-T3: iOS — 一覧のフィルタリング（F-I2 将来項目の実装）** ✅ 2026-07-19
  - ツールバー左に絞り込みメニュー（すべて/未タグ/クラス別インライン Picker）
  - 該当0件時は `ContentUnavailableView` で明示

- [x] **P3-T4: iOS — 解析エンジンの基礎（F-I4）** ✅ 2026-07-19
  - `Domain/SwingAnalysis.swift`: `SwingAnalyzer.analyze` 純粋関数
    （ピーク時刻・ピーク値・減速開始点=ピークの50%まで低下した最初の時刻）
  - `SwingDetailView` に「簡易指標 (β)」として表示。本格スコアリングは未実装であることを明示
  - ユニットテスト5件、全PASS

- [ ] **P3-T5: iOS — 学習データのエクスポート**
  - ラベル付きスイングを `ShotClass` ごとのフォルダに整理してエクスポート（共有シート経由で
    Files app 等に書き出し）。Create ML への具体的な取り込み方法は Wave 2 で設計
  - DoD: ビルド green、実機で軽く動作確認

- [ ] **P3-T6: ドキュメント更新**
  - REQUIREMENTS.md の F-W7 TBD 部分を本計画の内容で更新
  - Logs に記録、本ファイルの完了マーク

## Wave 2（着手条件: 各クラス50本以上のラベル付きデータ）

- [ ] Create ML Activity Classifier のスキーマ調査・学習スクリプト作成
- [ ] 学習・評価、精度目標の確定
- [ ] `.mlmodel` を Watch ターゲットへ組み込み、オンデバイス推論（F-W7 本体）
- [ ] 精度の実機検証

---

## 再開手順（新セッション向け）

1. 本ファイルの「現在地」とチェックボックスを確認
2. `git log --oneline -10` で最後のチェックポイントを確認
3. `Logs/` の最新ログで直近の意思決定を確認
4. ビルド確認:
   - iOS: `cd TennisAnalyser && xcodebuild -project TennisAnalyser.xcodeproj -scheme "TennisAnalyser" -destination 'generic/platform=iOS' build`
   - Watch: `xcodebuild -project TennisAnalyser.xcodeproj -scheme "TennisAnalyser Watch App" -destination 'generic/platform=watchOS' build`
5. 未完了の最初のタスクから着手
