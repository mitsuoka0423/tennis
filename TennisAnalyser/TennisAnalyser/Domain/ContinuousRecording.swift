//
//  ContinuousRecording.swift
//  TennisAnalyser (iOS)
//
//  Domain — 連続センサー記録（W6-T14）のチャンクと時刻対応付け

import Foundation

/// 連続センサー記録のチャンク1本
///
/// Watch 側の `ContinuousSensorRepositoryImpl` が書き出した CSV に対応する。
/// センサータイムスタンプは Watch の起動からの経過時間であり、動画（壁時計）と
/// 対応付けるには基準点が必要になる。その基準を各チャンクが自身のヘッダーに持つ。
struct ContinuousChunk: Identifiable, Equatable {

    var id: String { "\(sessionId)#\(index)" }

    let sessionId: String
    /// セッション内のチャンク番号（0始まり）
    let index: Int
    let fileURL: URL
    /// 壁時計対応付けの基準となるセンサータイムスタンプ (ms)
    let anchorSensorMs: Int64
    /// `anchorSensorMs` に対応する壁時計時刻
    let anchorWallClock: Date

    /// センサータイムスタンプ (ms) に対応する壁時計時刻
    func wallClock(forSensorMs sensorMs: Int64) -> Date {
        anchorWallClock.addingTimeInterval(Double(sensorMs - anchorSensorMs) / 1000.0)
    }

    /// 壁時計時刻に対応するセンサータイムスタンプ (ms)
    func sensorMs(forWallClock date: Date) -> Int64 {
        anchorSensorMs + Int64((date.timeIntervalSince(anchorWallClock) * 1000.0).rounded())
    }
}

// MARK: - Parser

enum ContinuousChunkParser {

    // 注: プロジェクトは SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor のため、
    // 純関数のパーサは nonisolated を明示してバックグラウンドから呼べるようにする

    /// ヘッダーの先頭バイトだけを読む量。コメント4行＋列見出しに十分な余裕を取る
    private static let headerProbeBytes = 512

    /// チャンクのメタ情報をパースする（ファイル全体は読まない）
    ///
    /// Why not ファイル全体を読む: 1チャンクは 200Hz・5分で約 3.9MB あり、
    /// 一覧表示のたびに全量を文字列化するとセッション単位で数十MBを読むことになる。
    nonisolated static func parseHeader(fileURL: URL) -> ContinuousChunk? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headerProbeBytes),
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        var sessionId: String?
        var index: Int?
        var anchorSensorMs: Int64?
        var anchorWallClock: Date?

        for line in text.split(separator: "\n") {
            guard line.hasPrefix("#") else { break }
            let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
            guard let separator = body.firstIndex(of: ":") else { continue }
            let key = String(body[body.startIndex..<separator])
            let value = String(body[body.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            switch key {
            case "SessionID": sessionId = value
            case "ChunkIndex": index = Int(value)
            case "AnchorSensorMs": anchorSensorMs = Int64(value)
            case "AnchorWallClock": anchorWallClock = Self.parseDate(value)
            default: break
            }
        }

        guard let sessionId, let index, let anchorSensorMs, let anchorWallClock else { return nil }
        return ContinuousChunk(
            sessionId: sessionId,
            index: index,
            fileURL: fileURL,
            anchorSensorMs: anchorSensorMs,
            anchorWallClock: anchorWallClock
        )
    }

    /// 波形サンプルをパースする
    ///
    /// 列構成はスイング単位CSVと同一のため既存パーサを流用する（ShotClass 列のみ無い）。
    nonisolated static func parseSamples(fileURL: URL) -> [SwingSamplePoint] {
        SwingCSVParser.parseSamples(fileURL: fileURL)
    }

    /// ISO8601（小数秒あり／なしの双方）をパースする
    ///
    /// 小数秒つきは `ISO8601DateFormatter` の既定オプションでは解釈できないため、
    /// 明示指定した formatter を先に試す。
    nonisolated private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}
