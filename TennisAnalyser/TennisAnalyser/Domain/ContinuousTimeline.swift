//
//  ContinuousTimeline.swift
//  TennisAnalyser (iOS)
//
//  Domain — セッション全体を1本の連続した時間軸として扱う（F-I8-4 / W6-T16b）
//
//  Why not 画面ごとに時間軸を作る: 選別画面は候補の前後数秒、タイムライン画面は
//  セッション全体を対象とするが、違いは範囲だけである。別実装にすると
//  選別画面で確認した位置がタイムライン画面で違って見えることになる。

import Foundation

/// 動画が存在しない区間（中断・セグメント間の欠落）
///
/// ここに落ちたスイングは原理的にクリップ化できない（F-I7-3）。
/// 「動画が無い」のか「打っていない」のかを区別できないと見落とし探しが成立しないため、
/// 時間軸上に明示する必要がある。
struct TimelineGap: Equatable, Identifiable {
    var id: Date { startedAt }
    let startedAt: Date
    let endedAt: Date

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    func contains(_ date: Date) -> Bool {
        date >= startedAt && date < endedAt
    }
}

/// 連続タイムライン
///
/// 壁時計を単一の基準とし、セグメントとその内部オフセットへの変換を担う。
/// 再生位置・波形位置・アノテーションの `impactAt` はすべて壁時計で表す。
struct ContinuousTimeline: Equatable {

    let session: RecordingSession
    /// 表示・再生の対象範囲（壁時計）
    let range: DateInterval

    /// - Parameter range: nil ならセッション全体を対象とする
    init(session: RecordingSession, range: DateInterval? = nil) {
        self.session = session
        self.range = range ?? Self.fullRange(of: session)
    }

    /// 候補の前後を対象とする範囲を作る（選別画面用）
    init(session: RecordingSession, around date: Date, leading: TimeInterval, trailing: TimeInterval) {
        self.init(
            session: session,
            range: DateInterval(
                start: date.addingTimeInterval(-leading),
                end: date.addingTimeInterval(trailing)
            )
        )
    }

    // MARK: - 解決

    /// 壁時計時刻をセグメントと内部オフセットへ解決する
    func resolve(_ date: Date) -> (segment: RecordingSegment, offsetSeconds: Double)? {
        session.resolve(date)
    }

    /// この時刻の動画が存在するか
    func isCovered(_ date: Date) -> Bool {
        session.resolve(date) != nil
    }

    /// 対象範囲に含まれる動画欠落区間
    ///
    /// 終了時刻が未確定のセグメントは範囲が定まらないため覆っていないものとして扱う
    /// （`RecordingSegment.contains` と同じ判断）。
    var gaps: [TimelineGap] {
        let covered = session.segments
            .filter { $0.endedAt != nil }
            .map { DateInterval(start: $0.startedAt, end: $0.endedAt!) }
            .filter { $0.end > range.start && $0.start < range.end }
            .sorted { $0.start < $1.start }

        var gaps: [TimelineGap] = []
        var cursor = range.start
        for interval in covered {
            if interval.start > cursor {
                gaps.append(TimelineGap(startedAt: cursor, endedAt: min(interval.start, range.end)))
            }
            cursor = max(cursor, interval.end)
            if cursor >= range.end { break }
        }
        if cursor < range.end {
            gaps.append(TimelineGap(startedAt: cursor, endedAt: range.end))
        }
        return gaps
    }

    /// 欠落区間を飛ばした次の再生可能時刻
    ///
    /// セグメント境界をまたぐ再生で、欠落区間に入ったときの復帰先として用いる。
    func nextCoveredDate(atOrAfter date: Date) -> Date? {
        if isCovered(date), date < range.end { return date }
        let candidates = session.segments
            .filter { $0.endedAt != nil && $0.startedAt > date && $0.startedAt < range.end }
            .map(\.startedAt)
        return candidates.min()
    }

    // MARK: - 進捗との対応（シークバー・波形の横軸）

    var duration: TimeInterval { max(0, range.end.timeIntervalSince(range.start)) }

    /// 対象範囲内の進捗（0.0〜1.0）に対応する壁時計時刻
    func date(atProgress progress: Double) -> Date {
        range.start.addingTimeInterval(duration * min(max(progress, 0), 1))
    }

    /// 壁時計時刻に対応する対象範囲内の進捗（0.0〜1.0）
    func progress(of date: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(date.timeIntervalSince(range.start) / duration, 0), 1)
    }

    // MARK: - Private

    /// セッション全体の範囲
    ///
    /// 終了通知が未受信なら最後のセグメント終端までとする。終端も未確定なら
    /// 開始時刻のみの空範囲となり、再生対象が無いことを表す。
    private static func fullRange(of session: RecordingSession) -> DateInterval {
        let segmentEnd = session.segments.compactMap(\.endedAt).max()
        let end = [session.endedAt, segmentEnd].compactMap { $0 }.max() ?? session.startedAt
        return DateInterval(start: session.startedAt, end: max(end, session.startedAt))
    }
}
