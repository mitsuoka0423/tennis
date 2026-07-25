//
//  AnnotationTimelineView.swift
//  TennisAnalyser (iOS)
//
//  Presentation — セッション全体の俯瞰と補完（F-I8-5/6/7 / W6-T16d）
//
//  選別画面（T16c）と同じ `SyncPlaybackController` / `SyncPlayerView` を使い、
//  渡すタイムラインの範囲だけが異なる。

import SwiftUI

struct AnnotationTimelineView: View {

    let session: RecordingSession

    @EnvironmentObject private var annotations: AnnotationStore
    @EnvironmentObject private var continuousStore: ContinuousSensorStore
    @EnvironmentObject private var videoStore: VideoStore

    @State private var controller: SyncPlaybackController?
    @State private var bins: [WaveformBin] = []
    @State private var zoom: Zoom = .whole
    @State private var isLoading = false

    /// 表示倍率。波形は表示範囲に対して間引くため、狭めるほど細かく見える
    private enum Zoom: String, CaseIterable, Identifiable {
        case whole = "全体"
        case fiveMinutes = "5分"
        case oneMinute = "1分"
        case tenSeconds = "10秒"

        var id: String { rawValue }

        /// nil ならセッション全体
        var seconds: TimeInterval? {
            switch self {
            case .whole: return nil
            case .fiveMinutes: return 300
            case .oneMinute: return 60
            case .tenSeconds: return 10
            }
        }
    }

    /// 波形の描画本数
    private static let binCount = 300

    private var annotation: SessionAnnotation { annotations.annotation(for: session.id) }

    /// 再生位置に最も近いイベント（微調整・削除の対象）
    private var nearestEvent: AnnotatedEvent? {
        guard let currentDate = controller?.currentDate else { return nil }
        return annotation.events.min {
            abs($0.impactAt.timeIntervalSince(currentDate))
                < abs($1.impactAt.timeIntervalSince(currentDate))
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                zoomPicker

                if let controller {
                    SyncPlayerView(controller: controller, bins: bins, markers: markers)
                        .overlay(alignment: .topTrailing) {
                            if isLoading { ProgressView().padding(8) }
                        }
                    coverageSummary
                    eventEditor
                    timeOffsetEditor
                }
            }
            .padding()
        }
        .navigationTitle("タイムライン")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("取り消し", systemImage: "arrow.uturn.backward") {
                    annotations.undo(sessionId: session.id)
                }
                .disabled(!annotations.canUndo(sessionId: session.id))
            }
        }
        .task { await prepare() }
        .onChange(of: zoom) { _, _ in retarget(centeredOn: controller?.currentDate) }
    }

    // MARK: - 表示倍率（F-I8-5）

    private var zoomPicker: some View {
        Picker("表示範囲", selection: $zoom) {
            ForEach(Zoom.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - 欠落の要約（F-I8-4）

    private var coverageSummary: some View {
        let gaps = controller?.timeline.gaps ?? []
        let missing = gaps.reduce(0) { $0 + $1.duration }
        return HStack {
            Label(
                gaps.isEmpty ? "動画の欠落なし" : String(format: "動画の欠落 %.0f秒（%d区間）", missing, gaps.count),
                systemImage: gaps.isEmpty ? "checkmark.circle" : "exclamationmark.triangle"
            )
            .foregroundStyle(gaps.isEmpty ? .green : .orange)
            Spacer()
            Text("候補 \(annotation.events.count)")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    // MARK: - 見落としの補完と位置調整（F-I8-5/6）

    private var eventEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("イベント")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                Button("再生位置に追加", systemImage: "plus.circle") {
                    guard let date = controller?.currentDate else { return }
                    annotations.addManualEvent(sessionId: session.id, impactAt: date)
                }
                Spacer()
                if let nearestEvent {
                    Text(String(
                        format: "最寄り %+.3f秒",
                        nearestEvent.impactAt.timeIntervalSince(controller?.currentDate ?? Date())
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
            }

            if let nearestEvent {
                HStack(spacing: 12) {
                    // 粒度はセンサーのサンプル間隔（5ms）。動画フレーム（33ms）より細かい
                    Button("-5ms") { adjust(nearestEvent, by: -0.005) }
                    Button("+5ms") { adjust(nearestEvent, by: 0.005) }
                    Button("再生位置へ") { snapToPlayhead(nearestEvent) }
                    Spacer()
                    Button("削除", systemImage: "trash", role: .destructive) {
                        annotations.remove(sessionId: session.id, eventId: nearestEvent.id)
                    }
                }
                .font(.subheadline)
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - 時刻の全体補正（F-I8-7）

    private var timeOffsetEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("時刻オフセット")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%+.2f秒", annotation.timeOffsetSeconds))
                    .monospacedDigit()
            }
            // 補正は保持値であり、各イベントの impactAt は書き換えない（何度でも試せる）
            Slider(
                value: Binding(
                    get: { annotation.timeOffsetSeconds },
                    set: { annotations.setTimeOffset(sessionId: session.id, seconds: $0) }
                ),
                in: -2...2,
                step: 0.05
            )
        }
    }

    // MARK: - 操作

    private func adjust(_ event: AnnotatedEvent, by seconds: Double) {
        annotations.adjustImpact(sessionId: session.id, eventId: event.id, bySeconds: seconds)
    }

    private func snapToPlayhead(_ event: AnnotatedEvent) {
        guard let date = controller?.currentDate else { return }
        annotations.adjustImpact(
            sessionId: session.id,
            eventId: event.id,
            bySeconds: date.timeIntervalSince(event.impactAt)
        )
    }

    // MARK: - 準備と同期

    private func prepare() async {
        controller = SyncPlaybackController(
            timeline: timeline(centeredOn: nil),
            segmentURL: { [videoStore] segment in
                videoStore.existingSegmentURL(sessionId: session.id, segment: segment)
            }
        )
        loadBins()
    }

    private func retarget(centeredOn date: Date?) {
        guard let controller else { return }
        controller.pause()
        let timeline = timeline(centeredOn: date)
        controller.retarget(to: timeline, startingAt: date ?? timeline.range.start)
        loadBins()
    }

    /// 表示倍率に応じた範囲を作る
    ///
    /// 倍率を狭めたときは再生位置を中心に置く。位置を保ったまま拡大できないと、
    /// 見つけたピークを拡大して確かめる操作が成立しない。
    private func timeline(centeredOn date: Date?) -> ContinuousTimeline {
        let whole = ContinuousTimeline(session: session)
        guard let width = zoom.seconds, whole.duration > width else { return whole }
        let center = date ?? whole.range.start.addingTimeInterval(width / 2)
        var start = center.addingTimeInterval(-width / 2)
        start = max(start, whole.range.start)
        start = min(start, whole.range.end.addingTimeInterval(-width))
        return ContinuousTimeline(
            session: session,
            range: DateInterval(start: start, duration: width)
        )
    }

    private func loadBins() {
        guard let range = controller?.timeline.range else { return }
        let chunks = continuousStore.chunks(for: session.id)
        isLoading = true
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                WaveformLoader.loadBins(chunks: chunks, range: range, binCount: Self.binCount)
            }.value
            guard controller?.timeline.range == range else { return }
            bins = loaded
            isLoading = false
        }
    }

    private var markers: [WaveformMarker] {
        guard let range = controller?.timeline.range else { return [] }
        return annotation.events
            .filter { $0.impactAt >= range.start && $0.impactAt <= range.end }
            .map {
                WaveformMarker(
                    id: $0.id, date: $0.impactAt, status: $0.status, origin: $0.origin
                )
            }
    }
}
