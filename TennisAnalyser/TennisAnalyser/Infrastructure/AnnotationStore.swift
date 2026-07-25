//
//  AnnotationStore.swift
//  TennisAnalyser (iOS)
//
//  Infrastructure — アノテーションの永続化と取り消し（F-I8-8 / W6-T16a）

import Foundation
import Combine
import os

/// アノテーションの保管庫
///
/// - 保存先: Documents/annotations/{sessionId}.json
/// - 操作のたびに永続化する（F-I8-8: 強制終了しても選別結果を失わない）
/// - 直前の操作を取り消せる（F-I8-2）
@MainActor
final class AnnotationStore: ObservableObject {

    /// セッションIDごとのアノテーション
    @Published private(set) var annotations: [String: SessionAnnotation] = [:]

    /// 取り消し用の履歴（操作前の状態）。セッションごとに保持する
    private var history: [String: [SessionAnnotation]] = [:]

    /// 履歴の保持上限。深い巻き戻しは選別のやり直しと変わらないため浅く抑える
    private static let historyLimit = 20

    private let fileManager = FileManager.default

    private var annotationsDirectory: URL {
        get throws {
            let docs = try fileManager.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            return docs.appendingPathComponent("annotations", isDirectory: true)
        }
    }

    // MARK: - 読み込み

    /// ディスク上の全アノテーションを読み込む
    func reload() {
        do {
            let dir = try annotationsDirectory
            guard fileManager.fileExists(atPath: dir.path) else {
                annotations = [:]
                return
            }
            let files = try fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            ).filter { $0.pathExtension == "json" }
            var loaded: [String: SessionAnnotation] = [:]
            for file in files {
                guard let annotation = Self.decode(fileURL: file) else { continue }
                loaded[annotation.sessionId] = annotation
            }
            annotations = loaded
        } catch {
            AppLog.store.error("annotation reload failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// セッションのアノテーションを返す（無ければ空を返す）
    func annotation(for sessionId: String) -> SessionAnnotation {
        annotations[sessionId] ?? SessionAnnotation(sessionId: sessionId)
    }

    // MARK: - 選別（F-I8-2/3）

    func confirm(sessionId: String, eventId: String, shotClass: ShotClass) {
        mutate(sessionId: sessionId) { $0.confirm(id: eventId, shotClass: shotClass) }
    }

    func confirm(sessionId: String, eventIds: [String], shotClass: ShotClass) {
        mutate(sessionId: sessionId) { $0.confirm(ids: eventIds, shotClass: shotClass) }
    }

    func reject(sessionId: String, eventId: String) {
        mutate(sessionId: sessionId) { $0.reject(id: eventId) }
    }

    func unreview(sessionId: String, eventId: String) {
        mutate(sessionId: sessionId) { $0.unreview(id: eventId) }
    }

    // MARK: - 補完と調整（F-I8-5/6/7）

    func addManualEvent(sessionId: String, impactAt: Date) {
        mutate(sessionId: sessionId) { $0.addManualEvent(impactAt: impactAt) }
    }

    func remove(sessionId: String, eventId: String) {
        mutate(sessionId: sessionId) { $0.remove(id: eventId) }
    }

    func adjustImpact(sessionId: String, eventId: String, bySeconds seconds: Double) {
        mutate(sessionId: sessionId) { $0.adjustImpact(id: eventId, bySeconds: seconds) }
    }

    func setTimeOffset(sessionId: String, seconds: Double) {
        mutate(sessionId: sessionId) { $0.setTimeOffset(seconds) }
    }

    // MARK: - 検知結果の取り込み（F-I8-1）

    /// 連続記録に検知器を走らせ、候補を取り込む
    ///
    /// 既存の判断は保持される（`SessionAnnotation.merge`）。パラメータを変えて
    /// 何度でも呼び直せる。
    func detectCandidates(
        sessionId: String,
        chunks: [ContinuousChunk],
        parameters: OfflineDetectorParameters = OfflineDetectorParameters()
    ) async {
        // 1セッションは約68万サンプル。メインスレッドで走らせるとUIが固まる
        let detected = await Task.detached(priority: .userInitiated) {
            OfflineSwingDetector.detect(chunks: chunks, parameters: parameters)
        }.value
        AppLog.store.info(
            "detected \(detected.count, privacy: .public) candidates for \(sessionId, privacy: .public)"
        )
        merge(sessionId: sessionId, detected: detected)
    }

    /// 検知結果を取り込む（既存の判断は保持される）
    func merge(sessionId: String, detected: [DetectedImpact]) {
        mutate(sessionId: sessionId) { $0.merge(detected: detected) }
    }

    // MARK: - 取り消し（F-I8-2）

    func canUndo(sessionId: String) -> Bool {
        !(history[sessionId] ?? []).isEmpty
    }

    func undo(sessionId: String) {
        guard var stack = history[sessionId], let previous = stack.popLast() else { return }
        history[sessionId] = stack
        annotations[sessionId] = previous
        persist(previous)
    }

    // MARK: - 削除（ユーザー操作）

    func deleteAnnotation(sessionId: String) {
        guard let url = try? fileURL(for: sessionId) else { return }
        try? fileManager.removeItem(at: url)
        annotations[sessionId] = nil
        history[sessionId] = nil
    }

    // MARK: - Private

    private func mutate(sessionId: String, _ transform: (inout SessionAnnotation) -> Void) {
        var annotation = annotation(for: sessionId)
        pushHistory(annotation)
        transform(&annotation)
        annotations[sessionId] = annotation
        persist(annotation)
    }

    private func pushHistory(_ annotation: SessionAnnotation) {
        var stack = history[annotation.sessionId] ?? []
        stack.append(annotation)
        if stack.count > Self.historyLimit {
            stack.removeFirst(stack.count - Self.historyLimit)
        }
        history[annotation.sessionId] = stack
    }

    private func fileURL(for sessionId: String) throws -> URL {
        try annotationsDirectory.appendingPathComponent("\(sessionId).json")
    }

    private func persist(_ annotation: SessionAnnotation) {
        do {
            let dir = try annotationsDirectory
            if !fileManager.fileExists(atPath: dir.path) {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let data = try Self.encoder.encode(annotation)
            try data.write(to: try fileURL(for: annotation.sessionId), options: .atomic)
        } catch {
            AppLog.store.error("annotation save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Codec

    /// 日付は小数秒つき ISO8601 で保存する
    ///
    /// 文字列にするのは、数値では中身を目視できず実機から吸い出したファイルで
    /// 事後調査ができないため（2026-07-21 の教訓）。
    /// 小数秒が要るのは `impactAt` を 5ms 粒度で調整するため（F-I8-6）。
    /// 既定の `.iso8601` は秒で切り捨てるため使えない。
    // Foundation の日付フォーマッタは変換処理自体はスレッド安全であり、
    // ここでは生成後に設定を変更しないため共有して差し支えない
    nonisolated(unsafe) static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601Formatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static func decode(fileURL: URL) -> SessionAnnotation? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = iso8601Formatter.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath, debugDescription: "invalid date: \(text)"
                ))
            }
            return date
        }
        return try? decoder.decode(SessionAnnotation.self, from: data)
    }
}
