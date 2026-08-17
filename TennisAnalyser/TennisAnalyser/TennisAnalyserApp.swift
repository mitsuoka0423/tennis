//
//  TennisAnalyserApp.swift
//  TennisAnalyser
//
//  Created by Mitsuoka Takahiro on 2026/07/15.
//

import SwiftUI

@main
struct TennisAnalyserApp: App {

    @StateObject private var store: SwingStore
    @StateObject private var continuousStore: ContinuousSensorStore
    @StateObject private var videoStore: VideoStore
    @StateObject private var recorder: PracticeVideoRecorder
    @StateObject private var annotations: AnnotationStore
    private let sessionManager: PhoneSessionManager
    private let diagnostics: DiagnosticsStore

    init() {
        // 診断記録は録画・クリップ生成・セッション通知の全経路から書かれるため、
        // 単一インスタンスを App 側で生成して配る（F-I7-5）
        let diagnostics = DiagnosticsStore()
        self.diagnostics = diagnostics
        let store = SwingStore()
        let continuousStore = ContinuousSensorStore()
        let videoStore = VideoStore(diagnostics: diagnostics)
        let recorder = PracticeVideoRecorder(videoStore: videoStore, diagnostics: diagnostics)
        _store = StateObject(wrappedValue: store)
        _continuousStore = StateObject(wrappedValue: continuousStore)
        _videoStore = StateObject(wrappedValue: videoStore)
        // recorder は videoStore と同一インスタンスを共有する必要があるため App 側で生成する
        // （RecordingCameraView の init 内では @EnvironmentObject がまだ解決できないため）
        _recorder = StateObject(wrappedValue: recorder)
        _annotations = StateObject(wrappedValue: AnnotationStore())

        // F-I6: スイング受信のたびに対応する動画クリップを自動生成する
        store.onIngested = { [weak videoStore] record in
            Task { await videoStore?.extractClipIfNeeded(
                sessionId: record.sessionId, sequence: record.sequence, detectedAt: record.detectedAt
            ) }
        }

        let sessionManager = PhoneSessionManager(
            store: store,
            continuousStore: continuousStore,
            videoStore: videoStore,
            recorder: recorder,
            diagnostics: diagnostics
        )
        self.sessionManager = sessionManager

        // F-I9-8: セグメントが閉じた時点で未生成クリップを掃く。
        // スイングは自分が写っているセグメントの録画中に届くため、
        // 上の onIngested（到着時の生成）は構造上ほぼ必ず失敗する。
        // 最大長10分ごとにセグメントが閉じるので、ここでセッション中に消化される。
        videoStore.onSegmentClosed = { [weak sessionManager] closedSessionId in
            Task { @MainActor in
                await sessionManager?.sweepPendingClips(sessionId: closedSessionId)
            }
        }

        sessionManager.activate()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(diagnostics: diagnostics)
                .environmentObject(store)
                .environmentObject(continuousStore)
                .environmentObject(videoStore)
                .environmentObject(recorder)
                .environmentObject(annotations)
                .task {
                    videoStore.removeLegacyLayout()
                    store.reload()
                    continuousStore.reload()
                    videoStore.reload()
                    annotations.reload()
                    // F-I9-8: 最終セグメントぶんなど、セッション中に消化しきれなかった分を拾う。
                    // reload の後でなければ生成済みの判定（availableClipKeys）が空になる
                    await sessionManager.sweepPendingClips()
                }
        }
    }
}

/// アプリのルートタブ
///
/// スイング一覧は既存データ（スイング単位で収集した分）の閲覧用として残す。
/// 新規セッションはアノテーション経由でラベル付けする（F-I8 7章）。
private struct RootTabView: View {

    let diagnostics: DiagnosticsStore

    var body: some View {
        TabView {
            ContentView()
                .tabItem { Label("スイング", systemImage: "figure.tennis") }
            RecordingCameraView()
                .tabItem { Label("録画", systemImage: "video") }
            AnnotationSessionListView()
                .tabItem { Label("タグ付け", systemImage: "checklist") }
            SessionDiagnosticsView(diagnostics: diagnostics)
                .tabItem { Label("診断", systemImage: "waveform.path.ecg") }
        }
    }
}
