//
//  DiagnosticsReport.swift
//  TennisAnalyser (iOS)
//
//  Domain — セッション診断記録を人が読めるテキストへ整形する（F-I7-5）
//
//  Why not View 内で整形する（2026-08-16 まではそうしていた）: 旧実装の共有テキストには
//  セグメント終了理由と中断理由が含まれておらず、「録画がなぜ止まったか」を共有内容だけからは
//  追えなかった。実機検証は1時間の実練習を要して再現コストが高く、共有した内容に
//  決め手が入っていない状態は次の練習まで取り返せない。何が含まれるかを
//  回帰テストで固定できる場所へ移す。

import Foundation

/// 診断記録を共有・貼り付け用のテキストへ整形する
enum DiagnosticsReport {

    /// セッション1件分の報告テキストを組み立てる
    ///
    /// Why not 文字列リテラルへ一気に埋め込む: 補間が10件を超えると型チェックが指数的に重くなり、
    /// 「unable to type-check this expression in reasonable time」で失敗する。
    /// 行ごとに組み立てて渡す。
    static func text(sessionId: String, events: [DiagnosticEvent]) -> String {
        let d = SessionDiagnostics.make(sessionId: sessionId, from: events)
        let timeline = self.timeline(from: events)

        let startedAt: String = d.sessionStartedAt.map { dateFormatter.string(from: $0) } ?? "—"
        let endedAt: String = d.sessionEndedAt.map { dateFormatter.string(from: $0) } ?? "—（終了通知なし）"
        let recorded: String = duration(d.recordedDuration)
        let total: String = d.sessionDuration.map { duration($0) } ?? "—"
        let coverage: String = d.coverageRatio.map { percent($0) } ?? "—"
        let endReasons: String = segmentEndBreakdown(d.segmentEndReasonCounts)
        let skipReasons: String = clipSkipBreakdown(d.skipReasonCounts)

        var lines: [String] = []
        lines.append("TennisAnalyser セッション診断")
        lines.append("SessionID: \(sessionId)")
        lines.append("開始: \(startedAt)")
        lines.append("終了: \(endedAt)")
        lines.append("録画時間: \(recorded) / セッション時間: \(total)")
        lines.append("カバー率: \(coverage)")
        lines.append("セグメント数: \(d.segmentCount)")
        lines.append("中断回数: \(d.interruptionCount) / 復帰回数: \(d.resumptionCount)")
        lines.append("セグメント終了理由: \(endReasons)")
        lines.append("クリップ: 成功 \(d.clipsExtracted) / 失敗 \(d.clipsSkipped)")
        lines.append("失敗理由: \(skipReasons)")

        let unresumed = d.interruptionCount - d.resumptionCount
        if unresumed > 0 {
            lines.append("※ 復帰しなかった中断が \(unresumed) 件あります")
        }

        lines.append("")
        lines.append("--- 出来事（\(timeline.count)件。クリップ生成は上の集計のみ）---")
        lines.append(contentsOf: timeline)

        return lines.joined(separator: "\n")
    }

    /// 録画の経過を1行1件で並べる
    ///
    /// Why not クリップ生成も並べる: 1セッションで300件を超えるため、
    /// 録画の開始・中断・復帰・終了が埋もれて経過を追えなくなる。
    /// 件数と理由の内訳は集計側に出ている。
    static func timeline(from events: [DiagnosticEvent]) -> [String] {
        events.compactMap { line(for: $0) }
    }

    /// 出来事1件の表示行。タイムラインに載せないものは nil を返す
    static func line(for event: DiagnosticEvent) -> String? {
        let time = timeFormatter.string(from: event.timestamp)
        switch event {
        case .sessionStarted:
            return "\(time) セッション開始"
        case .sessionEnded:
            return "\(time) セッション終了"
        case .segmentStarted(let index, _):
            return "\(time) セグメント\(index) 開始"
        case .segmentEnded(let index, _, let reason):
            return "\(time) セグメント\(index) 終了（\(label(for: reason))）"
        case .interrupted(_, let reason):
            return "\(time) 中断: \(reason)"
        case .interruptionEnded:
            return "\(time) 中断から復帰"
        case .clipExtracted, .clipSkipped:
            return nil
        }
    }

    // MARK: - 内訳
    //
    // 並び順は宣言順に固定する。辞書の列挙順は不定であり、
    // 共有のたびに順序が変わると前回との差分が読めなくなるため。

    static func segmentEndBreakdown(_ counts: [SegmentEndReason: Int]) -> String {
        let parts: [String] = SegmentEndReason.allCases.compactMap { reason in
            guard let count = counts[reason] else { return nil }
            return "\(label(for: reason))=\(count)"
        }
        return parts.isEmpty ? "—" : parts.joined(separator: ", ")
    }

    static func clipSkipBreakdown(_ counts: [ClipSkipReason: Int]) -> String {
        let parts: [String] = ClipSkipReason.allCases.compactMap { reason in
            guard let count = counts[reason] else { return nil }
            return "\(label(for: reason))=\(count)"
        }
        return parts.isEmpty ? "—" : parts.joined(separator: ", ")
    }

    // MARK: - 表示用ラベル

    static func label(for reason: SegmentEndReason) -> String {
        switch reason {
        case .sessionEnded: return "セッション終了"
        case .interrupted: return "中断"
        case .maxDuration: return "最大長に到達"
        case .error: return "エラー"
        }
    }

    static func label(for reason: ClipSkipReason) -> String {
        switch reason {
        case .detectedAtMissing: return "検知時刻が不明"
        case .noSourceRecording: return "録画が存在しない"
        case .sourceFileMissing: return "動画ファイルが見つからない"
        case .outOfRecordedRange: return "録画されていない時間帯"
        case .extractionFailed: return "切り出しに失敗"
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d分%02d秒", total / 60, total % 60)
    }

    static func percent(_ ratio: Double) -> String {
        ratio.formatted(.percent.precision(.fractionLength(1)))
    }

    // MARK: - Private

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// タイムラインはミリ秒まで出す。中断から復帰までの間隔が数百ミリ秒のことがあり、
    /// 秒単位だと同時刻に見えて前後関係が読めなくなる
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
