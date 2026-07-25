//
//  ContinuousSensorRepositoryImplTests.swift
//  TennisAnalyser Watch AppTests
//
//  ContinuousSensorRepositoryImpl（W6-T14: センサー全区間記録）のユニットテスト

import Foundation
import Testing
@testable import TennisAnalyser_Watch_App

@MainActor
struct ContinuousSensorRepositoryImplTests {

    // MARK: - Helpers

    private func makeSamples(count: Int, startMs: Int64 = 1_000) -> [MotionSample] {
        (0..<count).map { i in
            MotionSample(
                timestampMs: startMs + Int64(i * 5),
                accX: Double(i) * 0.001, accY: 0.5, accZ: -0.25,
                gyroX: 10, gyroY: -20, gyroZ: 30,
                shotClass: nil
            )
        }
    }

    /// テスト用に固有のセッションIDを作る（Documents は全テストで共有されるため）
    private func makeSessionId() -> String { "test-continuous-\(UUID().uuidString)" }

    private func cleanUp(sessionId: String) {
        let fm = FileManager.default
        guard let docs = try? fm.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return }
        try? fm.removeItem(
            at: docs.appendingPathComponent("continuous/\(sessionId)", isDirectory: true)
        )
    }

    // MARK: - Tests

    // 正常系: append したサンプルが全件 CSV のデータ行として保存されること
    @Test func savesAllAppendedSamples() throws {
        let sessionId = makeSessionId()
        defer { cleanUp(sessionId: sessionId) }
        let repo = ContinuousSensorRepositoryImpl()

        repo.beginSession(sessionId: sessionId)
        repo.append(makeSamples(count: 500), receivedAt: Date())
        repo.endSession()

        let files = try repo.listFiles().filter { $0.path.contains(sessionId) }
        #expect(files.count == 1)
        let content = try String(contentsOf: files[0], encoding: .utf8)
        let dataRows = content.split(separator: "\n").filter {
            !$0.hasPrefix("#") && !$0.hasPrefix("Timestamp")
        }
        #expect(dataRows.count == 500)
    }

    // 正常系: 1行目の列構成がスイング単位CSVと同一（ShotClass 列のみ無い）であること
    @Test func writesSevenColumnsPerSample() throws {
        let sessionId = makeSessionId()
        defer { cleanUp(sessionId: sessionId) }
        let repo = ContinuousSensorRepositoryImpl()

        repo.beginSession(sessionId: sessionId)
        repo.append(makeSamples(count: 1, startMs: 4_000), receivedAt: Date())
        repo.endSession()

        let files = try repo.listFiles().filter { $0.path.contains(sessionId) }
        let content = try String(contentsOf: files[0], encoding: .utf8)
        let lines = content.split(separator: "\n")
        #expect(lines.contains("Timestamp(ms),AccX,AccY,AccZ,GyroX,GyroY,GyroZ"))

        let dataRow = try #require(lines.last { !$0.hasPrefix("#") && !$0.hasPrefix("Timestamp") })
        let columns = dataRow.split(separator: ",")
        #expect(columns.count == 7)
        #expect(columns[0] == "4000")
    }

    // 正常系: サンプル数が上限に達するとチャンクが分割されること
    @Test func rotatesChunkAtMaxSamples() throws {
        let sessionId = makeSessionId()
        defer { cleanUp(sessionId: sessionId) }
        let repo = ContinuousSensorRepositoryImpl()
        repo.maxSamplesPerChunk = 100

        repo.beginSession(sessionId: sessionId)
        for batch in 0..<3 {
            repo.append(makeSamples(count: 100, startMs: Int64(batch) * 1_000), receivedAt: Date())
        }
        repo.endSession()

        let files = try repo.listFiles().filter { $0.path.contains(sessionId) }
        #expect(files.count == 3)
        #expect(files.map(\.lastPathComponent) == ["0000.csv", "0001.csv", "0002.csv"])
    }

    // 正常系: 書き込み中のチャンクは転送対象（listFiles）に現れないこと
    @Test func excludesOpenChunkFromListFiles() throws {
        let sessionId = makeSessionId()
        defer { cleanUp(sessionId: sessionId) }
        let repo = ContinuousSensorRepositoryImpl()

        repo.beginSession(sessionId: sessionId)
        repo.append(makeSamples(count: 300), receivedAt: Date())

        #expect(try repo.listFiles().filter { $0.path.contains(sessionId) }.isEmpty)

        repo.endSession()
        #expect(try repo.listFiles().filter { $0.path.contains(sessionId) }.count == 1)
    }

    // 正常系: ヘッダーがセンサータイムスタンプと壁時計の対応付けを保持すること
    @Test func writesClockAnchorInHeader() throws {
        let sessionId = makeSessionId()
        defer { cleanUp(sessionId: sessionId) }
        let repo = ContinuousSensorRepositoryImpl()
        let receivedAt = Date(timeIntervalSince1970: 1_700_000_000.125)

        repo.beginSession(sessionId: sessionId)
        // アンカーはバッチ末尾のサンプル（= 受信時刻に最も近いサンプル）
        repo.append(makeSamples(count: 3, startMs: 2_000), receivedAt: receivedAt)
        repo.endSession()

        let files = try repo.listFiles().filter { $0.path.contains(sessionId) }
        let content = try String(contentsOf: files[0], encoding: .utf8)
        #expect(content.contains("# SessionID: \(sessionId)"))
        #expect(content.contains("# ChunkIndex: 0"))
        #expect(content.contains("# AnchorSensorMs: 2010"))
        #expect(content.contains("# AnchorWallClock: 2023-11-14T22:13:20.125Z"))
    }

    // 異常系: beginSession 前の append は破棄され、後続セッションに混ざらないこと
    @Test func discardsAppendBeforeBeginSession() throws {
        let sessionId = makeSessionId()
        defer { cleanUp(sessionId: sessionId) }
        let repo = ContinuousSensorRepositoryImpl()

        repo.append(makeSamples(count: 10), receivedAt: Date())
        repo.beginSession(sessionId: sessionId)
        repo.endSession()

        #expect(try repo.listFiles().filter { $0.path.contains(sessionId) }.isEmpty)
    }

    // 正常系: 転送完了後の削除でチャンクとセッションディレクトリが消えること
    @Test func deletesChunkAndEmptySessionDirectory() throws {
        let sessionId = makeSessionId()
        defer { cleanUp(sessionId: sessionId) }
        let repo = ContinuousSensorRepositoryImpl()

        repo.beginSession(sessionId: sessionId)
        repo.append(makeSamples(count: 10), receivedAt: Date())
        repo.endSession()

        let files = try repo.listFiles().filter { $0.path.contains(sessionId) }
        let sessionDir = files[0].deletingLastPathComponent()
        try repo.deleteFile(at: files[0])

        #expect(!FileManager.default.fileExists(atPath: files[0].path))
        #expect(!FileManager.default.fileExists(atPath: sessionDir.path))
    }
}
