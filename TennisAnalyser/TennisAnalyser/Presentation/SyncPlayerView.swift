//
//  SyncPlayerView.swift
//  TennisAnalyser (iOS)
//
//  Presentation — 動画と波形の同期再生ビュー（F-I8-4 / W6-T16b）
//
//  選別画面（T16c）とタイムライン画面（T16d）が共有する。違いは
//  `SyncPlaybackController` に渡す対象範囲だけであり、このビューは範囲を意識しない。

import SwiftUI
import AVKit

struct SyncPlayerView: View {

    @ObservedObject var controller: SyncPlaybackController
    let bins: [WaveformBin]
    let markers: [WaveformMarker]
    /// 動画の表示高さ
    var videoHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            videoArea
            waveform
            seekBar
            controls
        }
    }

    // MARK: - 動画

    private var videoArea: some View {
        ZStack {
            VideoPlayer(player: controller.avPlayer)
                .frame(height: videoHeight)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            // 中断区間では「打っていない」のか「動画が無い」のかを判別できる必要がある
            if !controller.isCovered {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.black.opacity(0.6))
                    .frame(height: videoHeight)
                    .overlay {
                        VStack(spacing: 4) {
                            Image(systemName: "video.slash")
                            Text("この区間の動画はありません")
                                .font(.caption)
                        }
                        .foregroundStyle(.white)
                    }
            }
        }
    }

    // MARK: - 波形

    private var waveform: some View {
        ContinuousWaveformView(
            bins: bins,
            range: controller.timeline.range,
            gaps: controller.timeline.gaps,
            markers: markers,
            currentDate: controller.currentDate,
            onScrub: { date in
                controller.pause()
                controller.seek(to: date)
            }
        )
    }

    // MARK: - シークバー

    private var seekBar: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { controller.timeline.progress(of: controller.currentDate) },
                    set: { controller.seek(toProgress: $0) }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    if editing { controller.pause() }
                }
            )
            HStack {
                Text(controller.currentDate.ymdhmsString)
                Spacer()
                Text(String(format: "%.1f秒", controller.timeline.duration))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    // MARK: - 操作

    private var controls: some View {
        HStack(spacing: 16) {
            Button {
                controller.togglePlayPause()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
            }

            // コマ送り（F-I8-6 の位置確認用）
            Button { controller.nudge(bySeconds: -0.005) } label: {
                Image(systemName: "backward.frame")
            }
            Button { controller.nudge(bySeconds: 0.005) } label: {
                Image(systemName: "forward.frame")
            }

            Spacer()

            Picker("再生速度", selection: $controller.rate) {
                ForEach(SyncPlaybackController.availableRates, id: \.self) { rate in
                    Text(rate == 1.0 ? "等速" : "\(rate.formatted())倍").tag(rate)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)
            .onChange(of: controller.rate) { _, _ in
                if controller.isPlaying { controller.play() }
            }
        }
        .font(.body)
    }
}
