//
//  VideoStore.swift
//  TennisAnalyser (iOS)
//
//  Infrastructure — 練習動画の永続保管・スイング単位クリップ生成（F-I6）
//
//  Why not 壁時計マッチングをクリップにも使う: v1 はスイング詳細画面の表示のたびに
//  「継続録画のどれに該当するか」を壁時計時刻で検索していたが、Watch の sessionId が
//  iPhone にも伝わるようになった（V-T6）ため、クリップは `{sessionId}/{sequence}.mov` に
//  固定パスで保存する。CSV（Documents/swings/{sessionId}/{sequence}.csv）と対称的なレイアウトにより、
//  検索ロジック自体が不要になった。

import Foundation
import AVFoundation
import Combine
import os

/// 練習動画の保管庫
///
/// - **セッション録画（一次データ）**: `Documents/video_sources/{sessionId}/manifest.json` + `{index}.mov`
///   （Watch の sessionId をそのまま識別子に使う）
/// - **スイング単位クリップ（派生データ）**: `Documents/videos/{sessionId}/{sequence}.mov`
///
/// Why not クリップを一次データ扱いする: セグメントさえ残っていればクリップは
/// 何度でも再生成できる。2026-07-21 はクリップ生成に失敗した時点で素材ごと
/// 失われたため原因を追えなかった（F-I7-4）。
@MainActor
final class VideoStore: ObservableObject {

    /// 生成済みクリップの識別子集合（"{sessionId}_{sequence}"）。
    /// SwiftUI に変更を伝えるための Published プロパティ（ディスクの実体は都度確認しない）
    @Published private(set) var availableClipKeys: Set<String> = []

    /// セッション録画の一覧
    private(set) var sessions: [RecordingSession] = []

    private let fileManager = FileManager.default
    private let diagnostics: DiagnosticsStore

    /// クリップの前後窓（秒）。`VideoSyncPlayerView` の相対時間計算と一致させること。
    static let preRollSeconds = 2.0
    static let postRollSeconds = 2.0

    private static let manifestName = "manifest.json"

