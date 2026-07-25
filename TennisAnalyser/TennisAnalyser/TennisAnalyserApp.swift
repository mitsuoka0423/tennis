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

        // F-I6: スイング受信のたびに対応する動画クリップを自動生成する
        store.onIngested = { [weak videoStore] record in
            Task { await videoStore?.extractClipIfNeeded(
                sessionId: record.sessionId, sequence: record.sequence, detectedAt: record.detectedAt
            ) }
        }

        sessionManager = PhoneSessionManager(
            store: store,
            continuousStore: continuousStore,
            videoStore: videoStore,
            recorder: recorder,
            diagnostics: diagnostics
        )
        sessionManager.activate()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(diagnostics: diagnostics)
                .environmentObject(store)
                .environmentObject(continuousStore)
                .environmentObject(videoStore)
                .environmentObject(recorder)
                .task {
                    videoStore.removeLegacyLayout()
                    store.reload()
                    continuousStore.reload()
                    videoStore.reload()
                }
        }
    }
}

/// アプリのルートタブ（F-I6: スイング一覧 / 録画 の2タブ構成）
private struct RootTabView: View {

    let diagnostics: DiagnosticsStore

    var body: some View {
        TabView {
            ContentView()
                .tabItem { Label("スイング", systemImage: "figure.tennis") }
            RecordingCameraView()
                .tabItem { Label("録画", systemImage: "video") }
            SessionDiagnosticsView(diagnostics: diagnostics)
                .tabItem { Label("診断", systemImage: "waveform.path.ecg") }
        }
    }
}
