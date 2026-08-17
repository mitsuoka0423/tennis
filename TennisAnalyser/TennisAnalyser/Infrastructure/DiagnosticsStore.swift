//
//  DiagnosticsStore.swift
//  TennisAnalyser (iOS)
//
//  Infrastructure — セッション診断記録の永続化（F-I7-5）
//
//  Why not JSON配列を毎回書き直す: 配列を保つには読み込み→追加→全体書き戻しが必要で、
//  書き戻しの最中にアプリが落ちるとそれまでの記録ごと失われる。診断記録が最も必要なのは
//  まさにアプリが正常に終われなかった場合であり、その状況で失われる方式は採れない。
//  1行1イベントの JSON Lines なら追記のみで済み、途中で落ちても直前までの行は残る。
//
//  Why not 記録失敗を呼び出し側へ伝播: 診断はアプリの主機能ではない。記録に失敗しても
//  録画やクリップ生成を止めるべきではないため、ログに残して握りつぶす。

import Foundation
import os

/// セッション診断記録の保管庫
///
/// - 保存先: `Documents/diagnostics/{sessionId}.jsonl`（1行1イベント）
/// - 書き込みは追記のみ。集計は読み出し時に `SessionDiagnostics.make` で導出する
@MainActor
final class DiagnosticsStore {

    private let fileManager = FileManager.default

    // 出来事の前後関係はミリ秒で効く（中断から復帰までが数百ミリ秒のことがある）。
    // `.iso8601` は小数秒を捨てるため、記録が全て `.000` になっていた（F-I9-9）
    private lazy var encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = ISO8601DateCoding.encodingStrategy
        return encoder
    }()

    private lazy var decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = ISO8601DateCoding.decodingStrategy
        return decoder
    }()

    private func directory() throws -> URL {
        let docs = try fileManager.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let dir = docs.appendingPathComponent("diagnostics", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func fileURL(for sessionId: String) throws -> URL {
        try directory().appendingPathComponent("\(sessionId).jsonl")
    }

    // MARK: - Public API

    /// 出来事を1件追記する
    func record(_ event: DiagnosticEvent, for sessionId: String) {
        do {
            let url = try fileURL(for: sessionId)
            var line = try encoder.encode(event)
            line.append(0x0A)  // '\n'

            if fileManager.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url, options: .atomic)
            }
        } catch {
            AppLog.session.error(
                "diagnostics record failed for \(sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// セッションの出来事を発生順に読み出す
    ///
    /// 壊れた行（書き込み途中でアプリが落ちた場合の最終行など）は読み飛ばす。
    /// 1行でも壊れていたら全体を諦める方式では、診断記録が最も必要な場面で何も読めなくなる。
    func events(for sessionId: String) -> [DiagnosticEvent] {
        guard let url = try? fileURL(for: sessionId),
              let content = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }

        return content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(DiagnosticEvent.self, from: data)
            }
    }

    /// セッションの診断結果を導出する
    func diagnostics(for sessionId: String) -> SessionDiagnostics {
        SessionDiagnostics.make(sessionId: sessionId, from: events(for: sessionId))
    }

    /// 記録が存在するセッションID（新しい順）
    func recordedSessionIds() -> [String] {
        guard let dir = try? directory(),
              let urls = try? fileManager.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles
              )
        else { return [] }

        return urls
            .filter { $0.pathExtension == "jsonl" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            }
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    /// セッションの記録を削除する（ユーザー操作）
    func delete(sessionId: String) {
        guard let url = try? fileURL(for: sessionId) else { return }
        try? fileManager.removeItem(at: url)
    }
}
