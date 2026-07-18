//
//  SwingRepositoryImplTests.swift
//  TennisAnalyser Watch AppTests
//
//  SwingRepositoryImpl（F-W4: スイング単位CSV永続化）のユニットテスト

import Foundation
import Testing
@testable import TennisAnalyser_Watch_App

struct SwingRepositoryImplTests {

    private func makeSwing(sequence: Int = 1) -> Swing {
        let samples = (0..<3).map { i in
            MotionSample(
                timestampMs: Int64(1_000 + i * 5),
                accX: Double(i) + 0.5, accY: 0, accZ: 0,
                gyroX: 10, gyroY: 20, gyroZ: 30,
                shotClass: nil
            )
        }
        return Swing(
            id: "swing-uuid",
            sessionId: "session-uuid",
            sequence: sequence,
            impactTimestampMs: 1_005,
            detectedAt: Date(timeIntervalSince1970: 1_700_000_000),
            samples: samples
        )
    }

    @Test("CSV にメタ情報ヘッダーとデータ行が含まれる")
    func buildsCSVWithMetadata() {
        let csv = SwingRepositoryImpl.buildCSV(from: makeSwing())
        let lines = csv.split(separator: "\n").map(String.init)

        #expect(lines.contains("# SwingID: swing-uuid"))
        #expect(lines.contains("# SessionID: session-uuid"))
        #expect(lines.contains("# Sequence: 1"))
        #expect(lines.contains("# ImpactTimestampMs: 1005"))
        #expect(lines.contains("Timestamp(ms),AccX,AccY,AccZ,GyroX,GyroY,GyroZ,ShotClass"))
        // データ行: 3サンプル
        #expect(lines.filter { $0.hasPrefix("1") }.count == 3)
        #expect(lines.contains("1000,0.500000,0.000000,0.000000,10.0000,20.0000,30.0000,"))
    }

    @Test("ShotClass 指定時に CSV データ行の末尾へ rawValue が書き込まれる")
    func buildsCSVWithShotClass() {
        let samples = [MotionSample(
            timestampMs: 1_000, accX: 1, accY: 0, accZ: 0,
            gyroX: 0, gyroY: 0, gyroZ: 0, shotClass: .strokeForehand
        )]
        let swing = Swing(
            id: "s", sessionId: "sess", sequence: 1,
            impactTimestampMs: 1_000, detectedAt: Date(), samples: samples
        )
        let csv = SwingRepositoryImpl.buildCSV(from: swing)
        #expect(csv.contains(",STROKE_FOREHAND"))
    }

    @Test("ShotClass の6分類すべてに一意な rawValue が定義されている")
    func shotClassRawValuesAreUnique() {
        let rawValues = Set(ShotClass.allCases.map(\.rawValue))
        #expect(rawValues.count == ShotClass.allCases.count)
        #expect(ShotClass.allCases.count == 6)
    }

    @Test("保存 → 一覧 → 削除のラウンドトリップ")
    func saveListDeleteRoundtrip() async throws {
        let repo = SwingRepositoryImpl()

        let url = try await repo.save(swing: makeSwing(sequence: 7))
        #expect(url.lastPathComponent == "0007.csv")
        #expect(FileManager.default.fileExists(atPath: url.path))

        let files = try repo.listFiles()
        #expect(files.contains(url))

        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("# SessionID: session-uuid"))

        try repo.deleteFile(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // セッションディレクトリも空になったら消える
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }
}
