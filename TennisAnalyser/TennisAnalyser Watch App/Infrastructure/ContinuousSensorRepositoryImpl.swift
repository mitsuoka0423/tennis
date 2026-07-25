//
//  ContinuousSensorRepositoryImpl.swift
//  TennisAnalyser Watch App
//
//  Infrastructure — センサー全区間記録をチャンク分割CSVで永続化する実装（W6-T14）

import Foundation
import os

/// 連続センサー記録のチャンク分割 CSV 実装
///
/// - 保存先: Documents/continuous/{sessionId}/{chunkIndex}.csv
/// - フォーマット: メタ情報コメント行 + ヘッダー + データ行
///   `Timestamp(ms),AccX,AccY,AccZ,GyroX,GyroY,GyroZ`
///
/// 列構成をスイング単位CSVの ShotClass 列以外と一致させている。
/// iPhone 側の `SwingCSVParser.parseSamples` をそのまま流用できるため。
/// ラベルは列ではなくアノテーション層（F-I8）が独立して持つ。
final class ContinuousSensorRepositoryImpl: ContinuousSensorRepository {

    // MARK: - Constants

    private static let directoryName = "continuous"
    private static let csvHeader = "Timestamp(ms),AccX,AccY,AccZ,GyroX,GyroY,GyroZ"

    // MARK: - Configuration

    /// 1チャンクに収めるサンプル数の上限（200Hz で5分 ≒ 3.9MB）
    ///
    /// Why not 1セッション1ファイル: 1時間で約46MB になり、転送が途中で失敗したときに
    /// 全量を送り直すことになる。チャンクごとなら未転送分だけを再送できる。
    var maxSamplesPerChunk: Int = 60_000

    /// メモリバッファをディスクへ落とすサンプル数（200Hz で約1秒）
    var flushThreshold: Int = 200

    // MARK: - State

    private var sessionId: String?
    private var chunkIndex: Int = 0
    /// 書き込み中チャンクのファイル URL（nil = 次のサンプルで新規作成する）
    private var currentChunkURL: URL?
    private var samplesInCurrentChunk: Int = 0
    private var buffer: [MotionSample] = []

    /// ファイル書き込み専用の直列キュー。追記の順序を保証する
    private let writeQueue = DispatchQueue(
        label: "com.spleeing.TennisAnalyser.continuousWrite", qos: .utility
    )

    private let fileManager = FileManager.default

    // MARK: - ContinuousSensorRepository

    func beginSession(sessionId: String) {
        self.sessionId = sessionId
        chunkIndex = 0
        currentChunkURL = nil
        samplesInCurrentChunk = 0
        buffer = []
    }

    func append(_ samples: [MotionSample], receivedAt: Date) {
        guard sessionId != nil, !samples.isEmpty else { return }

        if currentChunkURL == nil {
            openChunk(firstBatch: samples, receivedAt: receivedAt)
        }

        buffer.append(contentsOf: samples)
        samplesInCurrentChunk += samples.count

        if buffer.count >= flushThreshold {
            flush()
        }
        if samplesInCurrentChunk >= maxSamplesPerChunk {
            closeChunk()
        }
    }

    func endSession() {
        guard sessionId != nil else { return }
        closeChunk()
        sessionId = nil
        // 転送層が直後に listFiles() を呼ぶため、キュー上の追記が完了するまで待つ。
        // 書き込み途中のファイルを転送すると末尾が欠けた状態で iPhone に届く
        writeQueue.sync {}
    }

    func listFiles() throws -> [URL] {
        let dir = try continuousDirectory
        guard fileManager.fileExists(atPath: dir.path) else { return [] }
        let sessionDirs = try fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )
        let openChunkPath = currentChunkURL?.path
        return try sessionDirs.flatMap { sessionDir -> [URL] in
            guard sessionDir.hasDirectoryPath else { return [] }
            return try fileManager.contentsOfDirectory(
                at: sessionDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            ).filter { $0.pathExtension == "csv" && $0.path != openChunkPath }
        }.sorted { $0.path < $1.path }
    }

    func deleteFile(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
        let dir = url.deletingLastPathComponent()
        if let remaining = try? fileManager.contentsOfDirectory(atPath: dir.path), remaining.isEmpty {
            try? fileManager.removeItem(at: dir)
        }
    }

    // MARK: - Chunk Lifecycle

    private func openChunk(firstBatch: [MotionSample], receivedAt: Date) {
        guard let sessionId, let anchorSample = firstBatch.last else { return }
        let url = (try? continuousDirectory)?
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent(String(format: "%04d.csv", chunkIndex))
        guard let url else { return }

        currentChunkURL = url
        samplesInCurrentChunk = 0

        let header = Self.buildHeader(
            sessionId: sessionId,
            chunkIndex: chunkIndex,
            anchorSensorMs: anchorSample.timestampMs,
            anchorWallClock: receivedAt
        )
        writeQueue.async {
            Self.appendText(header, to: url)
        }
        AppLog.motion.info("continuous chunk opened: \(url.lastPathComponent, privacy: .public)")
    }

    private func closeChunk() {
        guard let url = currentChunkURL else { return }
        flush()
        currentChunkURL = nil
        chunkIndex += 1
        AppLog.motion.info(
            "continuous chunk closed: \(url.lastPathComponent, privacy: .public) (\(self.samplesInCurrentChunk, privacy: .public) samples)"
        )
        samplesInCurrentChunk = 0
    }

    /// バッファをディスクへ追記する
    ///
    /// CSV 行の整形もキュー側で行う。200Hz の `String(format:)` を呼び出し元
    /// （MainActor）で回すと UI 更新と競合するため。
    private func flush() {
        guard let url = currentChunkURL, !buffer.isEmpty else { return }
        let samples = buffer
        buffer = []
        writeQueue.async {
            Self.appendText(Self.buildRows(from: samples), to: url)
        }
    }

    // MARK: - Private

    private var continuousDirectory: URL {
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

    // MARK: - CSV Builder

    static func buildHeader(
        sessionId: String,
        chunkIndex: Int,
        anchorSensorMs: Int64,
        anchorWallClock: Date
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines: [String] = []
        lines.append("# SessionID: \(sessionId)")
        lines.append("# ChunkIndex: \(chunkIndex)")
        lines.append("# AnchorSensorMs: \(anchorSensorMs)")
        lines.append("# AnchorWallClock: \(formatter.string(from: anchorWallClock))")
        lines.append(Self.csvHeader)
        return lines.joined(separator: "\n") + "\n"
    }

    static func buildRows(from samples: [MotionSample]) -> String {
        var lines: [String] = []
        lines.reserveCapacity(samples.count)
        for sample in samples {
            lines.append(String(
                format: "%lld,%.6f,%.6f,%.6f,%.4f,%.4f,%.4f",
                sample.timestampMs,
                sample.accX, sample.accY, sample.accZ,
                sample.gyroX, sample.gyroY, sample.gyroZ
            ))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - File I/O

    /// ファイル末尾へ追記する（`writeQueue` 上でのみ呼ぶ）
    ///
    /// Why not FileHandle を開いたまま保持する: ハンドルをキューの外へ持ち出さずに済み、
    /// 1秒ごとに閉じるため異常終了時もそこまでの記録がディスクに残る。
    /// 開閉のコストは毎秒1回であり 200Hz の書き込み量に対して無視できる。
    nonisolated private static func appendText(_ text: String, to url: URL) {
        let data = Data(text.utf8)
        let fm = FileManager.default
        do {
            guard fm.fileExists(atPath: url.path) else {
                try fm.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try data.write(to: url)
                return
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            AppLog.motion.error(
                "continuous append failed \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
