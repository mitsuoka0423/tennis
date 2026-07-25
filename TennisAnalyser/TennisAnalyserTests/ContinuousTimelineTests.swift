//
//  ContinuousTimelineTests.swift
//  TennisAnalyserTests
//
//  ContinuousTimeline / WaveformDownsampler（W6-T16b: 同期再生の共通基盤）のユニットテスト

import Foundation
import Testing
@testable import TennisAnalyser

struct ContinuousTimelineTests {

    // MARK: - Helpers

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeSegment(index: Int, start: Double, end: Double?) -> RecordingSegment {
        RecordingSegment(
            index: index,
            fileName: RecordingSegment.fileName(for: index),
            startedAt: base.addingTimeInterval(start),
            endedAt: end.map { base.addingTimeInterval($0) },
            endReason: end == nil ? nil : .sessionEnded
        )
    }

    /// 0〜100秒のセッション。20〜30秒が中断区間
    private func makeSession(endedAt: Double? = 100) -> RecordingSession {
        RecordingSession(
            id: "session-1",
            startedAt: base,
            endedAt: endedAt.map { base.addingTimeInterval($0) },
            segments: [
                makeSegment(index: 0, start: 0, end: 20),
                makeSegment(index: 1, start: 30, end: 100),
            ]
        )
    }

    // MARK: - 解決

    // 正常系: 壁時計時刻がセグメントと内部オフセットへ解決されること
    @Test func resolvesDateToSegmentOffset() {
        let timeline = ContinuousTimeline(session: makeSession())

        let resolved = timeline.resolve(base.addingTimeInterval(35))

        #expect(resolved?.segment.index == 1)
        #expect(resolved?.offsetSeconds == 5)
    }

    // 正常系: 中断区間は動画が存在しないと判定されること（F-I8-4）
    @Test func gapIsNotCovered() {
        let timeline = ContinuousTimeline(session: makeSession())

        #expect(timeline.isCovered(base.addingTimeInterval(10)))
        #expect(!timeline.isCovered(base.addingTimeInterval(25)))
    }

    // MARK: - 欠落区間

    // 正常系: セグメント間の欠落が時間軸上に現れること
    @Test func listsGapBetweenSegments() {
        let timeline = ContinuousTimeline(session: makeSession())

        let gaps = timeline.gaps

        #expect(gaps.count == 1)
        #expect(gaps[0].startedAt == base.addingTimeInterval(20))
        #expect(gaps[0].endedAt == base.addingTimeInterval(30))
        #expect(gaps[0].duration == 10)
    }

    // 正常系: 録画が始まる前・終わった後も欠落として現れること
    @Test func listsGapsAtBothEnds() {
        let session = RecordingSession(
            id: "session-1",
            startedAt: base,
            endedAt: base.addingTimeInterval(100),
            segments: [makeSegment(index: 0, start: 10, end: 20)]
        )
        let timeline = ContinuousTimeline(session: session)

        let gaps = timeline.gaps

        #expect(gaps.count == 2)
        #expect(gaps[0].startedAt == base)
        #expect(gaps[0].endedAt == base.addingTimeInterval(10))
        #expect(gaps[1].startedAt == base.addingTimeInterval(20))
        #expect(gaps[1].endedAt == base.addingTimeInterval(100))
    }

    // 正常系: 終了時刻が未確定のセグメントは覆っていないものとして扱われること
    //（範囲が定まらない以上、再生位置も定まらない）
    @Test func unfinishedSegmentCountsAsGap() {
        let session = RecordingSession(
            id: "session-1",
            startedAt: base,
            endedAt: base.addingTimeInterval(50),
            segments: [makeSegment(index: 0, start: 0, end: nil)]
        )
        let timeline = ContinuousTimeline(session: session)

        #expect(timeline.gaps.count == 1)
        #expect(timeline.gaps[0].duration == 50)
    }

    // 正常系: 対象範囲を絞ると、その範囲の欠落だけが現れること（選別画面の用途）
    @Test func gapsAreClampedToRange() {
        let timeline = ContinuousTimeline(
            session: makeSession(),
            around: base.addingTimeInterval(25), leading: 3, trailing: 3
        )

        let gaps = timeline.gaps

        #expect(gaps.count == 1)
        #expect(gaps[0].startedAt == base.addingTimeInterval(22))
        #expect(gaps[0].endedAt == base.addingTimeInterval(28))
    }

    // MARK: - 境界をまたぐ再生

    // 正常系: 欠落区間からは次に動画がある時刻へ送られること
    @Test func findsNextCoveredDateAcrossGap() {
        let timeline = ContinuousTimeline(session: makeSession())

        let next = timeline.nextCoveredDate(atOrAfter: base.addingTimeInterval(25))

        #expect(next == base.addingTimeInterval(30))
    }

