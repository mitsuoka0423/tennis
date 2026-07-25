//
//  SyncPlaybackController.swift
//  TennisAnalyser (iOS)
//
//  Presentation — 波形と動画の双方向同期（F-I8-4 / W6-T16b）
//
//  Why not 画面ごとに再生制御を持つ: 選別画面とタイムライン画面で同期の挙動が
//  食い違うと、選別画面で確認した位置がタイムライン画面で違って見えることになる。
//  対象範囲だけを引数で受け、制御そのものは1つに保つ。

import Foundation
import AVFoundation
import Combine
import os

/// 連続タイムラインの再生制御
///
/// 位置の基準は**壁時計時刻**の1つだけとする。動画の再生位置も波形のスクラブ位置も
/// この時刻へ変換して扱うため、どちらから操作しても互いに追従する。
@MainActor
final class SyncPlaybackController: ObservableObject {

    // MARK: - Published State

    /// 現在位置（壁時計）
    @Published private(set) var currentDate: Date
    @Published private(set) var isPlaying = false
    /// 現在位置に動画が存在するか（中断区間では false）
    @Published private(set) var isCovered = false
    @Published var rate: Float = 1.0

    /// 再生対象のタイムライン
    private(set) var timeline: ContinuousTimeline

    // MARK: - Configuration

    static let availableRates: [Float] = [0.25, 0.5, 1.0]

    /// 再生位置の通知間隔（秒）。動画1フレーム（30fps ≒ 33ms）より細かくしても
    /// 波形の描画が追いつかないため同程度に留める
    private static let observationInterval: Double = 0.03

    // MARK: - Private

    private let player = AVPlayer()
    /// 再生中のセグメント。境界をまたぐと差し替える
    private var currentSegmentIndex: Int?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    /// セグメントファイルの所在を解決する
    private let segmentURL: (RecordingSegment) -> URL?

    // MARK: - Init

    /// - Parameter segmentURL: セグメントのファイル URL を返すクロージャ（`VideoStore` が提供する）
    init(timeline: ContinuousTimeline, segmentURL: @escaping (RecordingSegment) -> URL?) {
        self.timeline = timeline
        self.segmentURL = segmentURL
        self.currentDate = timeline.range.start
        player.isMuted = true  // 音声トラックは録音していない
        observePlayer()
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    /// 動画プレイヤー（`VideoPlayer` へ渡す）
    var avPlayer: AVPlayer { player }

    // MARK: - Public API

    /// 対象範囲を差し替える（選別画面で次の候補へ送るときに使う）
    func retarget(to timeline: ContinuousTimeline, startingAt date: Date? = nil) {
        self.timeline = timeline
        seek(to: date ?? timeline.range.start)
    }

    /// 壁時計時刻へシークする（波形スクラブ・候補移動の入口）
    ///
    /// 中断区間へのシークも位置としては受け付ける。「動画が無い」ことを
    /// 見せる必要があるため、位置を勝手に動かさない（F-I8-4）。
    func seek(to date: Date) {
        let clamped = min(max(date, timeline.range.start), timeline.range.end)
        currentDate = clamped

        guard let resolved = timeline.resolve(clamped) else {
            isCovered = false
            player.pause()
            return
        }
        isCovered = true
        loadSegmentIfNeeded(resolved.segment)
        player.seek(
            to: CMTime(seconds: resolved.offsetSeconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    /// 進捗（0.0〜1.0）でシークする（シークバー用）
    func seek(toProgress progress: Double) {
        seek(to: timeline.date(atProgress: progress))
    }

    func play() {
        // 中断区間から再生を始めた場合は次に動画がある位置へ送る。
        // そこに留まると再生ボタンが無反応に見える
        if !isCovered, let next = timeline.nextCoveredDate(atOrAfter: currentDate) {
            seek(to: next)
        }
        guard isCovered else { return }
        player.rate = rate
        isPlaying = true
    }

    func pause() {
        player.rate = 0
        isPlaying = false
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// 現在位置を秒単位でずらす（インパクト位置の微調整・コマ送り）
    func nudge(bySeconds seconds: Double) {
        seek(to: currentDate.addingTimeInterval(seconds))
    }

    // MARK: - Private

    /// 必要ならセグメントを差し替える
    ///
    /// `.mov` はセグメントごとに独立したファイルであり、`AVPlayerItem` を
    /// 切り替えないと境界をまたいで再生できない。
    private func loadSegmentIfNeeded(_ segment: RecordingSegment) {
        guard currentSegmentIndex != segment.index else { return }
        guard let url = segmentURL(segment) else {
            AppLog.recording.error(
                "segment file missing: \(segment.fileName, privacy: .public)"
            )
            isCovered = false
            return
        }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        currentSegmentIndex = segment.index
        if isPlaying {
            player.rate = rate
        }
    }

    /// 動画の再生位置を壁時計へ変換して公開する（動画 → 波形の追従）
    private func observePlayer() {
        let interval = CMTime(seconds: Self.observationInterval, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
            [weak self] time in
            MainActor.assumeIsolated {
                self?.handlePlaybackProgress(offsetSeconds: time.seconds)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSegmentEnd()
            }
        }
    }

    private func handlePlaybackProgress(offsetSeconds: Double) {
        guard isPlaying,
              let index = currentSegmentIndex,
              let segment = timeline.session.segments.first(where: { $0.index == index })
        else { return }

        let date = segment.startedAt.addingTimeInterval(offsetSeconds)
        guard date <= timeline.range.end else {
            pause()
            return
        }
        currentDate = date
        isCovered = true
    }

    /// セグメント末尾に達したら次のセグメントへ継ぐ（境界をまたぐ再生）
    private func handleSegmentEnd() {
        guard isPlaying else { return }
        guard let next = timeline.nextCoveredDate(atOrAfter: currentDate.addingTimeInterval(0.001))
        else {
            pause()
            return
        }
        seek(to: next)
        player.rate = rate
    }
}
