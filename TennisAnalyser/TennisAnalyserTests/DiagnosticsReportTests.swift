//
//  DiagnosticsReportTests.swift
//  TennisAnalyserTests
//
//  DiagnosticsReport（F-I7-5: 診断記録を共有用テキストへ整形する）のユニットテスト

import Testing
import Foundation
@testable import TennisAnalyser

struct DiagnosticsReportTests {

    private let base = Date(timeIntervalSince1970: 1_780_000_000)
    private let sessionId = "TEST-SESSION"

    private func at(_ seconds: TimeInterval) -> Date {
        base.addingTimeInterval(seconds)
    }

    private func text(_ events: [DiagnosticEvent]) -> String {
        DiagnosticsReport.text(sessionId: sessionId, events: events)
    }

    // MARK: - 共有テキストに決め手が含まれること

    @Test("中断理由の文字列が共有テキストにそのまま含まれる")
    func interruptionReasonIsIncluded() {
        let report = text([
            .sessionStarted(at: at(0)),
            .segmentStarted(index: 0, at: at(1)),
            .interrupted(at: at(300), reason: "captureInterrupted(reason=5)"),
            .segmentEnded(index: 0, at: at(300), reason: .interrupted),
        ])

        // 熱・電力の逼迫（reason=5）かどうかは集計には現れず、この文字列だけが手掛かりになる
        #expect(report.contains("captureInterrupted(reason=5)"))
    }

    @Test("セグメント終了理由の内訳が共有テキストに含まれる")
    func segmentEndReasonsAreIncluded() {
        let report = text([
            .segmentEnded(index: 0, at: at(100), reason: .maxDuration),
            .segmentEnded(index: 1, at: at(200), reason: .error),
        ])

        #expect(report.contains("最大長に到達=1"))
        #expect(report.contains("エラー=1"))
    }

    @Test("復帰しなかった中断がある場合、その件数が警告として出る")
    func unresumedInterruptionsAreWarned() {
        let report = text([
            .sessionStarted(at: at(0)),
            .interrupted(at: at(10), reason: "willResignActive"),
            .interruptionEnded(at: at(20)),
            .interrupted(at: at(30), reason: "captureInterrupted(reason=5)"),
            .sessionEnded(at: at(3600)),
        ])

        #expect(report.contains("中断回数: 2 / 復帰回数: 1"))
        #expect(report.contains("復帰しなかった中断が 1 件あります"))
    }

    @Test("復旧の試行と上限到達が共有テキストに含まれる")
    func recoveryAndLimitAreIncluded() {
        let report = text([
            .sessionStarted(at: at(0)),
            .recoveryAttempted(at: at(15), trigger: "supervisor"),
            .sessionLimitReached(at: at(10800), reason: "maxSessionDuration(3h)"),
        ])

        #expect(report.contains("復旧試行: 1"))
        #expect(report.contains("上限に到達して終了: maxSessionDuration(3h)"))
        #expect(report.contains("復旧を試行: supervisor"))
        #expect(report.contains("上限に到達: maxSessionDuration(3h)"))
    }

    @Test("上限に達していないセッションでは上限の行を出さない")
    func limitLineIsOmittedWhenNotReached() {
        let report = text([.sessionStarted(at: at(0)), .sessionEnded(at: at(600))])

        #expect(!report.contains("上限に到達して終了"))
    }

    @Test("中断が全て復帰している場合は警告を出さない")
    func noWarningWhenAllInterruptionsResumed() {
        let report = text([
            .interrupted(at: at(10), reason: "willResignActive"),
            .interruptionEnded(at: at(20)),
        ])

        #expect(!report.contains("復帰しなかった中断"))
    }

    @Test("セッション終了が記録されていない場合、終了欄にその旨が出る")
    func missingSessionEndIsStated() {
        let report = text([.sessionStarted(at: at(0))])

        #expect(report.contains("終了通知なし"))
    }

    // MARK: - タイムライン

    @Test("タイムラインは録画の出来事のみを発生順に並べ、クリップ生成は含めない")
    func timelineExcludesClipEvents() {
        var events: [DiagnosticEvent] = [
            .sessionStarted(at: at(0)),
            .segmentStarted(index: 0, at: at(1)),
            .segmentEnded(index: 0, at: at(600), reason: .maxDuration),
        ]
        // 1セッションで300件を超えるため、並べると録画の経過が埋もれる
        for sequence in 1...325 {
            events.append(.clipSkipped(sequence: sequence, at: at(700), reason: .outOfRecordedRange))
        }

        let timeline = DiagnosticsReport.timeline(from: events)

        #expect(timeline.count == 3)
        #expect(timeline[0].hasSuffix("セッション開始"))
        #expect(timeline[1].hasSuffix("セグメント0 開始"))
        #expect(timeline[2].hasSuffix("セグメント0 終了（最大長に到達）"))
    }

    @Test("タイムラインの各行はミリ秒まで表示する")
    func timelineHasMillisecondPrecision() {
        let line = DiagnosticsReport.line(for: .interruptionEnded(at: at(0.123)))
        let time = try! #require(line?.split(separator: " ").first)

        // 中断から復帰までが数百ミリ秒のことがあり、秒単位では前後関係が読めない
        #expect(time.count == "HH:mm:ss.SSS".count)
        #expect(time.hasSuffix(".123"))
    }

    @Test("クリップ生成の出来事はタイムラインの行を持たない")
    func clipEventsHaveNoLine() {
        #expect(DiagnosticsReport.line(for: .clipExtracted(sequence: 1, at: at(0))) == nil)
        #expect(DiagnosticsReport.line(for: .clipSkipped(sequence: 1, at: at(0), reason: .extractionFailed)) == nil)
    }

    // MARK: - 内訳の並び

    @Test("内訳は宣言順に並び、共有のたびに順序が変わらない")
    func breakdownOrderIsStable() {
        let events: [DiagnosticEvent] = [
            .segmentEnded(index: 0, at: at(100), reason: .error),
            .segmentEnded(index: 1, at: at(200), reason: .sessionEnded),
            .segmentEnded(index: 2, at: at(300), reason: .interrupted),
        ]

        // SegmentEndReason の宣言順は sessionEnded → interrupted → maxDuration → error
        let expected = "セグメント終了理由: セッション終了=1, 中断=1, エラー=1"
        #expect(text(events).contains(expected))
        #expect(text(events) == text(events))
    }
}
