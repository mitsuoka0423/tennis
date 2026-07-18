//
//  ContentView.swift
//  TennisAnalyser
//
//  Presentation — スイング一覧（F-I2）
//  練習中に新着スイングが自動で追加される（SwingStore が受信のたびに reload）

import SwiftUI

struct ContentView: View {

    @EnvironmentObject private var store: SwingStore
    @State private var showsAxisGuide = false

    var body: some View {
        NavigationStack {
            Group {
                if store.records.isEmpty {
                    emptyState
                } else {
                    swingList
                }
            }
            .navigationTitle("スイング")
            .toolbar {
                // I-5: 座標軸ガイドは詳細画面と同じ右上に統一
                // （詳細画面は戻るボタンが左上を占めるため、右上が共通位置として自然）
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("再読み込み")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsAxisGuide = true
                    } label: {
                        Image(systemName: "move.3d")
                    }
                    .accessibilityLabel("座標軸ガイド")
                }
            }
            .sheet(isPresented: $showsAxisGuide) {
                AxisGuideView()
            }
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        ContentUnavailableView(
            "スイングはまだありません",
            systemImage: "figure.tennis",
            description: Text("Watch で計測を開始してスイングすると、\n自動でここに追加されます。")
        )
    }

    private var swingList: some View {
        List {
            ForEach(sessionGroups, id: \.sessionId) { group in
                Section(header: Text(sessionTitle(group))) {
                    ForEach(group.records) { record in
                        NavigationLink(value: record.id) {
                            SwingRow(record: record)
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { group.records[$0] }.forEach(store.delete)
                    }
                }
            }
        }
        .navigationDestination(for: String.self) { recordId in
            if let record = store.records.first(where: { $0.id == recordId }) {
                SwingDetailView(record: record)
            }
        }
        .refreshable { store.reload() }
    }

    // MARK: - Grouping

    private struct SessionGroup {
        let sessionId: String
        let records: [SwingRecord]
    }

    /// セッションごとにグルーピング（新しいセッションが先頭）
    private var sessionGroups: [SessionGroup] {
        let grouped = Dictionary(grouping: store.records, by: \.sessionId)
        return grouped
            .map { SessionGroup(sessionId: $0.key, records: $0.value.sorted { $0.sequence > $1.sequence }) }
            .sorted {
                ($0.records.first?.detectedAt ?? .distantPast)
                    > ($1.records.first?.detectedAt ?? .distantPast)
            }
    }

    private func sessionTitle(_ group: SessionGroup) -> String {
        if let date = group.records.last?.detectedAt {
            // I-2: 日付は yyyy-MM-dd 表記
            return date.ymdhmString + " のセッション (\(group.records.count)本)"
        }
        return "セッション (\(group.records.count)本)"
    }
}

// MARK: - SwingRow

/// 一覧の1行: 連番・時刻・ピーク加速度（F-I2: 時刻・連番で見分ける）
private struct SwingRow: View {
    let record: SwingRecord

    var body: some View {
        HStack(spacing: 12) {
            Text("#\(record.sequence)")
                .font(.headline)
                .monospacedDigit()
                .frame(minWidth: 44, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                if let date = record.detectedAt {
                    Text(date.formatted(date: .omitted, time: .standard))
                        .font(.body)
                } else {
                    Text("時刻不明")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                if let peak = record.peakAcceleration {
                    Text(String(format: "ピーク %.1f g", peak))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(SwingStore())
}