    // 正常系: 動画がある位置ではその時刻がそのまま返ること
    @Test func nextCoveredDateReturnsSelfWhenCovered() {
        let timeline = ContinuousTimeline(session: makeSession())

        #expect(timeline.nextCoveredDate(atOrAfter: base.addingTimeInterval(5))
            == base.addingTimeInterval(5))
    }

    // 異常系: 以降に動画が無ければ nil を返すこと
    @Test func nextCoveredDateIsNilAfterLastSegment() {
        let session = RecordingSession(
            id: "session-1",
            startedAt: base,
            endedAt: base.addingTimeInterval(100),
            segments: [makeSegment(index: 0, start: 0, end: 20)]
        )
        let timeline = ContinuousTimeline(session: session)

        #expect(timeline.nextCoveredDate(atOrAfter: base.addingTimeInterval(50)) == nil)
    }

    // MARK: - 進捗との対応

    // 正常系: 進捗と壁時計が往復すること（シークバーと波形が同じ軸を使う担保）
    @Test func mapsProgressAndDateBothWays() {
        let timeline = ContinuousTimeline(session: makeSession())

        #expect(timeline.duration == 100)
        #expect(timeline.date(atProgress: 0.25) == base.addingTimeInterval(25))
        #expect(timeline.progress(of: base.addingTimeInterval(75)) == 0.75)
    }

    // 異常系: 範囲外の時刻は 0〜1 に丸められること
    @Test func clampsProgressOutOfRange() {
        let timeline = ContinuousTimeline(session: makeSession())

        #expect(timeline.progress(of: base.addingTimeInterval(-10)) == 0)
        #expect(timeline.progress(of: base.addingTimeInterval(200)) == 1)
    }

    // 正常系: 終了通知が無くても最後のセグメント終端までを範囲とすること
    @Test func fallsBackToLastSegmentEndWhenSessionUnfinished() {
        let timeline = ContinuousTimeline(session: makeSession(endedAt: nil))

        #expect(timeline.range.end == base.addingTimeInterval(100))
    }
}

struct WaveformDownsamplerTests {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeSamples(_ values: [(offset: Double, acceleration: Double)]) -> [TimedSample] {
        values.map {
            TimedSample(
                date: base.addingTimeInterval($0.offset),
                acceleration: $0.acceleration,
                gyro: $0.acceleration * 100
            )
        }
    }

    // 正常系: 間引きが区間内の最大値を採ること（平均だとピークが消える）
    @Test func binsKeepPeakNotAverage() {
        let samples = makeSamples([
            (0.0, 0.1), (0.1, 9.0), (0.2, 0.1), (0.3, 0.1),
            (0.5, 0.2), (0.7, 0.3),
        ])

        let bins = WaveformDownsampler.bins(
            from: samples,
            range: DateInterval(start: base, end: base.addingTimeInterval(1)),
            binCount: 2
        )

        #expect(bins.count == 2)
        #expect(bins[0].peakAcceleration == 9.0)
        #expect(bins[1].peakAcceleration == 0.3)
    }

    // 正常系: 角速度も同じ区間で最大値が採られること
    @Test func binsIncludeGyroPeak() {
        let bins = WaveformDownsampler.bins(
            from: makeSamples([(0.1, 4.0), (0.2, 8.0)]),
            range: DateInterval(start: base, end: base.addingTimeInterval(1)),
            binCount: 1
        )

        #expect(bins[0].peakGyro == 800)
    }

    // 正常系: サンプルが無い区間が判別できること（センサー欠落と動画欠落を区別する）
    @Test func marksEmptyBins() {
        let bins = WaveformDownsampler.bins(
            from: makeSamples([(0.1, 5.0)]),
            range: DateInterval(start: base, end: base.addingTimeInterval(1)),
            binCount: 4
        )

        #expect(bins.map(\.hasSamples) == [true, false, false, false])
    }

    // 正常系: 各区間の開始時刻が等間隔に並ぶこと（横軸の座標変換に使う）
    @Test func binStartDatesAreEvenlySpaced() {
        let bins = WaveformDownsampler.bins(
            from: makeSamples([]),
            range: DateInterval(start: base, end: base.addingTimeInterval(4)),
            binCount: 4
        )

        #expect(bins.map { $0.startedAt.timeIntervalSince(base) } == [0, 1, 2, 3])
    }

    // 異常系: 範囲外のサンプルは無視されること
    @Test func ignoresSamplesOutsideRange() {
        let bins = WaveformDownsampler.bins(
            from: makeSamples([(-1.0, 9.0), (0.5, 3.0), (5.0, 9.0)]),
            range: DateInterval(start: base, end: base.addingTimeInterval(1)),
            binCount: 1
        )

        #expect(bins[0].peakAcceleration == 3.0)
    }

    // 異常系: ビン数0・長さ0の範囲では空を返すこと
    @Test func returnsEmptyForDegenerateInput() {
        #expect(WaveformDownsampler.bins(
            from: makeSamples([(0.1, 5.0)]),
            range: DateInterval(start: base, end: base.addingTimeInterval(1)),
            binCount: 0
        ).isEmpty)
        #expect(WaveformDownsampler.bins(
            from: makeSamples([(0.1, 5.0)]),
            range: DateInterval(start: base, end: base),
            binCount: 4
        ).isEmpty)
    }
}
