//
//  RecordingSessionTests.swift
//  TennisAnalyserTests
//
//  RecordingSession（F-I7-3: detectedAt からセグメントとオフセットを解決する）のユニットテスト

import Testing
import Foundation
@testable import TennisAnalyser

struct RecordingSessionTests {

    private let base = Date(timeIntervalSince1970: 1_780_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        base.addingTimeInterval(seconds)
    }

    private func segment(
        _ index: Int,
        from: TimeInterval,
        to: TimeInterval?,
        reason: SegmentEndReason? = .interrupted
    ) -> RecordingSegment {
        RecordingSegment(
            index: index,
            fileName: RecordingSegment.fileName(for: index),
            startedAt: at(from),
            endedAt: to.map { at($0) },
            endReason: to == nil ? nil : reason
        )
    }

    /// 0-100秒 と 300-400秒 を録画し、100-300秒が中断で欠落しているセッション
    private func sessionWithGap() -> RecordingSession {
        RecordingSession(
            id: "S1",
            startedAt: at(0),
            endedAt: at(400),
            segments: [segment(0, from: 0, to: 100), segment(1, from: 300, to: 400)]
        )
    }

    // MARK: - 解決

    @Test("セグメント内の時刻から、そのセグメントと内部オフセットが解決される")
    func resolvesWithinSegment() {
        let resolved = sessionWithGap().resolve(at(350))

        let result = try! #require(resolved)
        #expect(result.segment.index == 1)
        #expect(result.offsetSeconds == 50)
    }

    @Test("最初のセグメント内の時刻は index 0 として解決される")
    func resolvesFirstSegment() {
        let result = try! #require(sessionWithGap().resolve(at(30)))

        #expect(result.segment.index == 0)
        #expect(result.offsetSeconds == 30)
    }

    @Test("中断区間の時刻は解決されない")
    func doesNotResolveInGap() {
        #expect(sessionWithGap().resolve(at(200)) == nil)
    }

    @Test("録画範囲より前・後の時刻は解決されない")
    func doesNotResolveOutsideRange() {
        let session = sessionWithGap()

        #expect(session.resolve(at(-10)) == nil)
        #expect(session.resolve(at(500)) == nil)
    }

    @Test("終了時刻が未確定のセグメントは解決されない")
    func doesNotResolveUnfinishedSegment() {
        let session = RecordingSession(
            id: "S1", startedAt: at(0), endedAt: nil,
            segments: [segment(0, from: 0, to: nil)]
        )

        #expect(session.resolve(at(30)) == nil)
    }

    @Test("セグメント境界の時刻は解決される")
    func resolvesAtBoundary() {
        let session = sessionWithGap()

        #expect(session.resolve(at(0))?.offsetSeconds == 0)
        #expect(session.resolve(at(100))?.offsetSeconds == 100)
    }

    // MARK: - セグメント番号

    @Test("次のセグメント番号は既存の最大値+1になる")
    func nextIndexFollowsMaximum() {
        #expect(sessionWithGap().nextSegmentIndex == 2)
    }

    @Test("セグメントが無い場合、次のセグメント番号は0になる")
    func nextIndexStartsAtZero() {
        let session = RecordingSession(id: "S1", startedAt: at(0))

        #expect(session.nextSegmentIndex == 0)
    }

    @Test("途中のセグメントが削除されても番号は衝突しない")
    func nextIndexSurvivesDeletion() {
        // index 0 を削除しても、次は 2 であって 1 ではない
        let session = RecordingSession(
            id: "S1", startedAt: at(0),
            segments: [segment(1, from: 300, to: 400)]
        )

        #expect(session.nextSegmentIndex == 2)
    }

    // MARK: - 集計

    @Test("録画時間は終了済みセグメントのみ合算される")
    func recordedDurationSumsFinishedSegments() {
        let session = RecordingSession(
            id: "S1", startedAt: at(0), endedAt: at(400),
            segments: [
                segment(0, from: 0, to: 100),
                segment(1, from: 300, to: 400),
                segment(2, from: 420, to: nil),  // 未終了は算入しない
            ]
        )

        #expect(session.recordedDuration == 200)
    }

    @Test("カバー率は録画時間をセッション時間で割った値になる")
    func coverageRatioReflectsGap() {
        #expect(sessionWithGap().coverageRatio == 0.5)
    }

    @Test("セッション終了が未確定の場合、カバー率は nil になる")
    func coverageIsNilWhileRunning() {
        let session = RecordingSession(
            id: "S1", startedAt: at(0), endedAt: nil,
            segments: [segment(0, from: 0, to: 100)]
        )

        #expect(session.sessionDuration == nil)
        #expect(session.coverageRatio == nil)
    }

    // MARK: - ファイル名

    @Test("セグメントのファイル名は4桁ゼロ埋めになる")
    func fileNameIsZeroPadded() {
        #expect(RecordingSegment.fileName(for: 0) == "0000.mov")
        #expect(RecordingSegment.fileName(for: 7) == "0007.mov")
        #expect(RecordingSegment.fileName(for: 123) == "0123.mov")
    }

    // MARK: - 永続化

    @Test("JSON へ往復しても内容が保たれる")
    func roundTripsThroughJSON() throws {
        let original = sessionWithGap()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let restored = try decoder.decode(RecordingSession.self, from: try encoder.encode(original))

        #expect(restored == original)
    }
}
