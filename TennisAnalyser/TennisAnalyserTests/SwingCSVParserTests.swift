//
//  SwingCSVParserTests.swift
//  TennisAnalyserTests
//
//  SwingCSVParser（F-I3: ShotClass の読み書き）のユニットテスト

import Foundation
import Testing
@testable import TennisAnalyser

struct SwingCSVParserTests {

    private func writeTempCSV(_ content: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("csv")
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let sampleCSV = """
    # SwingID: swing-1
    # SessionID: session-1
    # Sequence: 3
    # DetectedAt: 2026-07-19T10:00:00Z
    # ImpactTimestampMs: 5000
    # PeakAcceleration: 4.200
    Timestamp(ms),AccX,AccY,AccZ,GyroX,GyroY,GyroZ,ShotClass
    4000,0.100000,0.000000,0.000000,1.0000,0.0000,0.0000,
    5000,4.200000,0.000000,0.000000,2.0000,0.0000,0.0000,
    """

    @Test("shotClass 未設定時は nil を返す")
    func parsesNilShotClassWhenAbsent() {
        let url = writeTempCSV(sampleCSV)
        let record = SwingCSVParser.parseMetadata(fileURL: url)
        #expect(record?.shotClass == nil)
    }

    @Test("writeShotClass 後は parseMetadata が同じ値を返す（ラウンドトリップ）")
    func writeThenParseRoundtrips() throws {
        let url = writeTempCSV(sampleCSV)
        try SwingCSVParser.writeShotClass(fileURL: url, shotClass: .volleyBackhand)

        let record = SwingCSVParser.parseMetadata(fileURL: url)
        #expect(record?.shotClass == .volleyBackhand)

        // データ行の末尾列にも反映されている
        let samples = try String(contentsOf: url, encoding: .utf8)
        #expect(samples.contains(",VOLLEY_BACKHAND"))
    }

    @Test("writeShotClass を2回呼んでも ShotClass 行が重複しない")
    func writeShotClassIsIdempotent() throws {
        let url = writeTempCSV(sampleCSV)
        try SwingCSVParser.writeShotClass(fileURL: url, shotClass: .serve)
        try SwingCSVParser.writeShotClass(fileURL: url, shotClass: .strokeForehand)

        let content = try String(contentsOf: url, encoding: .utf8)
        let shotClassMetaLines = content.split(separator: "\n").filter { $0.hasPrefix("# ShotClass:") }
        #expect(shotClassMetaLines.count == 1)
        #expect(shotClassMetaLines.first == "# ShotClass: STROKE_FOREHAND")

        // ヘッダー行とデータ行の順序が保たれている
        let record = SwingCSVParser.parseMetadata(fileURL: url)
        #expect(record?.sequence == 3)
        let parsedSamples = SwingCSVParser.parseSamples(fileURL: url)
        #expect(parsedSamples.count == 2)
    }
}
