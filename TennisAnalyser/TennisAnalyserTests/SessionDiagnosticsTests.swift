//
//  SessionDiagnosticsTests.swift
//  TennisAnalyserTests
//
//  SessionDiagnostics（F-I7-5: 出来事の列からセッション診断を導出する）のユニットテスト

import Testing
import Foundation
@testable import TennisAnalyser

struct SessionDiagnosticsTests {

    private let base = Date(timeIntervalSince1970: 1_780_000_000)
    private let sessionId = "TEST-SESSION"

    private func at(_ seconds: TimeInterval) -> Date {
        base.addingTimeInterval(seconds)
    }

    private func make(_ events: [DiagnosticEvent]) -> SessionDiagnostics {
        SessionDiagnostics.make(sessionId: sessionId, from: events)
    }

    // MARK: - 録画時間とカバー率

    @Test("セグメント1本がセッション全体を覆う場合、カバー率が 1.0 になる")
    func fullCoverage() {
        let d = make([
            .sessionStarted(at: at(0)),
            .segmentStarted(index: 0, at: at(0)),
            .segmentEnded(index: 0, at: at(600), reason: .sessionEnded),
            .sessionEnded(at: at(600)),
        ])

        #expect(d.segmentCount == 1)
        #expect(d.recordedDuration == 600)
        #expect(d.sessionDuration == 600)
        #expect(d.coverageRatio == 1.0)
    }

    @Test("複数セグメントの録画時間が合算され、間の空白がカバー率に反映される")
    func multipleSegmentsAreSummed() {
        let d = make([
            .sessionStarted(at: at(0)),
            .segmentStarted(index: 0, at: at(0)),
            .segmentEnded(index: 0, at: at(100), reason: .interrupted),
            .segmentStarted(index: 1, at: at(300)),
            .segmentEnded(index: 1, at: at(400), reason: .sessionEnded),
            .sessionEnded(at: at(400)),
        ])

        #expect(d.segmentCount == 2)
        #expect(d.recordedDuration == 200)
        #expect(d.sessionDuration == 400)
        #expect(d.coverageRatio == 0.5)
    }

    @Test("終了していないセグメントは録画時間に算入されない")
    func unfinishedSegmentIsNotCounted() {
        let d = make([
            .sessionStarted(at: at(0)),
            .segmentStarted(index: 0, at: at(0)),
            .segmentEnded(index: 0, at: at(50), reason: .interrupted),
            .segmentStarted(index: 1, at: at(60)),  // 終了記録なし（アプリが落ちた等）
            .sessionEnded(at: at(600)),
        ])

        #expect(d.segmentCount == 2)
        #expect(d.recordedDuration == 50)
    }

    @Test("セッション終了が記録されていない場合、カバー率は nil になる")
    func coverageIsNilWithoutSessionEnd() {
        let d = make([
            .sessionStarted(at: at(0)),
            .segmentStarted(index: 0, at: at(0)),
            .segmentEnded(index: 0, at: at(100), reason: .interrupted),
        ])

        #expect(d.sessionDuration == nil)
        #expect(d.coverageRatio == nil)
    }

    // MARK: - 中断

    @Test("中断の発生回数が数えられる")
    func interruptionsAreCounted() {
        let d = make([
            .sessionStarted(at: at(0)),
            .interrupted(at: at(10), reason: "background"),
            .interruptionEnded(at: at(20)),
            .interrupted(at: at(30), reason: "call"),
            .interruptionEnded(at: at(40)),
        ])

        #expect(d.interruptionCount == 2)
    }

    // MARK: - クリップ生成

    @Test("クリップの成功数・失敗数が理由別に集計される")
    func clipOutcomesAreAggregated() {
        let d = make([
            .clipExtracted(sequence: 1, at: at(10)),
            .clipExtracted(sequence: 2, at: at(20)),
            .clipSkipped(sequence: 3, at: at(30), reason: .outOfRecordedRange),
            .clipSkipped(sequence: 4, at: at(40), reason: .outOfRecordedRange),
            .clipSkipped(sequence: 5, at: at(50), reason: .noSourceRecording),
        ])

        #expect(d.clipsExtracted == 2)
        #expect(d.clipsSkipped == 3)
        #expect(d.skipReasonCounts[.outOfRecordedRange] == 2)
        #expect(d.skipReasonCounts[.noSourceRecording] == 1)
        #expect(d.skipReasonCounts[.detectedAtMissing] == nil)
    }

    @Test("セグメントの終了理由が種別ごとに集計される")
    func segmentEndReasonsAreAggregated() {
        let d = make([
            .segmentEnded(index: 0, at: at(100), reason: .interrupted),
            .segmentEnded(index: 1, at: at(200), reason: .maxDuration),
            .segmentEnded(index: 2, at: at(300), reason: .interrupted),
        ])

        #expect(d.segmentEndReasonCounts[.interrupted] == 2)
        #expect(d.segmentEndReasonCounts[.maxDuration] == 1)
        #expect(d.segmentEndReasonCounts[.sessionEnded] == nil)
    }

    // MARK: - 回帰: 2026-07-21 の実機不具合

    @Test("録画が開始直後に停止した場合、低いカバー率と大量のスキップとして現れる")
    func reproducesFieldFailure() {
        // 2026-07-21: 57分のセッションで録画が約20秒で停止し、
        // 325スイング中1件しかクリップが生成されなかった
        var events: [DiagnosticEvent] = [
            .sessionStarted(at: at(0)),
            .segmentStarted(index: 0, at: at(0)),
            .segmentEnded(index: 0, at: at(20), reason: .interrupted),
            .clipExtracted(sequence: 1, at: at(25)),
        ]
        for sequence in 2...325 {
            events.append(.clipSkipped(sequence: sequence, at: at(30), reason: .outOfRecordedRange))
        }
        events.append(.sessionEnded(at: at(3400)))

        let d = make(events)

        #expect(d.clipsExtracted == 1)
        #expect(d.clipsSkipped == 324)
        #expect(d.skipReasonCounts[.outOfRecordedRange] == 324)
        #expect(d.segmentEndReasonCounts[.interrupted] == 1)
        // カバー率 20/3400 ≒ 0.6%。この数値が出ていれば実機検証中に気付けた
        let coverage = try! #require(d.coverageRatio)
        #expect(coverage < 0.01)
    }
}
