//
//  ContinuousRecordingTests.swift
//  TennisAnalyserTests
//
//  ContinuousChunk / ContinuousChunkParser（W6-T14: 連続記録の受信側）のユニットテスト

import Foundation
import Testing
@testable import TennisAnalyser

struct ContinuousRecordingTests {

    // MARK: - Helpers

    /// Watch 側 `ContinuousSensorRepositoryImpl` の出力と同じ形式のチャンクを作る
    private func writeChunk(
        sessionId: String = "session-1",
        chunkIndex: Int = 0,
        anchorSensorMs: Int64 = 2_010,
        anchorWallClock: String = "2023-11-14T22:13:20.125Z",
        rows: [String] = ["2000,0.100000,0.500000,-0.250000,10.0000,-20.0000,30.0000"]
    ) throws -> URL {
        let lines = [
            "# SessionID: \(sessionId)",
            "# ChunkIndex: \(chunkIndex)",
            "# AnchorSensorMs: \(anchorSensorMs)",
            "# AnchorWallClock: \(anchorWallClock)",
            "Timestamp(ms),AccX,AccY,AccZ,GyroX,GyroY,GyroZ",
        ] + rows
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunk-\(UUID().uuidString).csv")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Parser

    // 正常系: ヘッダーからセッションID・チャンク番号・時刻アンカーを復元できること
    @Test func parsesHeader() throws {
        let url = try writeChunk()
        defer { try? FileManager.default.removeItem(at: url) }

        let chunk = try #require(ContinuousChunkParser.parseHeader(fileURL: url))
        #expect(chunk.sessionId == "session-1")
        #expect(chunk.index == 0)
        #expect(chunk.anchorSensorMs == 2_010)
        #expect(chunk.anchorWallClock == Date(timeIntervalSince1970: 1_700_000_000.125))
    }

    // 異常系: ヘッダーが欠けたファイルは nil を返すこと（不正なチャンクを一覧に載せない）
    @Test func returnsNilForMissingAnchor() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("broken-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try "# SessionID: session-1\n# ChunkIndex: 0\n".write(
            to: url, atomically: true, encoding: .utf8
        )

        #expect(ContinuousChunkParser.parseHeader(fileURL: url) == nil)
    }

    // 正常系: データ行をスイング単位CSVと同じパーサで読めること（列構成の一致を保証する）
    @Test func parsesSamplesWithSwingCSVParser() throws {
        let url = try writeChunk(rows: [
            "2000,0.100000,0.500000,-0.250000,10.0000,-20.0000,30.0000",
            "2005,0.200000,0.500000,-0.250000,11.0000,-21.0000,31.0000",
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = ContinuousChunkParser.parseSamples(fileURL: url)
        #expect(samples.count == 2)
        #expect(samples[0].timestampMs == 2_000)
        #expect(samples[1].gyroZ == 31.0)
    }

    // MARK: - 時刻対応付け

    // 正常系: センサータイムスタンプが壁時計へ線形に対応付けられること
    @Test func mapsSensorTimestampToWallClock() throws {
        let url = try writeChunk()
        defer { try? FileManager.default.removeItem(at: url) }
        let chunk = try #require(ContinuousChunkParser.parseHeader(fileURL: url))

        // アンカーより 10ms 前のサンプル
        let wallClock = chunk.wallClock(forSensorMs: 2_000)
        #expect(abs(wallClock.timeIntervalSince1970 - 1_700_000_000.115) < 0.0005)
    }

    // 正常系: 壁時計 → センサータイムスタンプが逆方向にも一致すること（往復）
    @Test func mapsWallClockBackToSensorTimestamp() throws {
        let url = try writeChunk()
        defer { try? FileManager.default.removeItem(at: url) }
        let chunk = try #require(ContinuousChunkParser.parseHeader(fileURL: url))

        let wallClock = chunk.wallClock(forSensorMs: 5_555)
        #expect(chunk.sensorMs(forWallClock: wallClock) == 5_555)
    }
}
