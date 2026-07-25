//
//  SessionDiagnostics.swift
//  TennisAnalyser (iOS)
//
//  Domain — セッション診断記録（F-I7-5）
//
//  Why not 集計値を直接更新して保存: 2026-07-21 の実機検証では録画が開始数十秒で停止し、
//  以降57分間なにも起きなかった。このとき「何が起きなかったか」を復元する手掛かりが
//  一切残っていなかった。出来事を追記のみで記録し、集計は読み出し時に導出する形にすれば、
//  途中でアプリが落ちてもそこまでの経過が残る。集計値を上書き保存する方式では
//  最後の書き込みしか残らず、同じ状況で再び原因を追えなくなる。

import Foundation

/// セグメント（連続録画1本）が終了した理由
enum SegmentEndReason: String, Codable, Equatable, CaseIterable {
    /// Watch からセッション終了通知を受けた
    case sessionEnded
    /// 中断（バックグラウンド遷移・着信・自動ロック等）
    case interrupted
    /// 最大セグメント長に到達（F-I7-3）
    case maxDuration
    /// 録画エラー
    case error
}

/// クリップを生成できなかった理由
enum ClipSkipReason: String, Codable, Equatable, CaseIterable {
    /// スイングCSVに DetectedAt が無い
    case detectedAtMissing
    /// このセッションの継続録画が存在しない（録画していない・削除済み）
    case noSourceRecording
    /// メタデータはあるが動画ファイルがディスク上に無い
    case sourceFileMissing
    /// detectedAt が録画範囲外（録画が止まっていた時間帯のスイング）
    case outOfRecordedRange
    /// 切り出し処理自体の失敗
    case extractionFailed
}

/// セッション中に起きた出来事1件
///
/// 追記のみで記録し、順序はファイル上の並び（発生順）に従う。
enum DiagnosticEvent: Codable, Equatable {
    case sessionStarted(at: Date)
    case sessionEnded(at: Date)
    case segmentStarted(index: Int, at: Date)
    case segmentEnded(index: Int, at: Date, reason: SegmentEndReason)
    case interrupted(at: Date, reason: String)
    case interruptionEnded(at: Date)
    case clipExtracted(sequence: Int, at: Date)
    case clipSkipped(sequence: Int, at: Date, reason: ClipSkipReason)

    /// 出来事の発生時刻
    var timestamp: Date {
        switch self {
        case .sessionStarted(let at), .sessionEnded(let at),
             .interruptionEnded(let at):
            return at
        case .segmentStarted(_, let at), .clipExtracted(_, let at):
            return at
        case .segmentEnded(_, let at, _), .clipSkipped(_, let at, _):
            return at
        case .interrupted(let at, _):
            return at
        }
    }
}

/// 出来事の列から導出したセッションの診断結果
///
/// 保存はしない。`DiagnosticEvent` の列から `make(sessionId:from:)` で都度導出する。
struct SessionDiagnostics: Equatable {

    let sessionId: String

    let sessionStartedAt: Date?
    let sessionEndedAt: Date?

    /// セグメント（連続録画1本）の数
    let segmentCount: Int
    /// 終了時刻が確定したセグメントの実録画時間の合計
    let recordedDuration: TimeInterval
    /// セッション開始から終了までの時間（終了通知が無ければ nil）
    let sessionDuration: TimeInterval?

    let interruptionCount: Int

    let clipsExtracted: Int
    let clipsSkipped: Int
    let skipReasonCounts: [ClipSkipReason: Int]
    let segmentEndReasonCounts: [SegmentEndReason: Int]

    /// 録画が session 全体のどれだけを覆えたか（0.0〜1.0）。
    /// セッション時間が未確定・ゼロの場合は nil
    var coverageRatio: Double? {
        guard let sessionDuration, sessionDuration > 0 else { return nil }
        return recordedDuration / sessionDuration
    }

    /// 出来事の列から診断結果を導出する
    ///
    /// 終了時刻の無いセグメント（録画中・アプリ終了で記録が途切れた等）は
    /// `recordedDuration` に算入しない。実際に録画できたと確認できる時間だけを数えるため。
    static func make(sessionId: String, from events: [DiagnosticEvent]) -> SessionDiagnostics {
        var sessionStartedAt: Date?
        var sessionEndedAt: Date?
        var segmentStarts: [Int: Date] = [:]
        var startedSegmentIndices: Set<Int> = []
        var recordedDuration: TimeInterval = 0
        var interruptionCount = 0
        var clipsExtracted = 0
        var clipsSkipped = 0
        var skipReasonCounts: [ClipSkipReason: Int] = [:]
        var segmentEndReasonCounts: [SegmentEndReason: Int] = [:]

        for event in events {
            switch event {
            case .sessionStarted(let at):
                sessionStartedAt = at
            case .sessionEnded(let at):
                sessionEndedAt = at
            case .segmentStarted(let index, let at):
                segmentStarts[index] = at
                startedSegmentIndices.insert(index)
            case .segmentEnded(let index, let at, let reason):
                startedSegmentIndices.insert(index)
                segmentEndReasonCounts[reason, default: 0] += 1
                if let start = segmentStarts[index] {
                    recordedDuration += max(0, at.timeIntervalSince(start))
                    segmentStarts[index] = nil
                }
            case .interrupted:
                interruptionCount += 1
            case .interruptionEnded:
                break
            case .clipExtracted:
                clipsExtracted += 1
            case .clipSkipped(_, _, let reason):
                clipsSkipped += 1
                skipReasonCounts[reason, default: 0] += 1
            }
        }

        let sessionDuration = sessionStartedAt.flatMap { start in
            sessionEndedAt.map { $0.timeIntervalSince(start) }
        }

        return SessionDiagnostics(
            sessionId: sessionId,
            sessionStartedAt: sessionStartedAt,
            sessionEndedAt: sessionEndedAt,
            segmentCount: startedSegmentIndices.count,
            recordedDuration: recordedDuration,
            sessionDuration: sessionDuration,
            interruptionCount: interruptionCount,
            clipsExtracted: clipsExtracted,
            clipsSkipped: clipsSkipped,
            skipReasonCounts: skipReasonCounts,
            segmentEndReasonCounts: segmentEndReasonCounts
        )
    }
}
