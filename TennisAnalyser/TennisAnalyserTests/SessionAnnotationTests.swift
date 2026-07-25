//
//  SessionAnnotationTests.swift
//  TennisAnalyserTests
//
//  SessionAnnotation（W6-T16a: 選別の状態遷移と進捗集計）のユニットテスト

import Foundation
import Testing
@testable import TennisAnalyser

struct SessionAnnotationTests {

    // MARK: - Helpers

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeAnnotation(eventCount: Int) -> SessionAnnotation {
        let events = (0..<eventCount).map { index in
            AnnotatedEvent(
                id: "event-\(index)",
                impactAt: base.addingTimeInterval(Double(index) * 10),
                detectorPeak: 5.0 + Double(index)
            )
        }
        return SessionAnnotation(sessionId: "session-1", events: events)
    }

    private func makeDetected(offsets: [Double], peak: Double = 8.0) -> [DetectedImpact] {
        offsets.map { offset in
            DetectedImpact(
                sessionId: "session-1",
                chunkIndex: 0,
                impactSensorMs: Int64(offset * 1000),
                impactAt: base.addingTimeInterval(offset),
                peakAcceleration: peak,
                gyroPeak: 500
            )
        }
    }

    // MARK: - 状態遷移

    // 正常系: 承認で状態と球種が同時に決まること（F-I8-2 の1操作完了）
    @Test func confirmSetsStatusAndShotClass() {
        var annotation = makeAnnotation(eventCount: 3)

        annotation.confirm(id: "event-1", shotClass: .strokeForehand)

        let event = annotation.events.first { $0.id == "event-1" }
        #expect(event?.status == .confirmed)
        #expect(event?.shotClass == .strokeForehand)
    }

    // 正常系: 却下では球種が付かないこと
    @Test func rejectLeavesShotClassEmpty() {
        var annotation = makeAnnotation(eventCount: 2)

        annotation.reject(id: "event-0")

        let event = annotation.events.first { $0.id == "event-0" }
        #expect(event?.status == .rejected)
        #expect(event?.shotClass == nil)
    }

    // 正常系: 取り消しで未レビューへ戻り、球種も落ちること
    @Test func unreviewClearsShotClass() {
        var annotation = makeAnnotation(eventCount: 2)
        annotation.confirm(id: "event-0", shotClass: .serve)

        annotation.unreview(id: "event-0")

        let event = annotation.events.first { $0.id == "event-0" }
        #expect(event?.status == .proposed)
        #expect(event?.shotClass == nil)
    }

    // 正常系: 連続する候補へ球種を一括付与できること（F-I8-3）
    @Test func bulkConfirmAppliesToAllGivenEvents() {
        var annotation = makeAnnotation(eventCount: 5)

        annotation.confirm(
            ids: ["event-1", "event-2", "event-3"], shotClass: .strokeBackhand
        )

        #expect(annotation.confirmedCount == 3)
        #expect(annotation.events.filter { $0.shotClass == .strokeBackhand }.count == 3)
    }

    // 異常系: 存在しないIDへの操作は何も変えないこと
    @Test func operationOnUnknownIdIsIgnored() {
        var annotation = makeAnnotation(eventCount: 2)
        let before = annotation.events

        annotation.confirm(id: "missing", shotClass: .serve)

        #expect(annotation.events == before)
    }

    // MARK: - 進捗集計

    // 正常系: 進捗が承認・却下の合計として集計されること
    @Test func aggregatesProgress() {
        var annotation = makeAnnotation(eventCount: 4)

        annotation.confirm(id: "event-0", shotClass: .strokeForehand)
        annotation.reject(id: "event-1")

        #expect(annotation.reviewedCount == 2)
        #expect(annotation.confirmedCount == 1)
        #expect(annotation.rejectedCount == 1)
        #expect(annotation.remainingCount == 2)
    }

    // 正常系: 再開位置が未レビューの先頭を指すこと（F-I8-8）
    @Test func firstUnreviewedIndexPointsToResumePosition() {
        var annotation = makeAnnotation(eventCount: 4)
        annotation.confirm(id: "event-0", shotClass: .serve)
        annotation.reject(id: "event-1")

        #expect(annotation.firstUnreviewedIndex == 2)
    }

    // 正常系: 全件レビュー済みなら再開位置が無いこと
    @Test func firstUnreviewedIndexIsNilWhenComplete() {
        var annotation = makeAnnotation(eventCount: 2)
        annotation.confirm(id: "event-0", shotClass: .serve)
        annotation.confirm(id: "event-1", shotClass: .serve)

        #expect(annotation.firstUnreviewedIndex == nil)
    }

