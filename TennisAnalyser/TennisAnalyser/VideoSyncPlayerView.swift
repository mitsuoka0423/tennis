//
//  VideoSyncPlayerView.swift
//  TennisAnalyser
//
//  Presentation — スイング単位クリップの再生（F-I6 本体、I-3 シークバー・I-4 グラフ同期）
//
//  Why not 壁時計シーク: v1 は継続録画から都度シークしていたが、クリップ自体が
//  既にインパクト前後の窓（VideoStore.preRoll/postRollSeconds）で切り出し済みのため、
//  クリップの先頭（0秒）＝ウィンドウ開始として単純に頭から再生すればよい。

import SwiftUI
import AVKit

struct VideoSyncPlayerView: View {

    let sessionId: String
    let sequence: Int
    /// 再生位置をインパクトからの相対秒として親（波形グラフ）へ公開する（I-4）
    @Binding var relativeTimeSec: Double?

    @EnvironmentObject private var videoStore: VideoStore
    @State private var player: AVPlayer?
    @State private var rate: Float = 0.5
    @State private var isPlaying = false
    @State private var duration: Double = 0
    @State private var currentTime: Double = 0
    @State private var isScrubbing = false
    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?
    @State private var loadError = false

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

                seekBar
                controls
            } else if loadError {
                EmptyView()  // クリップ未生成: SwingDetailView 側で「動画がありません」を表示
            } else {
                ProgressView()
                    .frame(height: 220)
                    .frame(maxWidth: .infinity)
            }
        }
        .task { await setUpPlayer() }
    }

    // MARK: - Seek Bar (I-3)

    private var seekBar: some View {
        VStack(spacing: 2) {
            Slider(
                value: $currentTime,
                in: 0...max(duration, 0.01),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if editing {
                        player?.rate = 0
                    } else {
                        seek(to: currentTime)
                        if isPlaying { player?.rate = rate }
                    }
                }
            )
            HStack {
                Text(timeString(currentTime))
                Spacer()
                Text(timeString(duration))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    private func timeString(_ seconds: Double) -> String {
        String(format: "%.2fs", seconds)
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
        guard let fileURL = try? videoStore.clipURL(sessionId: sessionId, sequence: sequence),
              FileManager.default.fileExists(atPath: fileURL.path)
        else {
            loadError = true
            return
        }

        let asset = AVURLAsset(url: fileURL)
        let item = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.isMuted = true  // 音声トラックは録音していないが念のため

        duration = (try? await asset.load(.duration).seconds) ?? 0

        // クリップ全体をループ再生する
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { _ in
            newPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            newPlayer.rate = rate
        }

        // I-4: 再生位置を波形グラフ同期用に公開する
        let interval = CMTime(seconds: 0.03, preferredTimescale: 600)
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            guard !isScrubbing else { return }
            let seconds = time.seconds
            currentTime = seconds
            relativeTimeSec = seconds - VideoStore.preRollSeconds
        }

        player = newPlayer
        newPlayer.rate = rate
        isPlaying = true
    }

    private func seek(to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        relativeTimeSec = seconds - VideoStore.preRollSeconds
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
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        player.pause()
        relativeTimeSec = nil
    }
}
