//
//  SessionDiagnosticsView.swift
//  TennisAnalyser (iOS)
//
//  Presentation — セッション診断の閲覧・共有とクリップ生成の再試行（F-I7-5 / T9・T10）
//
//  Why not スイング一覧へ埋め込む: 診断は「録画が正しく動いたか」を見る画面であり、
//  スイングが1件も無い場合こそ最も必要になる。一覧の下位に置くと、
//  最も見たい状況（何も記録されていない）で辿り着けない。

import SwiftUI

struct SessionDiagnosticsView: View {

    @EnvironmentObject private var store: SwingStore
    @EnvironmentObject private var videoStore: VideoStore

    let diagnostics: DiagnosticsStore

    @State private var sessionIds: [String] = []
    @State private var retryingSessionId: String?

    var body: some View {
        NavigationStack {
            Group {
                if sessionIds.isEmpty {
                    ContentUnavailableView(
                        "診断記録がありません",
                        systemImage: "waveform.path.ecg",
                        description: Text("Apple Watch で計測を開始すると記録されます。")
                    )
                } else {
                    List(sessionIds, id: \.self) { sessionId in
                        NavigationLink {
                            detail(for: sessionId)
                        } label: {
                            summaryRow(for: sessionId)
                        }
                    }
                }
            }
            .navigationTitle("セッション診断")
            .refreshable { reload() }
        }
        .task { reload() }
    }

    private func reload() {
        sessionIds = diagnostics.recordedSessionIds()
    }

    // MARK: - 一覧

    @ViewBuilder
    private func summaryRow(for sessionId: String) -> some View {
        let d = diagnostics.diagnostics(for: sessionId)
        VStack(alignment: .leading, spacing: 4) {
            Text(d.sessionStartedAt.map(Self.dateFormatter.string(from:)) ?? sessionId)
                .font(.headline)
            HStack(spacing: 12) {
                coverageLabel(d.coverageRatio)
                Label("\(d.segmentCount)", systemImage: "film.stack")
                if d.interruptionCount > 0 {
                    Label("\(d.interruptionCount)", systemImage: "exclamationmark.triangle")
                }
                Label("\(d.clipsExtracted)/\(d.clipsExtracted + d.clipsSkipped)", systemImage: "scissors")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// カバー率は本画面の主要指標。2026-07-21 はこれが 0.6% だった
    @ViewBuilder
    private func coverageLabel(_ ratio: Double?) -> some View {
        if let ratio {
            Label(ratio.formatted(.percent.precision(.fractionLength(0))), systemImage: "video")
                .foregroundStyle(ratio < 0.95 ? Color.red : Color.secondary)
        } else {
            Label("—", systemImage: "video")
        }
    }

    // MARK: - 詳細

    @ViewBuilder
    private func detail(for sessionId: String) -> some View {
        let events = diagnostics.events(for: sessionId)
        let d = SessionDiagnostics.make(sessionId: sessionId, from: events)
        let pending = pendingSwings(for: sessionId)
        // 録画がなぜ止まったかは集計では判別できない。中断理由の文字列
        // （`captureInterrupted(reason=5)` 等）と、中断に復帰が続いているかは
        // 出来事の並びにしか現れないため、画面上でも読めるようにする
        let timeline = DiagnosticsReport.timeline(from: events)

        List {
            Section("録画") {
                row("カバー率", d.coverageRatio.map { DiagnosticsReport.percent($0) } ?? "—")
                row("録画時間", DiagnosticsReport.duration(d.recordedDuration))
                row("セッション時間", d.sessionDuration.map { DiagnosticsReport.duration($0) } ?? "—")
                row("セグメント数", "\(d.segmentCount)")
                row("中断回数", "\(d.interruptionCount)")
                row("復帰回数", "\(d.resumptionCount)")
            }

            if !d.segmentEndReasonCounts.isEmpty {
                Section("セグメント終了理由") {
                    ForEach(SegmentEndReason.allCases, id: \.self) { reason in
                        if let count = d.segmentEndReasonCounts[reason] {
                            row(DiagnosticsReport.label(for: reason), "\(count)")
                        }
                    }
                }
            }

            Section("クリップ") {
                row("生成成功", "\(d.clipsExtracted)")
                row("生成できず", "\(d.clipsSkipped)")
                ForEach(ClipSkipReason.allCases, id: \.self) { reason in
                    if let count = d.skipReasonCounts[reason] {
                        row(DiagnosticsReport.label(for: reason), "\(count)")
                    }
                }
            }

            if !timeline.isEmpty {
                Section {
                    ForEach(timeline.indices, id: \.self) { index in
                        Text(timeline[index])
                            .font(.caption.monospaced())
                    }
                } header: {
                    Text("出来事")
                } footer: {
                    if d.interruptionCount > d.resumptionCount {
                        Text("復帰しなかった中断が \(d.interruptionCount - d.resumptionCount) 件あります。以降の録画は止まったままです。")
                    }
                }
            }

            // T9: 未生成クリップの手動再試行
            if !pending.isEmpty {
                Section {
                    Button {
                        retry(sessionId: sessionId, records: pending)
                    } label: {
                        if retryingSessionId == sessionId {
                            HStack { ProgressView(); Text("再試行中…") }
                        } else {
                            Label("未生成の \(pending.count) 件を再生成", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(retryingSessionId != nil)
                } footer: {
                    Text("セグメントは保持されているため、クリップは何度でも生成し直せます。")
                }
            }

            Section {
                ShareLink(item: DiagnosticsReport.text(sessionId: sessionId, events: events)) {
                    Label("診断内容を共有", systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text("集計に加えて、中断理由と出来事の並びを含みます。")
            }
        }
        .navigationTitle("診断")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    // MARK: - 再試行（T9）

    private func pendingSwings(for sessionId: String) -> [SwingRecord] {
        store.records.filter {
            $0.sessionId == sessionId && !videoStore.hasClip(sessionId: sessionId, sequence: $0.sequence)
        }
    }

    private func retry(sessionId: String, records: [SwingRecord]) {
        retryingSessionId = sessionId
        Task {
            for record in records {
                await videoStore.extractClipIfNeeded(
                    sessionId: record.sessionId, sequence: record.sequence, detectedAt: record.detectedAt
                )
            }
            retryingSessionId = nil
        }
    }

    // MARK: - 表示用

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