    // Why not `.iso8601`: 小数秒を捨てるため、`RecordingSegment.startedAt` が
    // 秒に丸まる。動画の再生位置は `再生時刻 - startedAt` で決まるので、
    // そのセグメント全体が最大1秒ずれる（F-I9-9）。
    // セッション中は sessions（メモリ上）が完全精度を保つため、
    // ずれが表面化するのは manifest を読み直したあと＝アノテーション時である。
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = ISO8601DateCoding.encodingStrategy
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = ISO8601DateCoding.decodingStrategy
        return decoder
    }()

    init(diagnostics: DiagnosticsStore) {
        self.diagnostics = diagnostics
    }

    private var sourcesDirectory: URL {
        get throws { try makeDirectory("video_sources") }
    }

    private var clipsDirectory: URL {
        get throws { try makeDirectory("videos") }
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let docs = try fileManager.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let dir = docs.appendingPathComponent(name, isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: - Public API (source recordings)

    /// ディスクを再スキャンして継続録画一覧・クリップ一覧を更新する
    func reload() {
        reloadSources()
        reloadClipKeys()
    }

    private func reloadSources() {
        do {
            let dir = try sourcesDirectory
            let entries = try fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            )
            sessions = entries
                .filter { $0.hasDirectoryPath }
                .compactMap { loadManifest(at: $0.appendingPathComponent(Self.manifestName)) }
        } catch {
            AppLog.clip.error("reloadSources failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadManifest(at url: URL) -> RecordingSession? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(RecordingSession.self, from: data)
    }

    /// 旧レイアウト（`{sessionId}.mov` + `.json`）の残骸を削除する
    ///
    /// Why not 移行処理: 2026-07-21 時点で `video_sources/` は空であり、
    /// 移行すべき実データが存在しない。書いても検証できない処理は持たない。
    func removeLegacyLayout() {
        guard let dir = try? sourcesDirectory,
              let entries = try? fileManager.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
              )
        else { return }
        for entry in entries where !entry.hasDirectoryPath {
            try? fileManager.removeItem(at: entry)
            AppLog.clip.info("removed legacy source: \(entry.lastPathComponent, privacy: .public)")
        }
    }

    private func reloadClipKeys() {
        guard let dir = try? clipsDirectory else { return }
        guard let sessionDirs = try? fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return }
        var keys = Set<String>()
        for sessionDir in sessionDirs where sessionDir.hasDirectoryPath {
            let sessionId = sessionDir.lastPathComponent
            let clips = (try? fileManager.contentsOfDirectory(
                at: sessionDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            )) ?? []
            for clip in clips where clip.pathExtension == "mov" {
                let sequence = clip.deletingPathExtension().lastPathComponent
                keys.insert("\(sessionId)_\(sequence)")
            }
        }
        availableClipKeys = keys
    }

    /// セッションのディレクトリ（無ければ作る）
    private func sessionDirectory(_ sessionId: String) throws -> URL {
        let dir = try sourcesDirectory.appendingPathComponent(sessionId, isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 次に録画するセグメントの番号
    func nextSegmentIndex(sessionId: String) -> Int {
        sessions.first(where: { $0.id == sessionId })?.nextSegmentIndex ?? 0
    }

    /// 新しいセグメントの保存先 URL を発行する（録画開始要求時に呼ぶ）
    ///
    /// この時点では manifest へ登録しない。実際に録画が始まらないことがあるため、
    /// 登録は `registerSegmentStart` で行う。
    func newSegmentURL(sessionId: String, index: Int) throws -> URL {
        try sessionDirectory(sessionId).appendingPathComponent(RecordingSegment.fileName(for: index))
    }

    /// 既存セグメントのファイル URL（実体が無ければ nil）
    ///
    /// `newSegmentURL` と分けているのは、こちらがディレクトリを作らない読み取り専用の
    /// 問い合わせであるため（連続タイムラインの再生に用いる。W6-T16b）。
    func existingSegmentURL(sessionId: String, segment: RecordingSegment) -> URL? {
        guard let dir = try? sourcesDirectory.appendingPathComponent(sessionId, isDirectory: true)
        else { return nil }
        let url = dir.appendingPathComponent(segment.fileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// セッションの開始を記録する（未登録なら manifest を作る）
    func registerSessionStart(sessionId: String, startedAt: Date) {
        guard !sessions.contains(where: { $0.id == sessionId }) else { return }
        save(RecordingSession(id: sessionId, startedAt: startedAt))
    }

    /// セグメントの録画開始を manifest へ記録する
    func registerSegmentStart(sessionId: String, index: Int, startedAt: Date) {
        mutate(sessionId: sessionId, fallbackStartedAt: startedAt) { session in
            guard !session.segments.contains(where: { $0.index == index }) else { return }
            session.segments.append(RecordingSegment(
                index: index,
                fileName: RecordingSegment.fileName(for: index),
                startedAt: startedAt
            ))
        }
    }

    /// セグメントの終了時刻が確定したときに呼ばれる（F-I9-8）
    ///
    /// スイングは自分が写っているセグメントの録画中に届くため、到着時のクリップ生成は
    /// 必ず `outOfRecordedRange` になる。生成できるのはセグメントが閉じた後だけであり、
    /// その契機をここで通知する。
    var onSegmentClosed: ((_ sessionId: String) -> Void)?

    /// セグメントの録画終了を manifest へ記録する
    func registerSegmentEnd(sessionId: String, index: Int, endedAt: Date, reason: SegmentEndReason) {
        mutate(sessionId: sessionId, fallbackStartedAt: endedAt) { session in
            guard let i = session.segments.firstIndex(where: { $0.index == index }) else { return }
            session.segments[i].endedAt = endedAt
            session.segments[i].endReason = reason
        }
        onSegmentClosed?(sessionId)
    }

    /// セッションの終了を manifest へ記録する
    func registerSessionEnd(sessionId: String, endedAt: Date) {
        mutate(sessionId: sessionId, fallbackStartedAt: endedAt) { $0.endedAt = endedAt }
    }

    /// セッション録画を削除する（ユーザー操作のみ。自動削除はしない。F-I7-4）
    func deleteSession(sessionId: String) {
        guard let dir = try? sourcesDirectory.appendingPathComponent(sessionId, isDirectory: true) else { return }
        try? fileManager.removeItem(at: dir)
        AppLog.clip.info("deleted session recording: \(sessionId, privacy: .public)")
        reloadSources()
    }

    private func mutate(
        sessionId: String,
        fallbackStartedAt: Date,
        _ body: (inout RecordingSession) -> Void
    ) {
        var session = sessions.first(where: { $0.id == sessionId })
            ?? RecordingSession(id: sessionId, startedAt: fallbackStartedAt)
        body(&session)
        save(session)
    }

    /// manifest を書き出して一覧へ反映する
    ///
    /// Why not まとめて保存: 中断やクラッシュでセグメントの記録が失われると、
    /// その区間の映像が manifest から辿れなくなり、実体があるのに使えないファイルが残る。
    /// 変更のたびに書き出す（1セッションあたり数十回程度で、量的な問題は無い）。
    private func save(_ session: RecordingSession) {
        do {
            let url = try sessionDirectory(session.id).appendingPathComponent(Self.manifestName)
            try Self.encoder.encode(session).write(to: url, options: .atomic)
            if let i = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[i] = session
            } else {
                sessions.append(session)
            }
        } catch {
            AppLog.clip.error("manifest save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Public API (per-swing clips)

    /// スイング単位クリップの URL（存在するとは限らない）
    func clipURL(sessionId: String, sequence: Int) throws -> URL {
        try clipsDirectory
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("\(sequence).mov")
    }

    /// クリップが生成済みか
    func hasClip(sessionId: String, sequence: Int) -> Bool {
        availableClipKeys.contains("\(sessionId)_\(sequence)")
    }

    /// スイングに対応するクリップが無ければ、継続録画から切り出して生成する
    ///
    /// - Parameters:
    ///   - sessionId/sequence: スイングの識別子（CSV と同じキー）
    ///   - detectedAt: スイングのインパクト壁時計時刻
    func extractClipIfNeeded(sessionId: String, sequence: Int, detectedAt: Date?) async {
        // Why not 黙って return: 2026-07-21 の実機検証では 325スイング中 1件しか
        // クリップが生成されなかったが、全ての失敗経路が無言だったため原因の切り分けに
        // ファイル配置からの逆算が必要だった。諦める理由を必ず記録する（F-I7-6）。
        let key = "\(sessionId)/\(sequence)"
        guard !hasClip(sessionId: sessionId, sequence: sequence) else { return }
        guard let detectedAt else {
            skip(sessionId: sessionId, sequence: sequence, reason: .detectedAtMissing, detail: "detectedAt missing")
            return
        }
        guard let session = sessions.first(where: { $0.id == sessionId }) else {
            skip(sessionId: sessionId, sequence: sequence, reason: .noSourceRecording,
                 detail: "no source recording for session")
            return
        }
        // 中断区間・録画範囲外・終了時刻未確定のいずれもここで弾かれる。
        // 録画中のセグメントは範囲が定まらないため、確定後の reload で再試行される
        guard let (segment, offset) = session.resolve(detectedAt) else {
            skip(sessionId: sessionId, sequence: sequence, reason: .outOfRecordedRange,
                 detail: "detectedAt not covered by any segment "
                       + "(detectedAt=\(detectedAt) segments=\(session.segments.count))")
            return
        }
        guard let sourceURL = try? sourcesDirectory
                .appendingPathComponent(sessionId, isDirectory: true)
                .appendingPathComponent(segment.fileName),
              fileManager.fileExists(atPath: sourceURL.path)
        else {
            skip(sessionId: sessionId, sequence: sequence, reason: .sourceFileMissing,
                 detail: "segment file missing on disk (\(segment.fileName))")
            return
        }

        let startSeconds = max(0, offset - Self.preRollSeconds)
        let endSeconds = offset + Self.postRollSeconds

        do {
            let destURL = try clipURL(sessionId: sessionId, sequence: sequence)
            let destDir = destURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: destDir.path) {
                try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
            }
            try await exportClip(from: sourceURL, to: destURL, startSeconds: startSeconds, endSeconds: endSeconds)
            reloadClipKeys()
            AppLog.clip.info("extracted \(key, privacy: .public) at offset \(offset, format: .fixed(precision: 2))s")
            diagnostics.record(.clipExtracted(sequence: sequence, at: Date()), for: sessionId)
        } catch {
            skip(sessionId: sessionId, sequence: sequence, reason: .extractionFailed,
                 detail: "extraction failed: \(error.localizedDescription)")
        }
    }

    /// クリップを生成できなかったことをログと診断記録の両方へ残す
    ///
    /// 片方だけに残すと、実機ログが取れない状況（Console.app 未接続）と
    /// App から診断を見られない状況のどちらかで手掛かりを失うため、必ず対で記録する。
    private func skip(sessionId: String, sequence: Int, reason: ClipSkipReason, detail: String) {
        AppLog.clip.error("skip \(sessionId, privacy: .public)/\(sequence, privacy: .public): \(detail, privacy: .public)")
        diagnostics.record(.clipSkipped(sequence: sequence, at: Date(), reason: reason), for: sessionId)
    }

    private func exportClip(from sourceURL: URL, to destURL: URL, startSeconds: Double, endSeconds: Double) async throws {
        if fileManager.fileExists(atPath: destURL.path) {
            try fileManager.removeItem(at: destURL)
        }
        let asset = AVURLAsset(url: sourceURL)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw VideoExportError.exportSessionUnavailable
        }

        // Why not 要求された範囲をそのまま渡す: セグメント末尾から postRoll（2秒）以内に
        // 落ちたスイングは endSeconds が実体の長さを超え、書き出しが失敗していた。
        // 2026-08-09 のセッションでは5件がこれで失われた。切り詰めれば短いクリップにはなるが、
        // インパクト自体は写っているため使える。
        //
        // Why not manifest の duration でクランプする: manifest は壁時計の差であり、
        // 実体の長さとは数百ミリ秒ずれる。境界の判定には実体の長さを使う。
        let assetSeconds = try await asset.load(.duration).seconds
        guard assetSeconds.isFinite, assetSeconds > 0 else {
            throw VideoExportError.emptyTimeRange
        }
        let start = max(0, min(startSeconds, assetSeconds))
        let end = min(endSeconds, assetSeconds)
        guard end > start else { throw VideoExportError.emptyTimeRange }

        export.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
        // Why not プリセットのみ: プリセット指定の再エンコードは元動画の向きメタデータ
        // （preferredTransform）を落とすため、横向き録画でもクリップが縦向きになる。
        // videoComposition(withPropertiesOf:) は元動画の向き・サイズを反映した合成を作り、
        // 向きをピクセルに焼き込んで出力するため、再生側の解釈に依存せず正しい向きになる。
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        if !videoTracks.isEmpty {
            export.videoComposition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        }
        try await export.export(to: destURL, as: .mov)
    }
}

enum VideoExportError: LocalizedError {
    case exportSessionUnavailable
    case exportFailed
    /// 切り詰めた結果が空になった（セグメントの実体が無い・長さがゼロ等）
    case emptyTimeRange

    var errorDescription: String? {
        switch self {
        case .exportSessionUnavailable: return "動画の書き出しを準備できませんでした。"
        case .exportFailed: return "動画の書き出しに失敗しました。"
        case .emptyTimeRange: return "切り出す範囲が録画に含まれていません。"
        }
    }
}
