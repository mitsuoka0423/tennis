//
//  AnnotationReviewView.swift
//  TennisAnalyser (iOS)
//
//  Presentation — 候補の選別画面（F-I8-1/2/3 / W6-T16c）
//
//  設計目標は「1件あたり5秒以下」（仕様書2章）。1時間の練習で約325件が生成されるため、
//  1件に10秒かかると練習と同じ時間のタグ付けが必要になり運用が破綻する。
//  本画面の判断はすべてこの制約に従属する。

import SwiftUI

struct AnnotationReviewView: View {

    let session: RecordingSession

    @EnvironmentObject private var annotations: AnnotationStore
    @EnvironmentObject private var continuousStore: ContinuousSensorStore
    @EnvironmentObject private var videoStore: VideoStore

    @State private var controller: SyncPlaybackController?
    @State private var currentIndex = 0
    @State private var bins: [WaveformBin] = []
    /// 一括付与の対象件数（F-I8-3）
    @State private var bulkCount = 1
    @State private var isDetecting = false

    /// 候補の前後に取る秒数
    ///
    /// 書き出しの既定窓（前2秒・後2秒。F-I8-9）と揃える。選別時に見た範囲が
    /// そのまま学習データの範囲になるため、判断と結果が食い違わない。
    private static let leadingSeconds: TimeInterval = 2
    private static let trailingSeconds: TimeInterval = 2

    /// 波形の描画本数。iPhone の横幅に対して1本あたり1〜2ポイントに収まる
    private static let binCount = 240

    private var annotation: SessionAnnotation { annotations.annotation(for: session.id) }
    private var events: [AnnotatedEvent] { annotation.events }
    private var currentEvent: AnnotatedEvent? {
        events.indices.contains(currentIndex) ? events[currentIndex] : nil
    }

