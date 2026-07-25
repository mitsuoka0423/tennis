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
        let d = diagnostics.diagnostics(for: sessionId)
        let pending = pendingSwings(for: sessionId)

        List {
            Section("録画") {
                row("カバー率", d.coverageRatio.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? "—")
                row("録画時間", Self.duration(d.recordedDuration))
                row("セッション時間", d.sessionDuration.map(Self.duration) ?? "—")
                row("セグメント数", "\(d.segmentCount)")
                row("中断回数", "\(d.interruptionCount)")
            }

            if !d.segmentEndReasonCounts.isEmpty {
                Section("セグメント終了理由") {
                    ForEach(SegmentEndReason.allCases, id: \.self) { reason in
                        if let count = d.segmentEndReasonCounts[reason] {
                            row(Self.label(for: reason), "\(count)")
                        }
                    }
                }
            }

            Section("クリップ") {
                row("生成成功", "\(d.clipsExtracted)")
                row("生成できず", "\(d.clipsSkipped)")
                ForEach(ClipSkipReason.allCases, id: \.self) { reason in
                    if let count = d.skipReasonCounts[reason] {
                        row(Self.label(for: reason), "\(count)")
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
                ShareLink(item: shareText(sessionId: sessionId, diagnostics: d)) {
                    Label("診断内容を共有", systemImage: "square.and.arrow.up")
                }
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

    // MARK: - 共有

    private func shareText(sessionId: String, diagnostics d: SessionDiagnostics) -> String {
        """
        TennisAnalyser セッション診断
        SessionID: \(sessionId)
        開始: \(d.sessionStartedAt.map(Self.dateFormatter.string(from:)) ?? "—")
        録画時間: \(Self.duration(d.recordedDuration)) / セッション時間: \(d.sessionDuration.map(Self.duration) ?? "—")
        カバー率: \(d.coverageRatio.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? "—")
        セグメント数: \(d.segmentCount) / 中断回数: \(d.interruptionCount)
        クリップ: 成功 \(d.clipsExtracted) / 失敗 \(d.clipsSkipped)
        失敗理由: \(d.skipReasonCounts.map { "\(Self.label(for: $0.key))=\($0.value)" }.joined(separator: ", "))
        """
    }

    // MARK: - 表示用

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d分%02d秒", total / 60, total % 60)
    }

    private static func label(for reason: SegmentEndReason) -> String {
        switch reason {
        case .sessionEnded: return "セッション終了"
        case .interrupted: return "中断"
        case .maxDuration: return "最大長に到達"
        case .error: return "エラー"
        }
    }

    private static func label(for reason: ClipSkipReason) -> String {
        switch reason {
        case .detectedAtMissing: return "検知時刻が不明"
        case .noSourceRecording: return "録画が存在しない"
        case .sourceFileMissing: return "動画ファイルが見つからない"
        case .outOfRecordedRange: return "録画されていない時間帯"
        case .extractionFailed: return "切り出しに失敗"
        }
    }
}
