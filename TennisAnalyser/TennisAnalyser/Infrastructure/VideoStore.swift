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

/// 練習動画の保管庫
///
/// - **継続録画（中間データ）**: `Documents/video_sources/{sessionId}.mov` + `.json`
///   （Watch の sessionId をそのまま識別子に使う）
/// - **スイング単位クリップ（最終データ）**: `Documents/videos/{sessionId}/{sequence}.mov`
@MainActor
final class VideoStore: ObservableObject {

    /// 生成済みクリップの識別子集合（"{sessionId}_{sequence}"）。
    /// SwiftUI に変更を伝えるための Published プロパティ（ディスクの実体は都度確認しない）
    @Published private(set) var availableClipKeys: Set<String> = []

    /// 継続録画（中間データ）の一覧
    private(set) var sources: [PracticeVideo] = []

    private let fileManager = FileManager.default

    /// クリップの前後窓（秒）。`VideoSyncPlayerView` の相対時間計算と一致させること。
    static let preRollSeconds = 2.0
    static let postRollSeconds = 2.0

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
            let files = try fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            sources = files
                .filter { $0.pathExtension == "json" }
                .compactMap { url -> PracticeVideo? in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return try? decoder.decode(PracticeVideo.self, from: data)
                }
        } catch {
            print("[VideoStore] reloadSources error: \(error)")
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

    /// 新しい継続録画の保存先ファイル URL を発行する（録画開始時に呼ぶ）
    func newSourceRecordingURL(sessionId: String) throws -> URL {
        try sourcesDirectory.appendingPathComponent("\(sessionId).mov")
    }

    /// 継続録画の完了時にメタデータを保存する
    func saveSourceMetadata(_ video: PracticeVideo) {
        do {
            let dir = try sourcesDirectory
            let url = dir.appendingPathComponent("\(video.id).json")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(video)
            try data.write(to: url, options: .atomic)
            reloadSources()
        } catch {
            print("[VideoStore] saveSourceMetadata error: \(error)")
        }
    }

    /// 継続録画（中間データ）を削除する（セッション終了から猶予後のクリーンアップ用）
    func deleteSource(sessionId: String) {
        guard let dir = try? sourcesDirectory else { return }
        try? fileManager.removeItem(at: dir.appendingPathComponent("\(sessionId).mov"))
        try? fileManager.removeItem(at: dir.appendingPathComponent("\(sessionId).json"))
        reloadSources()
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
        guard !hasClip(sessionId: sessionId, sequence: sequence) else { return }
        guard let detectedAt else { return }
        guard let source = sources.first(where: { $0.id == sessionId }) else {
            // 継続録画が見つからない（録画していなかった等）。F-I6 は無くても支障ない機能なので黙って諦める
            return
        }
        guard let sourceURL = try? sourcesDirectory.appendingPathComponent("\(source.id).mov"),
              fileManager.fileExists(atPath: sourceURL.path)
        else { return }
        // 録画中（endedAt 未確定）は正しい範囲が定まらないため、確定後の reload で再試行される
        guard let offset = source.offsetSeconds(for: detectedAt) else { return }

        let startSeconds = max(0, offset - Self.preRollSeconds)
        let endSeconds = offset + Self.postRollSeconds

        do {
            let destURL = try clipURL(sessionId: sessionId, sequence: sequence)
            let destDir = destURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: destDir.path) {
                try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
            }
            await Self.logOrientation(label: "source", url: sourceURL)
            try await exportClip(from: sourceURL, to: destURL, startSeconds: startSeconds, endSeconds: endSeconds)
            await Self.logOrientation(label: "clip", url: destURL)
            reloadClipKeys()
            print("[VideoStore] clip extracted: \(sessionId)/\(sequence).mov")
        } catch {
            print("[VideoStore] extractClip error: \(error)")
        }
    }

    private func exportClip(from sourceURL: URL, to destURL: URL, startSeconds: Double, endSeconds: Double) async throws {
        if fileManager.fileExists(atPath: destURL.path) {
            try fileManager.removeItem(at: destURL)
        }
        let asset = AVURLAsset(url: sourceURL)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw VideoExportError.exportSessionUnavailable
        }
        export.timeRange = CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: 600),
            end: CMTime(seconds: endSeconds, preferredTimescale: 600)
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

    /// 診断用: 動画の保存サイズと向き変換をログ出力する（F-I6 向き問題の切り分け）
    static func logOrientation(label: String, url: URL) async {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            print("[Orient] \(label): 動画トラックなし (\(url.lastPathComponent))")
            return
        }
        let size = (try? await track.load(.naturalSize)) ?? .zero
        let t = (try? await track.load(.preferredTransform)) ?? .identity
        let angle = Int((atan2(t.b, t.a) * 180 / .pi).rounded())
        print("[Orient] \(label) \(url.lastPathComponent): naturalSize=\(Int(size.width))x\(Int(size.height)) transform回転=\(angle)° (a:\(t.a) b:\(t.b) c:\(t.c) d:\(t.d))")
    }
}

enum VideoExportError: LocalizedError {
    case exportSessionUnavailable
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .exportSessionUnavailable: return "動画の書き出しを準備できませんでした。"
        case .exportFailed: return "動画の書き出しに失敗しました。"
        }
    }
}
