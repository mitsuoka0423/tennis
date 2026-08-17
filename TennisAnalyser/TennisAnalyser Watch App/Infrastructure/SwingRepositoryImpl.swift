//
//  SwingRepositoryImpl.swift
//  TennisAnalyser Watch App
//
//  Infrastructure — Swing を 1スイング=1CSV で永続化する実装（F-W4）

import Foundation

/// スイング単位 CSV ファイルによる SwingRepository 実装
///
/// - 保存先: Documents/swings/{sessionId}/{sequence}.csv
/// - フォーマット: メタ情報コメント行 + ヘッダー + データ行
///   `Timestamp(ms),AccX,AccY,AccZ,GyroX,GyroY,GyroZ,ShotClass`
final class SwingRepositoryImpl: SwingRepository {

    // MARK: - Constants

    private static let directoryName = "swings"
    private static let csvHeader = "Timestamp(ms),AccX,AccY,AccZ,GyroX,GyroY,GyroZ,ShotClass"

    /// 小数秒つき ISO8601（連続記録のチャンクヘッダーと同じ形式）
    nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - Private

    private let fileManager = FileManager.default

    private var swingsDirectory: URL {
        get throws {
            let docs = try fileManager.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            return docs.appendingPathComponent(Self.directoryName, isDirectory: true)
        }
    }

    // MARK: - SwingRepository

    @discardableResult
    func save(swing: Swing) async throws -> URL {
        let dir = try swingsDirectory.appendingPathComponent(swing.sessionId, isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let url = dir.appendingPathComponent(String(format: "%04d.csv", swing.sequence))
        let csvContent = Self.buildCSV(from: swing)

        try await Task.detached(priority: .utility) {
            try csvContent.write(to: url, atomically: true, encoding: .utf8)
        }.value
        return url
    }

    func listFiles() throws -> [URL] {
        let dir = try swingsDirectory
        guard fileManager.fileExists(atPath: dir.path) else { return [] }
        let sessionDirs = try fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )
        return try sessionDirs.flatMap { sessionDir -> [URL] in
            guard sessionDir.hasDirectoryPath else { return [] }
            return try fileManager.contentsOfDirectory(
                at: sessionDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            ).filter { $0.pathExtension == "csv" }
        }.sorted { $0.path < $1.path }
    }

    func deleteFile(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
        // セッションディレクトリが空になったら削除（ストレージ保護）
        let dir = url.deletingLastPathComponent()
        if let remaining = try? fileManager.contentsOfDirectory(atPath: dir.path), remaining.isEmpty {
            try? fileManager.removeItem(at: dir)
        }
    }

    // MARK: - CSV Builder

    static func buildCSV(from swing: Swing) -> String {
        var lines: [String] = []
        lines.reserveCapacity(swing.samples.count + 8)

        // メタ情報（iOS 側は転送 metadata と本ヘッダーの両方から復元可能）
        lines.append("# SwingID: \(swing.id)")
        lines.append("# SessionID: \(swing.sessionId)")
        lines.append("# Sequence: \(swing.sequence)")
        // 小数秒つき: 既定の ISO8601DateFormatter は秒で切り捨てる。
        // detectedAt はクリップの切り出し位置を決めるため、秒に丸めると
        // 前後2秒窓の中で最大1秒ずれる（F-I9-9）
        lines.append("# DetectedAt: \(Self.iso8601.string(from: swing.detectedAt))")
        lines.append("# ImpactTimestampMs: \(swing.impactTimestampMs)")
        lines.append(String(format: "# PeakAcceleration: %.3f", swing.peakAcceleration))

        lines.append(Self.csvHeader)

        for sample in swing.samples {
            let shotClassStr = sample.shotClass?.rawValue ?? ""
            lines.append(String(
                format: "%lld,%.6f,%.6f,%.6f,%.4f,%.4f,%.4f,%@",
                sample.timestampMs,
                sample.accX, sample.accY, sample.accZ,
                sample.gyroX, sample.gyroY, sample.gyroZ,
                shotClassStr
            ))
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