    // MARK: - 見落としの補完と位置調整

    // 正常系: 手動追加が時刻順に挿入され、由来が manual になること（F-I8-5）
    @Test func addsManualEventInChronologicalOrder() {
        var annotation = makeAnnotation(eventCount: 3)

        let added = annotation.addManualEvent(impactAt: base.addingTimeInterval(15))

        #expect(annotation.events.count == 4)
        #expect(annotation.events[2].id == added.id)
        #expect(annotation.events[2].origin == .manual)
        #expect(annotation.events[2].status == .proposed)
    }

    // 正常系: インパクト位置の微調整が時刻順を保つこと（F-I8-6）
    @Test func adjustImpactKeepsChronologicalOrder() {
        var annotation = makeAnnotation(eventCount: 3)

        // event-0 を 15秒後ろへずらすと event-1 を追い越す
        annotation.adjustImpact(id: "event-0", bySeconds: 15)

        #expect(annotation.events.map(\.id) == ["event-1", "event-0", "event-2"])
    }

    // MARK: - 時刻の全体補正（F-I8-7）

    // 正常系: 補正が書き出し対象へ一律に適用され、保持値は元のままであること
    @Test func timeOffsetAppliesToExportOnly() {
        var annotation = makeAnnotation(eventCount: 2)
        annotation.confirm(id: "event-0", shotClass: .serve)
        annotation.setTimeOffset(0.5)

        #expect(annotation.events[0].impactAt == base)
        #expect(annotation.confirmedEventsForExport[0].impactAt == base.addingTimeInterval(0.5))
    }

    // MARK: - 検知結果の取り込み

    // 正常系: 初回の取り込みで全候補が未レビューとして入ること
    @Test func mergeInsertsAllCandidatesAsProposed() {
        var annotation = SessionAnnotation(sessionId: "session-1")

        annotation.merge(detected: makeDetected(offsets: [0, 10, 20]))

        #expect(annotation.events.count == 3)
        #expect(annotation.events.allSatisfy { $0.status == .proposed })
        #expect(annotation.events.allSatisfy { $0.origin == .detector })
        #expect(annotation.events[0].detectorPeak == 8.0)
    }

    // 正常系: 再検知しても承認済みの球種が失われないこと
    @Test func mergeKeepsConfirmedJudgements() {
        var annotation = makeAnnotation(eventCount: 3)
        annotation.confirm(id: "event-1", shotClass: .volleyForehand)

        annotation.merge(detected: makeDetected(offsets: [0, 10, 20], peak: 9.5))

        let event = annotation.events.first { $0.id == "event-1" }
        #expect(event?.status == .confirmed)
        #expect(event?.shotClass == .volleyForehand)
        // 参考値だけは新しい検知結果で更新される
        #expect(event?.detectorPeak == 9.5)
    }

    // 正常系: 却下は再検知でも保持されること（F-I8-10 の負例）
    @Test func mergeKeepsRejectedEvents() {
        var annotation = makeAnnotation(eventCount: 2)
        annotation.reject(id: "event-0")

        // 閾値を上げて event-0 が検知されなくなった状況
        annotation.merge(detected: makeDetected(offsets: [10]))

        #expect(annotation.events.count == 2)
        #expect(annotation.events.first { $0.id == "event-0" }?.status == .rejected)
    }

    // 正常系: 未レビューのまま検知されなくなった候補は消えること
    @Test func mergeDropsStaleProposedCandidates() {
        var annotation = makeAnnotation(eventCount: 3)

        annotation.merge(detected: makeDetected(offsets: [10]))

        #expect(annotation.events.count == 1)
        #expect(annotation.events[0].id == "event-1")
    }

    // 正常系: 手動追加は検知結果に無くても保持されること
    @Test func mergeKeepsManualEvents() {
        var annotation = SessionAnnotation(sessionId: "session-1")
        let manual = annotation.addManualEvent(impactAt: base.addingTimeInterval(100))

        annotation.merge(detected: makeDetected(offsets: [0]))

        #expect(annotation.events.contains { $0.id == manual.id })
    }

    // 正常系: 微調整済みの位置が再検知で巻き戻らないこと
    @Test func mergeKeepsAdjustedImpactPosition() {
        var annotation = makeAnnotation(eventCount: 1)
        annotation.confirm(id: "event-0", shotClass: .serve)
        annotation.adjustImpact(id: "event-0", bySeconds: 0.1)

        annotation.merge(detected: makeDetected(offsets: [0]))

        #expect(annotation.events.count == 1)
        #expect(annotation.events[0].impactAt == base.addingTimeInterval(0.1))
    }

}
