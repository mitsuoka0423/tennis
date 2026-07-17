//
//  SessionRepositoryImpl.swift
//  TennisAnalyser Watch App
//
//  Infrastructure — SwingSession を CSV ファイルへ永続化する実装

import Foundation

/// CSV ファイルへの書き出しによる SessionRepository 実装
///
/// - 保存先: App の Documents ディレクトリ以下の `sessions/` フォルダ
/// - ファイル名: `{sessionId}.csv`
/// - フォーマット: `Timestamp(ms),AccX,AccY,AccZ,GyroX,GyroY,GyroZ,ShotClass`
final class SessionRepositoryImpl: SessionRepository {

    // MARK: - Constants

    private static let directoryName = "sessions"
    private static let csvHeader = "Timestamp(ms),AccX,AccY,AccZ,GyroX,GyroY,GyroZ,ShotClass"

    // MARK: - Private

    private let fileManager = FileManager.default

    private var sessionsDirectory: URL {
        get throws {
            let docs = try fileManager.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dir = docs.appendingPathComponent(Self.directoryName, isDirectory: true)
            if !fileManager.fileExists(atPath: dir.path) {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            return dir
        }
    }

    // MARK: - SessionRepository

    func save(session: SwingSession) async throws {
        let url = try fileURL(for: session.id)
        let csvContent = buildCSV(from: session)

        // バッファリング書き出し（大容量データのため非同期ファイルI/Oを使用）
        try await Task.detached(priority: .utility) {
            try csvContent.write(to: url, atomically: true, encoding: .utf8)
        }.value
    }

    func listSessions() async throws -> [SwingSession] {
        let dir = try sessionsDirectory
        let contents = try fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        )
        let csvFiles = contents.filter { $0.pathExtension == "csv" }

        // セッションのメタ情報（サンプル非ロード）を返す軽量実装
        return csvFiles.compactMap { url -> SwingSession? in
            let sessionId = url.deletingPathExtension().lastPathComponent
            let attrs = try? fileManager.attributesOfItem(atPath: url.path)
            let createdAt = attrs?[.creationDate] as? Date ?? Date()
            // サンプルは必要に応じて別途ロードする設計（listSessions は軽量）
            return SwingSession(id: sessionId, startedAt: createdAt, endedAt: createdAt, samples: [])
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    func delete(sessionId: String) async throws {
        let url = try fileURL(for: sessionId)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func fileURL(for sessionId: String) throws -> URL {
        try sessionsDirectory.appendingPathComponent("\(sessionId).csv")
    }

    // MARK: - CSV Builder

    private func buildCSV(from session: SwingSession) -> String {
        var lines: [String] = []
        lines.reserveCapacity(session.samples.count + 2)

        // セッションメタ情報をコメント行として先頭に付与
        lines.append("# SessionID: \(session.id)")
        lines.append("# StartedAt: \(ISO8601DateFormatter().string(from: session.startedAt))")
        if let endedAt = session.endedAt {
            lines.append("# EndedAt: \(ISO8601DateFormatter().string(from: endedAt))")
        }
        if let rate = session.measuredSamplingRate {
            lines.append(String(format: "# MeasuredHz: %.1f", rate))
        }

        // ヘッダー行
        lines.append(Self.csvHeader)

        // データ行
        for sample in session.samples {
            let shotClassStr = sample.shotClass?.rawValue ?? ""
            let line = String(
                format: "%lld,%.6f,%.6f,%.6f,%.4f,%.4f,%.4f,%@",
                sample.timestampMs,
                sample.accX, sample.accY, sample.accZ,
                sample.gyroX, sample.gyroY, sample.gyroZ,
                shotClassStr
            )
            lines.append(line)
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
