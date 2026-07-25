//
//  AnnotationSessionListView.swift
//  TennisAnalyser (iOS)
//
//  Presentation — アノテーション対象セッションの一覧（F-I8 6章 / W6-T16c）

import SwiftUI

struct AnnotationSessionListView: View {

    @EnvironmentObject private var annotations: AnnotationStore
    @EnvironmentObject private var continuousStore: ContinuousSensorStore
    @EnvironmentObject private var videoStore: VideoStore

    var body: some View {
        NavigationStack {
            List {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "セッションがありません",
                        systemImage: "waveform",
                        description: Text("Watch でワークアウトを記録すると、ここに現れます")
                    )
                } else {
                    ForEach(sessions) { session in
                        Section {
                            NavigationLink {
                                AnnotationReviewView(session: session)
                            } label: {
                                Label("選別", systemImage: "checklist")
                            }
                        } header: {
                            sessionHeader(session)
                        }
                    }
                }
            }
            .navigationTitle("アノテーション")
            .refreshable {
                continuousStore.reload()
                annotations.reload()
                videoStore.reload()
            }
        }
    }

    // MARK: - Private

    /// 録画セッションを新しい順に並べる
    private var sessions: [RecordingSession] {
        videoStore.sessions.sorted { $0.startedAt > $1.startedAt }
    }

    private func sessionHeader(_ session: RecordingSession) -> some View {
        let annotation = annotations.annotation(for: session.id)
        let chunkCount = continuousStore.chunks(for: session.id).count
        return VStack(alignment: .leading, spacing: 2) {
            Text(session.startedAt.ymdhmString)
                .font(.headline)
            HStack(spacing: 8) {
                Text("\(annotation.reviewedCount) / \(annotation.events.count) レビュー済み")
                Text("承認 \(annotation.confirmedCount)")
                // センサーの連続記録が無ければ候補を作れないため、件数を出して原因を示す
                Text("記録 \(chunkCount) 本")
                    .foregroundStyle(chunkCount == 0 ? .red : .secondary)
            }
            .font(.caption)
            .monospacedDigit()
        }
        .textCase(nil)
    }
}
