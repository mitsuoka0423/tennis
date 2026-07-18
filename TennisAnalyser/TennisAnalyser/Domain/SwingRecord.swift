//
//  SwingRecord.swift
//  TennisAnalyser (iOS)
//
//  Domain — 受信済みスイングのモデルと CSV パーサ
//  注: Watch 側 Domain とはターゲットが別のため独立定義（将来は共有パッケージ化を検討）

import Foundation

/// 1サンプル分のセンサーデータ（波形表示用）
struct SwingSamplePoint: Identifiable {
    let id = UUID()
    let timestampMs: Int64
    let accX: Double
    let accY: Double
    let accZ: Double
    let gyroX: Double
    let gyroY: Double
    let gyroZ: Double

    var accelerationMagnitude: Double {
        (accX * accX + accY * accY + accZ * accZ).squareRoot()
    }
}

/// 受信済みスイング（一覧表示用のメタ情報 + 遅延ロードされる波形）
struct SwingRecord: Identifiable, Equatable {
    let id: String
    let sessionId: String
    let sequence: Int
    let detectedAt: Date?
    let peakAcceleration: Double?
    let fileURL: URL

    static func == (lhs: SwingRecord, rhs: SwingRecord) -> Bool { lhs.id == rhs.id }
}

// MARK: - CSV Parser

enum SwingCSVParser {

    /// メタ情報のみをパースする（一覧表示用・先頭行のみ読む軽量処理）
    static func parseMetadata(fileURL: URL) -> SwingRecord? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        var meta: [String: String] = [:]
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("# ") else { break }  // メタ情報はファイル先頭に連続
            let body = line.dropFirst(2)
            guard let sep = body.range(of: ": ") else { continue }
            meta[String(body[..<sep.lowerBound])] = String(body[sep.upperBound...])
        }

        // フォールバック: メタ欠損時はパス（swings/{sessionId}/{seq}.csv）から復元
        let sessionId = meta["SessionID"] ?? fileURL.deletingLastPathComponent().lastPathComponent
        let sequence = meta["Sequence"].flatMap(Int.init)
            ?? Int(fileURL.deletingPathExtension().lastPathComponent) ?? 0

        return SwingRecord(
            id: meta["SwingID"] ?? "\(sessionId)-\(sequence)",
            sessionId: sessionId,
            sequence: sequence,
            detectedAt: meta["DetectedAt"].flatMap { ISO8601DateFormatter().date(from: $0) },
            peakAcceleration: meta["PeakAcceleration"].flatMap(Double.init),
            fileURL: fileURL
        )
    }

    /// 波形サンプルをパースする（詳細表示用）
    static func parseSamples(fileURL: URL) -> [SwingSamplePoint] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return content.split(separator: "\n").compactMap { line -> SwingSamplePoint? in
            guard !line.hasPrefix("#"), !line.hasPrefix("Timestamp") else { return nil }
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 7,
                  let ts = Int64(cols[0]),
                  let ax = Double(cols[1]), let ay = Double(cols[2]), let az = Double(cols[3]),
                  let gx = Double(cols[4]), let gy = Double(cols[5]), let gz = Double(cols[6])
            else { return nil }
            return SwingSamplePoint(
                timestampMs: ts,
                accX: ax, accY: ay, accZ: az,
                gyroX: gx, gyroY: gy, gyroZ: gz
            )
        }
    }
}