    var body: some View {
        VStack(spacing: 12) {
            // 進捗は常時表示のためスクロール領域の外に置く（F-I8-1）
            progressHeader
                .padding(.horizontal)
                .padding(.top)

            if isDetecting {
                ProgressView("候補を検出中…")
                    .frame(maxHeight: .infinity)
            } else if let controller, currentEvent != nil {
                // 動画・波形・選別ボタンの合計高さは端末によって画面に収まらない。
                // 実機（iPhone）では却下ボタンと送りの行が下端で見切れていた。
                //
                // Why not 内容を縮めて収める: 波形は見落とし探しに使うため高さを削れず、
                // ボタンはタップ目標の 44pt を下回れない。収める方向では
                // 端末の高さが変わるたびに同じ問題が出る。
                //
                // Why not 候補を送るたびにスクロール位置を先頭へ戻す: 候補ごとの高さは
                // 同じなので、一度合わせた位置はそのまま次の候補でも使える。
                // 毎回戻すと 237件ぶんスクロールし直すことになり、
                // 1件5秒（仕様書2章）に対して割に合わない。
                ScrollView {
                    VStack(spacing: 12) {
                        SyncPlayerView(controller: controller, bins: bins, markers: markers)
                        candidateInfo
                        classificationButtons
                        navigationRow
                    }
                    .padding(.horizontal)
                    .padding(.bottom)
                }
                // 内容が収まるときは弾ませない（スクロールできると誤解させない）
                .scrollBounceBehavior(.basedOnSize)
            } else {
                ContentUnavailableView(
                    "候補がありません",
                    systemImage: "waveform.badge.magnifyingglass",
                    description: Text("センサーの連続記録が転送されていないか、閾値を超えた区間がありません")
                )
                .frame(maxHeight: .infinity)
            }
        }
        .navigationTitle("選別")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("取り消し", systemImage: "arrow.uturn.backward") {
                    annotations.undo(sessionId: session.id)
                }
                .disabled(!annotations.canUndo(sessionId: session.id))
            }
        }
        .task { await prepare() }
    }

    // MARK: - 進捗（F-I8-1: 常時表示）

    private var progressHeader: some View {
        VStack(spacing: 4) {
            HStack {
                Text("\(annotation.reviewedCount) / \(events.count) レビュー済み")
                    .font(.headline)
                Spacer()
                Text("残り \(annotation.remainingCount)")
                    .font(.subheadline)
                    .foregroundStyle(annotation.remainingCount == 0 ? .green : .secondary)
            }
            ProgressView(
                value: Double(annotation.reviewedCount),
                total: Double(max(events.count, 1))
            )
        }
        .monospacedDigit()
    }

    // MARK: - 候補の情報

    private var candidateInfo: some View {
        HStack {
            Text("#\(currentIndex + 1)")
                .font(.headline)
            if let peak = currentEvent?.detectorPeak {
                Text(String(format: "ピーク %.1fg", peak))
                    .foregroundStyle(.secondary)
            }
            if currentEvent?.origin == .manual {
                Label("手動追加", systemImage: "hand.point.up.left")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusLabel
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch currentEvent?.status {
        case .confirmed:
            Label(currentEvent?.shotClass?.displayName ?? "承認", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .rejected:
            Label("却下", systemImage: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        default:
            Label("未判断", systemImage: "questionmark.circle")
                .foregroundStyle(.orange)
        }
    }

    // MARK: - 選別（F-I8-2: 承認＋球種指定を1操作で）

    private var classificationButtons: some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                ForEach(ShotClass.allCases) { shotClass in
                    Button {
                        apply(shotClass)
                    } label: {
                        Text(shotClass.displayName)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button {
                    reject()
                } label: {
                    Text("却下")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

            // F-I8-3: 練習はブロック単位で行われることが多い（フォア20本 → バック20本）
            Stepper("この候補から \(bulkCount) 件へ適用", value: $bulkCount, in: 1...30)
                .font(.caption)
        }
    }

    private var navigationRow: some View {
        HStack {
            Button("前へ", systemImage: "chevron.left") { move(by: -1) }
                .disabled(currentIndex == 0)
            Spacer()
            // 判断を保留して次へ（proposed のまま維持する。F-I8-2）
            Button("保留して次へ") { move(by: 1) }
            Spacer()
            Button("未判断へ", systemImage: "forward.end") { jumpToUnreviewed() }
                .disabled(annotation.firstUnreviewedIndex == nil)
        }
        .font(.subheadline)
    }

    // MARK: - 操作

    /// 承認と球種指定、そして次の候補への移動までを1タップで行う
    private func apply(_ shotClass: ShotClass) {
        guard let event = currentEvent else { return }
        if bulkCount > 1 {
            let targets = Array(events[currentIndex...].prefix(bulkCount)).map(\.id)
            annotations.confirm(sessionId: session.id, eventIds: targets, shotClass: shotClass)
            move(by: bulkCount)
        } else {
            annotations.confirm(sessionId: session.id, eventId: event.id, shotClass: shotClass)
            move(by: 1)
        }
    }

    private func reject() {
        guard let event = currentEvent else { return }
        annotations.reject(sessionId: session.id, eventId: event.id)
        move(by: 1)
    }

    private func move(by offset: Int) {
        let next = min(max(currentIndex + offset, 0), max(events.count - 1, 0))
        currentIndex = next
        focusCurrentEvent()
    }

    private func jumpToUnreviewed() {
        guard let index = annotation.firstUnreviewedIndex else { return }
        currentIndex = index
        focusCurrentEvent()
    }

    // MARK: - 準備と同期

    private func prepare() async {
        let chunks = continuousStore.chunks(for: session.id)
        if annotation.events.isEmpty, !chunks.isEmpty {
            isDetecting = true
            await annotations.detectCandidates(sessionId: session.id, chunks: chunks)
            isDetecting = false
        }
        // F-I8-8: 前回レビューした位置から再開する
        currentIndex = annotation.firstUnreviewedIndex ?? 0
        controller = SyncPlaybackController(
            timeline: timeline(around: currentEvent?.impactAt ?? session.startedAt),
            segmentURL: { [videoStore] segment in
                videoStore.existingSegmentURL(sessionId: session.id, segment: segment)
            }
        )
        focusCurrentEvent()
    }

    /// 候補へ移動し、操作なしで再生を始める（F-I8-1: 共通経路は操作ゼロ）
    private func focusCurrentEvent() {
        guard let controller, let event = currentEvent else { return }
        let timeline = timeline(around: event.impactAt)
        controller.retarget(to: timeline, startingAt: timeline.range.start)
        controller.play()
        loadBins(for: timeline)
    }

    private func timeline(around date: Date) -> ContinuousTimeline {
        ContinuousTimeline(
            session: session,
            around: date,
            leading: Self.leadingSeconds,
            trailing: Self.trailingSeconds
        )
    }

    private func loadBins(for timeline: ContinuousTimeline) {
        let chunks = continuousStore.chunks(for: session.id)
        let range = timeline.range
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                WaveformLoader.loadBins(chunks: chunks, range: range, binCount: Self.binCount)
            }.value
            // 読み込み中に次の候補へ移っていたら破棄する
            guard controller?.timeline.range == range else { return }
            bins = loaded
        }
    }

    private var markers: [WaveformMarker] {
        guard let range = controller?.timeline.range else { return [] }
        return events
            .filter { $0.impactAt >= range.start && $0.impactAt <= range.end }
            .map {
                WaveformMarker(
                    id: $0.id, date: $0.impactAt, status: $0.status, origin: $0.origin
                )
            }
    }
}
