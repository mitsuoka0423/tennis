//
//  AnnotationExporterTests.swift
//  TennisAnalyserTests
//
//  AnnotationExporter / StorageCapacity（W6-T16e/T17）のユニットテスト

import Foundation
import Testing
@testable import TennisAnalyser

struct AnnotationExporterTests {

    // MARK: - Helpers

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// 200Hz・10秒分の連続記録チャンクを作る（アンカーは末尾サンプル）
    private func makeChunk(sessionId: String) throws -> ContinuousChunk {
        let sampleCount = 2_000  // 5ms × 2000 = 10秒
        var lines = [
            "# SessionID: \(sessionId)",
            "# ChunkIndex: 0",
            "# AnchorSensorMs: \((sampleCount - 1) * 5)",
            "# AnchorWallClock: 2023-11-14T22:13:30.000Z",  // base + 10秒
            "Timestamp(ms),AccX,AccY,AccZ,GyroX,GyroY,GyroZ",
        ]
        for index in 0..<sampleCount {
            lines.append("\(index * 5),0.100000,0.000000,0.000000,10.0000,0.0000,0.0000")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-chunk-\(UUID().uuidString).csv")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return try #require(ContinuousChunkParser.parseHeader(fileURL: url))
    }

    private func makeAnnotation(sessionId: String) -> SessionAnnotation {
        // チャンクは base〜base+10秒を覆う。イベントは中央付近に置く
        var annotation = SessionAnnotation(
            sessionId: sessionId,
            events: [
                AnnotatedEvent(id: "e1", impactAt: base.addingTimeInterval(5), detectorPeak: 8.0),
                AnnotatedEvent(id: "e2", impactAt: base.addingTimeInterval(7), detectorPeak: 4.0),
            ]
        )
        annotation.confirm(id: "e1", shotClass: .strokeForehand)
        annotation.reject(id: "e2")
        return annotation
    }

    // MARK: - 書き出し

    // 正常系: 承認済みのみが球種ごとのフォルダへ書き出されること（F-I8-9）
    @Test func exportsConfirmedEventsByShotClass() throws {
        let sessionId = "session-export"
        let chunk = try makeChunk(sessionId: sessionId)
        defer { try? FileManager.default.removeItem(at: chunk.fileURL) }

        let dir = try AnnotationExporter.export(
            annotation: makeAnnotation(sessionId: sessionId), chunks: [chunk]
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("STROKE_FOREHAND").path))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("REJECTED").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("manifest.csv").path))
    }

    // 正常系: 却下を負例として別フォルダへ出せること（F-I8-10）
    @Test func exportsRejectedAsNegativeSamples() throws {
        let sessionId = "session-export"
        let chunk = try makeChunk(sessionId: sessionId)
        defer { try? FileManager.default.removeItem(at: chunk.fileURL) }

        let dir = try AnnotationExporter.export(
            annotation: makeAnnotation(sessionId: sessionId),
            chunks: [chunk],
            includeRejected: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("REJECTED").path))
    }

    // 正常系: 窓長の指定がサンプル数に反映されること（F-I8-9 の主要な利点）
    @Test func windowLengthChangesSampleCount() throws {
        let sessionId = "session-export"
        let chunk = try makeChunk(sessionId: sessionId)
        defer { try? FileManager.default.removeItem(at: chunk.fileURL) }
        let annotation = makeAnnotation(sessionId: sessionId)

        let narrow = try AnnotationExporter.export(
            annotation: annotation, chunks: [chunk],
            window: ExportWindow(preSeconds: 0.5, postSeconds: 0.5)
        )
        defer { try? FileManager.default.removeItem(at: narrow) }
        let wide = try AnnotationExporter.export(
            annotation: annotation, chunks: [chunk],
            window: ExportWindow(preSeconds: 2.0, postSeconds: 2.0)
        )
        defer { try? FileManager.default.removeItem(at: wide) }

        // 200Hz なので 1秒窓 ≒ 201行、4秒窓 ≒ 801行（両端を含む）
        #expect(dataRowCount(in: narrow, className: "STROKE_FOREHAND") == 201)
        #expect(dataRowCount(in: wide, className: "STROKE_FOREHAND") == 801)
    }

    // 正常系: 出力CSVの列構成がスイング単位CSVと一致し、ラベルが入ること
    @Test func writesShotClassColumn() throws {
        let sessionId = "session-export"
        let chunk = try makeChunk(sessionId: sessionId)
        defer { try? FileManager.default.removeItem(at: chunk.fileURL) }

        let dir = try AnnotationExporter.export(
            annotation: makeAnnotation(sessionId: sessionId), chunks: [chunk]
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let content = try #require(firstCSVContent(in: dir, className: "STROKE_FOREHAND"))
        #expect(content.contains("Timestamp(ms),AccX,AccY,AccZ,GyroX,GyroY,GyroZ,ShotClass"))
        #expect(content.contains(",STROKE_FOREHAND"))
        #expect(content.contains("# ShotClass: STROKE_FOREHAND"))
    }

    // 異常系: 承認済みが無ければエラーになること
    @Test func throwsWithoutConfirmedEvents() throws {
        let chunk = try makeChunk(sessionId: "session-export")
        defer { try? FileManager.default.removeItem(at: chunk.fileURL) }

        #expect(throws: AnnotationExportError.self) {
            try AnnotationExporter.export(
                annotation: SessionAnnotation(sessionId: "session-export"), chunks: [chunk]
            )
        }
    }

    // 異常系: 連続記録が無ければエラーになること
    @Test func throwsWithoutSensorData() {
        #expect(throws: AnnotationExportError.self) {
            try AnnotationExporter.export(
                annotation: makeAnnotation(sessionId: "session-export"), chunks: []
            )
        }
    }

    // MARK: - Private

    private func firstCSVContent(in dir: URL, className: String) -> String? {
        let classDir = dir.appendingPathComponent(className, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: classDir, includingPropertiesForKeys: nil
        ), let first = files.first else { return nil }
        return try? String(contentsOf: first, encoding: .utf8)
    }

    private func dataRowCount(in dir: URL, className: String) -> Int {
        guard let content = firstCSVContent(in: dir, className: className) else { return 0 }
        return content.split(separator: "\n").filter {
            !$0.hasPrefix("#") && !$0.hasPrefix("Timestamp")
        }.count
    }
}

struct StorageCapacityTests {

    // 正常系: 1時間の練習を録りきれない空き容量が警告対象になること
    @Test func flagsLowCapacity() {
        let low = StorageCapacity(availableBytes: 3 * 1024 * 1024 * 1024)
        let enough = StorageCapacity(availableBytes: 20 * 1024 * 1024 * 1024)

        #expect(low.isLow)
        #expect(!enough.isLow)
    }

    // 正常系: 録画可能時間が消費量から算出されること
    @Test func estimatesRecordableHours() {
        let capacity = StorageCapacity(availableBytes: StorageCapacity.bytesPerHour * 3)

        #expect(capacity.estimatedRecordableHours == 3.0)
    }
}
