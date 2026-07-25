//
//  ContinuousSensorStore.swift
//  TennisAnalyser (iOS)
//
//  Infrastructure — Watch から受信した連続センサー記録の保管と一覧提供（W6-T14）

import Foundation
import Combine
import os

/// 受信済み連続センサー記録の保管庫
///
/// - 保存先: Documents/continuous/{sessionId}/{chunkIndex}.csv（Watch 側と同じレイアウト）
/// - 全量永続保存（F-I7-4: 削除はユーザー操作によるもののみ）
@MainActor
final class ContinuousSensorStore: ObservableObject {

    /// セッションIDごとのチャンク（チャンク番号の昇順）
    @Published private(set) var chunksBySession: [String: [ContinuousChunk]] = [:]

    private let fileManager = FileManager.default

    private var continuousDirectory: URL {
        get throws {
            let docs = try fileManager.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            return docs.appendingPathComponent("continuous", isDirectory: true)
        }
    }

    // MARK: - Public API

    /// ディスクを再スキャンして一覧を更新する
    func reload() {
        do {
            let dir = try continuousDirectory
            guard fileManager.fileExists(atPath: dir.path) else {
                chunksBySession = [:]
                return
            }
            let sessionDirs = try fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            )
            var result: [String: [ContinuousChunk]] = [:]
            for sessionDir in sessionDirs where sessionDir.hasDirectoryPath {
                let files = try fileManager.contentsOfDirectory(
                    at: sessionDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
                ).filter { $0.pathExtension == "csv" }
                let chunks = files
                    .compactMap { ContinuousChunkParser.parseHeader(fileURL: $0) }
                    .sorted { $0.index < $1.index }
                if !chunks.isEmpty {
                    result[sessionDir.lastPathComponent] = chunks
                }
            }
            chunksBySession = result
        } catch {
            AppLog.store.error("continuous reload failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// セッションのチャンクを返す（チャンク番号の昇順）
    func chunks(for sessionId: String) -> [ContinuousChunk] {
        chunksBySession[sessionId] ?? []
    }

    /// 連続記録を持つセッションID（新しい順）
    var sessionIds: [String] {
        chunksBySession
            .sorted { ($0.value.first?.anchorWallClock ?? .distantPast) > ($1.value.first?.anchorWallClock ?? .distantPast) }
            .map(\.key)
    }

    /// 受信チャンクを保管庫に取り込む（`PhoneSessionManager` から呼ばれる）
    ///
    /// - Parameters:
    ///   - tempURL: WCSession が渡す一時ファイル URL（このメソッド内で移動する必要がある）
    ///   - metadata: 転送時の metadata（sessionId / chunkIndex の復元に使用）
    nonisolated func ingest(tempURL: URL, metadata: [String: Any]?) {
        do {
            let fm = FileManager.default
            let docs = try fm.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            // metadata が欠けても CSV ヘッダーから復元できる（Watch 側と冗長設計を揃える）
            let header = ContinuousChunkParser.parseHeader(fileURL: tempURL)
            let sessionId = (metadata?["sessionId"] as? String) ?? header?.sessionId ?? "unknown-session"
            let chunkIndex = (metadata?["chunkIndex"] as? Int) ?? header?.index ?? 0

            let dir = docs
                .appendingPathComponent("continuous", isDirectory: true)
                .appendingPathComponent(sessionId, isDirectory: true)
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let dest = dir.appendingPathComponent(String(format: "%04d.csv", chunkIndex))
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)  // 再送による重複は上書き
            }
            try fm.moveItem(at: tempURL, to: dest)
            AppLog.store.info(
                "ingested chunk \(sessionId, privacy: .public)/\(dest.lastPathComponent, privacy: .public)"
            )
            Task { @MainActor in self.reload() }
        } catch {
            AppLog.store.error("chunk ingest failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// セッションの連続記録を削除する（ユーザー操作）
    func deleteSession(sessionId: String) {
        guard let dir = try? continuousDirectory.appendingPathComponent(sessionId, isDirectory: true)
        else { return }
        try? fileManager.removeItem(at: dir)
        reload()
    }
}
