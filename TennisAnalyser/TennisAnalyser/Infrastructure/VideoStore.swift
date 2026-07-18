//
//  VideoStore.swift
//  TennisAnalyser (iOS)
//
//  Infrastructure — 練習動画の永続保管と時刻マッチング（F-I6）

import Foundation
import Combine

/// 練習動画の保管庫
///
/// - 保存先: `Documents/videos/{uuid}.mov` + サイドカー `Documents/videos/{uuid}.json`
///   （メタデータを動画本体と分離。動画は AVCaptureMovieFileOutput が直接書き出すため、
///   メタデータだけを別ファイルにする方が録画コードをシンプルに保てる）
@MainActor
final class VideoStore: ObservableObject {

    @Published private(set) var videos: [PracticeVideo] = []

    private let fileManager = FileManager.default

    private var videosDirectory: URL {
        get throws {
            let docs = try fileManager.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            let dir = docs.appendingPathComponent("videos", isDirectory: true)
            if !fileManager.fileExists(atPath: dir.path) {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            return dir
        }
    }

    // MARK: - Public API

    /// ディスクを再スキャンして一覧を更新する
    func reload() {
        do {
            let dir = try videosDirectory
            let files = try fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            videos = files
                .filter { $0.pathExtension == "json" }
                .compactMap { url -> PracticeVideo? in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return try? decoder.decode(PracticeVideo.self, from: data)
                }
                .sorted { $0.startedAt > $1.startedAt }
        } catch {
            print("[VideoStore] reload error: \(error)")
        }
    }

    /// 新しい録画の保存先ファイル URL を発行する（録画開始時に呼ぶ）
    func newRecordingURL() throws -> (id: String, url: URL) {
        let id = UUID().uuidString
        let url = try videosDirectory.appendingPathComponent("\(id).mov")
        return (id, url)
    }

    /// 録画完了時にメタデータを保存する
    func saveMetadata(_ video: PracticeVideo) {
        do {
            let dir = try videosDirectory
            let url = dir.appendingPathComponent("\(video.id).json")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(video)
            try data.write(to: url, options: .atomic)
            reload()
        } catch {
            print("[VideoStore] saveMetadata error: \(error)")
        }
    }

    /// `date` を録画範囲に含む動画を探す（F-I6: スイングに対応する動画の検索）
    func video(containing date: Date) -> PracticeVideo? {
        videos.first { $0.contains(date) }
    }

    /// 動画ファイルの絶対 URL を返す
    func fileURL(for video: PracticeVideo) throws -> URL {
        try videosDirectory.appendingPathComponent(video.fileName)
    }

    /// 動画を削除する
    func delete(_ video: PracticeVideo) {
        do {
            let dir = try videosDirectory
            try? fileManager.removeItem(at: dir.appendingPathComponent(video.fileName))
            try? fileManager.removeItem(at: dir.appendingPathComponent("\(video.id).json"))
            reload()
        } catch {
            print("[VideoStore] delete error: \(error)")
        }
    }
}
