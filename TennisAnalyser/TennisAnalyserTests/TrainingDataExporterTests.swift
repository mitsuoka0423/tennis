//
//  TrainingDataExporterTests.swift
//  TennisAnalyserTests
//
//  TrainingDataExporter（P3-T5: 学習データのエクスポート）のユニットテスト

import Foundation
import Testing
@testable import TennisAnalyser

struct TrainingDataExporterTests {

    private func writeSwingCSV(sessionId: String, sequence: Int) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("csv")
        let content = """
        # SwingID: \(sessionId)-\(sequence)
        # SessionID: \(sessionId)
        # Sequence: \(sequence)
        Timestamp(ms),AccX,AccY,AccZ,GyroX,GyroY,GyroZ,ShotClass
        1000,1.0,0.0,0.0,0.0,0.0,0.0,
        """
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeRecord(sessionId: String, sequence: Int, shotClass: ShotClass?) -> SwingRecord {
        SwingRecord(
            id: "\(sessionId)-\(sequence)",
            sessionId: sessionId,
            sequence: sequence,
            detectedAt: Date(timeIntervalSince1970: 1_700_000_000),
            impactTimestampMs: 1_000,
            peakAcceleration: 3.5,
            shotClass: shotClass,
            fileURL: writeSwingCSV(sessionId: sessionId, sequence: sequence)
        )
    }

    @Test("未タグのスイングのみの場合はエラーを投げる")
    func throwsWhenNoLabeledSwings() {
        let records = [makeRecord(sessionId: "s1", sequence: 1, shotClass: nil)]
        #expect(throws: TrainingDataExportError.self) {
            try TrainingDataExporter.export(records: records)
        }
    }

    @Test("ラベル付きスイングをクラス別フォルダへ整理し manifest を書き出す")
    func exportsLabeledSwingsGroupedByShotClass() throws {
        let records = [
            makeRecord(sessionId: "s1", sequence: 1, shotClass: .strokeForehand),
            makeRecord(sessionId: "s1", sequence: 2, shotClass: .serve),
            makeRecord(sessionId: "s1", sequence: 3, shotClass: nil),  // 未タグは除外される
        ]

        let exportDir = try TrainingDataExporter.export(records: records)
        let fm = FileManager.default

        #expect(fm.fileExists(atPath: exportDir.appendingPathComponent("STROKE_FOREHAND/s1_1.csv").path))
        #expect(fm.fileExists(atPath: exportDir.appendingPathComponent("SERVE/s1_2.csv").path))
        #expect(!fm.fileExists(atPath: exportDir.appendingPathComponent("s1_3.csv").path))

        let manifest = try String(contentsOf: exportDir.appendingPathComponent("manifest.csv"), encoding: .utf8)
        #expect(manifest.contains("s1-1,s1,1,STROKE_FOREHAND"))
        #expect(manifest.contains("s1-2,s1,2,SERVE"))
        #expect(!manifest.contains("s1-3"))
    }
}
