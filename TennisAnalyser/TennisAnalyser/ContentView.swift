//
//  ContentView.swift
//  TennisAnalyser
//
//  Presentation — スイング一覧（F-I2）+ アノテーション（F-I3）
//  練習中に新着スイングが自動で追加される（SwingStore が受信のたびに reload）

import SwiftUI

/// 一覧の絞り込み条件（F-I2 将来項目: ショット種別ラベルによる絞り込み）
private enum SwingFilter: Hashable {
    case all
    case unlabeled
    case shotClass(ShotClass)

    var title: String {
        switch self {
        case .all: return "すべて"
        case .unlabeled: return "未タグ"
        case .shotClass(let shotClass): return shotClass.displayName
        }
    }

    func matches(_ record: SwingRecord) -> Bool {
        switch self {
        case .all: return true
        case .unlabeled: return record.shotClass == nil
        case .shotClass(let shotClass): return record.shotClass == shotClass
        }
    }
}

struct ContentView: View {

    @EnvironmentObject private var store: SwingStore
    @State private var showsAxisGuide = false
    @State private var filter: SwingFilter = .all
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<String>()

    var body: some View {
        NavigationStack {
            Group {
                if store.records.isEmpty {
                    emptyState
                } else if filteredRecords.isEmpty {
                    ContentUnavailableView(
                        "「\(filter.title)」に一致するスイングはありません",
                        systemImage: "line.3.horizontal.decrease.circle"
                    )
                } else {
                    swingList
                }
            }
            .navigationTitle("スイング")
            .toolbar {
                toolbarContent
            }
            .environment(\.editMode, $editMode)
            .sheet(isPresented: $showsAxisGuide) {
                AxisGuideView()
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // I-5: 座標軸ガイドは詳細画面と同じ右上に統一
        // （詳細画面は戻るボタンが左上を占めるため、右上が共通位置として自然）
        if editMode == .active {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(ShotClass.allCases) { shotClass in
                        Button(shotClass.displayName) {
                            applyBulkTag(shotClass)
                        }
                    }
                } label: {
                    Label("一括タグ付け", systemImage: "tag")
                }
                .disabled(selection.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("完了") { editMode = .inactive; selection.removeAll() }
            }
        } else {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("絞り込み", selection: $filter) {
                        Text(SwingFilter.all.title).tag(SwingFilter.all)
                        Text(SwingFilter.unlabeled.title).tag(SwingFilter.unlabeled)
                        Divider()
                        ForEach(ShotClass.allCases) { shotClass in
                            Text(shotClass.displayName).tag(SwingFilter.shotClass(shotClass))
                        }
                    }
                } label: {
                    Label("絞り込み", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
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
            if !store.records.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("選択") { editMode = .active }
                }
            }
        }
    }

    private func applyBulkTag(_ shotClass: ShotClass) {
        let targets = store.records.filter { selection.contains($0.id) }
        store.setShotClass(shotClass, for: targets)
        editMode = .inactive
        selection.removeAll()
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
        List(selection: $selection) {
            ForEach(sessionGroups, id: \.sessionId) { group in
                Section(header: Text(sessionTitle(group))) {
                    ForEach(group.records) { record in
                        if editMode == .active {
                            SwingRow(record: record)
                        } else {
                            NavigationLink(value: record.id) {
                                SwingRow(record: record)
                            }
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { group.records[$0] }.forEach(store.delete)
                    }
                }
            }
        }
        .navigationDestination(for: String.self) { recordId in
            SwingDetailView(recordId: recordId)
        }
        .refreshable { store.reload() }
    }

    // MARK: - Grouping

    private struct SessionGroup {
        let sessionId: String
        let records: [SwingRecord]
    }

    /// 現在の絞り込み条件に一致するスイング
    private var filteredRecords: [SwingRecord] {
        store.records.filter(filter.matches)
    }

    /// セッションごとにグルーピング（新しいセッションが先頭）
    private var sessionGroups: [SessionGroup] {
        let grouped = Dictionary(grouping: filteredRecords, by: \.sessionId)
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

/// 一覧の1行: 連番・時刻・ピーク加速度・ショット種別ラベル（F-I2/F-I3）
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

            if let shotClass = record.shotClass {
                Text(shotClass.displayName)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(SwingStore())
}
