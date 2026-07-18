//
//  SwingStore.swift
//  TennisAnalyser (iOS)
//
//  Infrastructure — 受信済みスイングの永続保管と一覧提供（F-I1/F-I2）

import Foundation
import Combine

/// 受信済みスイングファイルの保管庫
///
/// - 保存先: Documents/swings/{sessionId}/{sequence}.csv（Watch 側と同じレイアウト）
/// - 全量永続保存（NFR: 削除はユーザー操作によるもののみ）
/// - `records` は新しい順（検知時刻降順）
@MainActor
final class SwingStore: ObservableObject {

    @Published private(set) var records: [SwingRecord] = []

    private let fileManager = FileManager.default

    private var swingsDirectory: URL {
        get throws {
            let docs = try fileManager.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            return docs.appendingPathComponent("swings", isDirectory: true)
        }
    }

    // MARK: - Public API

    /// ディスクを再スキャンして一覧を更新する
    func reload() {
        do {
            let dir = try swingsDirectory
            guard fileManager.fileExists(atPath: dir.path) else {
                records = []
                return
            }
            let sessionDirs = try fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            )
            let csvFiles = try sessionDirs.flatMap { sessionDir -> [URL] in
                guard sessionDir.hasDirectoryPath else { return [] }
                return try fileManager.contentsOfDirectory(
                    at: sessionDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
                ).filter { $0.pathExtension == "csv" }
            }
            records = csvFiles
                .compactMap { SwingCSVParser.parseMetadata(fileURL: $0) }
                .sorted { ($0.detectedAt ?? .distantPast) > ($1.detectedAt ?? .distantPast) }
        } catch {
            print("[SwingStore] reload error: \(error)")
        }
    }

    /// 受信ファイルを保管庫に取り込む（PhoneSessionManager から呼ばれる）
    ///
    /// - Parameters:
    ///   - tempURL: WCSession が渡す一時ファイル URL（このメソッド内で移動する必要がある）
    ///   - metadata: 転送時の metadata（sessionId / sequence の復元に使用）
    nonisolated func ingest(tempURL: URL, metadata: [String: Any]?) {
        do {
            let fm = FileManager.default
            let docs = try fm.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            // sessionId / sequence を metadata → CSV ヘッダーの順で解決
            let sessionId = (metadata?["sessionId"] as? String)
                ?? SwingCSVParser.parseMetadata(fileURL: tempURL)?.sessionId
                ?? "unknown-session"
            let sequence = (metadata?["sequence"] as? Int)
                ?? SwingCSVParser.parseMetadata(fileURL: tempURL)?.sequence
                ?? 0

            let dir = docs
                .appendingPathComponent("swings", isDirectory: true)
                .appendingPathComponent(sessionId, isDirectory: true)
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let dest = dir.appendingPathComponent(String(format: "%04d.csv", sequence))
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)  // 再送による重複は上書き
            }
            try fm.moveItem(at: tempURL, to: dest)
            print("[SwingStore] ingested \(sessionId)/\(dest.lastPathComponent)")

            Task { @MainActor in
                self.reload()
            }
        } catch {
            print("[SwingStore] ingest error: \(error)")
        }
    }

    /// スイングにショット種別をタグ付けする（F-I3）
    func setShotClass(_ shotClass: ShotClass, for record: SwingRecord) {
        do {
            try SwingCSVParser.writeShotClass(fileURL: record.fileURL, shotClass: shotClass)
            reload()
        } catch {
            print("[SwingStore] setShotClass error: \(error)")
        }
    }

    /// 複数スイングへ同一のショット種別を一括タグ付けする（ラリー中の連続ショット向け）
    func setShotClass(_ shotClass: ShotClass, for records: [SwingRecord]) {
        for record in records {
            do {
                try SwingCSVParser.writeShotClass(fileURL: record.fileURL, shotClass: shotClass)
            } catch {
                print("[SwingStore] setShotClass error: \(error)")
            }
        }
        reload()
    }

    /// スイングを削除する（ユーザー操作）
    func delete(_ record: SwingRecord) {
        try? fileManager.removeItem(at: record.fileURL)
        let dir = record.fileURL.deletingLastPathComponent()
        if let remaining = try? fileManager.contentsOfDirectory(atPath: dir.path), remaining.isEmpty {
            try? fileManager.removeItem(at: dir)
        }
        reload()
    }
}
