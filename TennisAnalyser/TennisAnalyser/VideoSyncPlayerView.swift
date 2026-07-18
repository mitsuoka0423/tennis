//
//  VideoSyncPlayerView.swift
//  TennisAnalyser
//
//  Presentation — スイングに対応する動画をシークして表示する（F-I6 本体）

import SwiftUI
import AVKit

/// 該当スイング付近（インパクトの前後）を切り出して再生するプレイヤー
///
/// Why not 正確なウィンドウ幅: スイングの pre/post 秒数は Watch 側で調整可能（F-W3）だが、
/// この動画同期は「目視でショットを確認する」用途のため、デフォルト値（前後2秒）を
/// 固定で使う近似で十分と判断した。ズレても目視確認には支障がない。
struct VideoSyncPlayerView: View {

    let video: PracticeVideo
    /// スイング（インパクト）に対応する動画内の再生位置（秒）
    let impactOffsetSeconds: Double

    @EnvironmentObject private var videoStore: VideoStore
    @State private var player: AVPlayer?
    @State private var rate: Float = 0.5
    @State private var isPlaying = false
    @State private var boundaryObserver: Any?

    private static let preRollSeconds = 2.0
    private static let postRollSeconds = 2.0
    private static let availableRates: [Float] = [0.25, 0.5, 1.0]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("動画")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let player {
                VideoPlayer(player: player)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onDisappear { teardown(player: player) }

                controls
            } else {
                ProgressView()
                    .frame(height: 220)
                    .frame(maxWidth: .infinity)
            }
        }
        .task { await setUpPlayer() }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack {
            Button {
                togglePlayPause()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            }

            Spacer()

            Picker("再生速度", selection: $rate) {
                ForEach(Self.availableRates, id: \.self) { r in
                    Text(r == 1.0 ? "等速" : "\(r.formatted())倍").tag(r)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            .onChange(of: rate) { _, newRate in
                if isPlaying { player?.rate = newRate }
            }
        }
        .font(.body)
    }

    // MARK: - Setup

    private func setUpPlayer() async {
        guard let fileURL = try? videoStore.fileURL(for: video) else { return }
        let item = AVPlayerItem(url: fileURL)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.isMuted = true  // 音声トラックは録音していないが念のため

        let startSeconds = max(0, impactOffsetSeconds - Self.preRollSeconds)
        let endSeconds = impactOffsetSeconds + Self.postRollSeconds
        let startTime = CMTime(seconds: startSeconds, preferredTimescale: 600)
        let endTime = CMTime(seconds: endSeconds, preferredTimescale: 600)

        await newPlayer.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)

        // インパクト前後の短い区間だけをループ再生する（目視確認しやすいように）
        let observer = newPlayer.addBoundaryTimeObserver(
            forTimes: [NSValue(time: endTime)], queue: .main
        ) {
            newPlayer.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
            newPlayer.rate = rate
        }
        boundaryObserver = observer

        player = newPlayer
        newPlayer.rate = rate
        isPlaying = true
    }

    private func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.rate = 0
        } else {
            player.rate = rate
        }
        isPlaying.toggle()
    }

    private func teardown(player: AVPlayer) {
        if let boundaryObserver {
            player.removeTimeObserver(boundaryObserver)
        }
        player.pause()
    }
}
