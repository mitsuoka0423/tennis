//
//  AnnotationStoreTests.swift
//  TennisAnalyserTests
//
//  AnnotationStore（W6-T16a: 永続化・再開・取り消し）のユニットテスト

import Foundation
import Testing
@testable import TennisAnalyser

@MainActor
struct AnnotationStoreTests {

    // MARK: - Helpers

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// Documents は全テストで共有されるため、セッションIDを固有にする
    private func makeSessionId() -> String { "test-annotation-\(UUID().uuidString)" }

    private func cleanUp(sessionId: String) {
        let fm = FileManager.default
        guard let docs = try? fm.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return }
        try? fm.removeItem(
            at: docs.appendingPathComponent("annotations/\(sessionId).json")
        )
    }

    private func makeDetected(sessionId: String, offsets: [Double]) -> [DetectedImpact] {
        offsets.map { offset in
            DetectedImpact(
                sessionId: sessionId,
                chunkIndex: 0,
                impactSensorMs: Int64(offset * 1000),
                impactAt: base.addingTimeInterval(offset),
                peakAcceleration: 8.0,
                gyroPeak: 500
            )
        }
    }

    // MARK: - Tests

    // 正常系: 操作のたびに永続化され、別インスタンスから読み直せること（F-I8-8）
    @Test func persistsEachOperation() {
        let sessionId = makeSessionId()
        defer { cleanUp(sessionId: sessionId) }
        let store = AnnotationStore()
        store.addManualEvent(sessionId: sessionId, impactAt: base)
        let eventId = store.annotation(for: sessionId).events[0].id

        store.confirm(sessionId: sessionId, eventId: eventId, shotClass: .strokeForehand)

        let reloaded = AnnotationStore()
        reloaded.reload()
        let restored = reloaded.annotation(for: sessionId)
        #expect(restored.events.count == 1)
        #expect(restored.events[0].status == .confirmed)
        #expect(restored.events[0].shotClass == .strokeForehand)
    }

    // 正常系: 未保存のセッションでも空のアノテーションが得られること
    @Test func returnsEmptyAnnotationForUnknownSession() {
        let store = AnnotationStore()

        let annotation = store.annotation(for: makeSessionId())

        #expect(annotation.events.isEmpty)
        #expect(annotation.remainingCount == 0)
    }

    // 正常系: 直前の操作を取り消せること（F-I8-2）
    @Test func undoRestoresPreviousState() {
        let sessionId = makeSessionId()
        defer { cleanUp(sessionId: sessionId) }
        let store = AnnotationStore()
        store.addManualEvent(sessionId: sessionId, impactAt: base)
        let eventId = store.annotation(for: sessionId).events[0].id
        store.confirm(sessionId: sessionId, eventId: eventId, shotClass: .serve)

        store.undo(sessionId: sessionId)

        #expect(store.annotation(for: sessionId).events[0].status == .proposed)
        #expect(store.canUndo(sessionId: sessionId))  // 追加操作の分がまだ残る
    }

    // 正常系: 取り消しの結果も永続化されること（取り消し後の強制終了で復活しない）
    @Test func undoIsPersisted() {
        let sessionId = makeSessionId()
        defer { cleanUp(sessionId: sessionId) }
        let store = AnnotationStore()
        store.addManualEvent(sessionId: sessionId, impactAt: base)
        let eventId = store.annotation(for: sessionId).events[0].id
        store.confirm(sessionId: sessionId, eventId: eventId, shotClass: .serve)

        store.undo(sessionId: sessionId)

        let reloaded = AnnotationStore()
        reloaded.reload()
        #expect(reloaded.annotation(for: sessionId).events[0].status == .proposed)
    }

    // 異常系: 履歴が無い状態の取り消しは何も起こさないこと
    @Test func undoWithoutHistoryIsIgnored() {
        let sessionId = makeSessionId()
        let store = AnnotationStore()

        #expect(!store.canUndo(sessionId: sessionId))
        store.undo(sessionId: sessionId)

        #expect(store.annotation(for: sessionId).events.isEmpty)
    }

    // 正常系: 検知結果の取り込みが永続化され、再取り込みでも判断が残ること
    @Test func mergesDetectedCandidatesAndKeepsJudgements() {
        let sessionId = makeSessionId()
        defer { cleanUp(sessionId: sessionId) }
        let store = AnnotationStore()

        store.merge(sessionId: sessionId, detected: makeDetected(sessionId: sessionId, offsets: [0, 10]))
        let eventId = store.annotation(for: sessionId).events[0].id
        store.confirm(sessionId: sessionId, eventId: eventId, shotClass: .strokeBackhand)

        store.merge(sessionId: sessionId, detected: makeDetected(sessionId: sessionId, offsets: [0, 10, 20]))

        let annotation = store.annotation(for: sessionId)
        #expect(annotation.events.count == 3)
        #expect(annotation.events[0].shotClass == .strokeBackhand)
        #expect(annotation.confirmedCount == 1)
    }

    // 正常系: 5ms 粒度のインパクト位置が永続化を跨いで保たれること（F-I8-6）
    @Test func preservesMillisecondPrecisionAcrossReload() {
        let sessionId = makeSessionId()
        defer { cleanUp(sessionId: sessionId) }
        let store = AnnotationStore()
        store.addManualEvent(sessionId: sessionId, impactAt: base.addingTimeInterval(12.005))
        let eventId = store.annotation(for: sessionId).events[0].id

        store.adjustImpact(sessionId: sessionId, eventId: eventId, bySeconds: -0.005)

        let reloaded = AnnotationStore()
        reloaded.reload()
        #expect(reloaded.annotation(for: sessionId).events[0].impactAt == base.addingTimeInterval(12))
    }

    // 正常系: 時刻オフセット補正が永続化されること（F-I8-7）
    @Test func persistsTimeOffset() {
        let sessionId = makeSessionId()
        defer { cleanUp(sessionId: sessionId) }
        let store = AnnotationStore()
        store.addManualEvent(sessionId: sessionId, impactAt: base)

        store.setTimeOffset(sessionId: sessionId, seconds: -0.25)

        let reloaded = AnnotationStore()
        reloaded.reload()
        #expect(reloaded.annotation(for: sessionId).timeOffsetSeconds == -0.25)
    }

    // 正常系: 削除でファイルと履歴が消えること
    @Test func deleteRemovesFileAndHistory() {
        let sessionId = makeSessionId()
        defer { cleanUp(sessionId: sessionId) }
        let store = AnnotationStore()
        store.addManualEvent(sessionId: sessionId, impactAt: base)

        store.deleteAnnotation(sessionId: sessionId)

        #expect(!store.canUndo(sessionId: sessionId))
        let reloaded = AnnotationStore()
        reloaded.reload()
        #expect(reloaded.annotation(for: sessionId).events.isEmpty)
    }
}
