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
    @StateObject private var videoStore: VideoStore
    @StateObject private var recorder: PracticeVideoRecorder
    private let sessionManager: PhoneSessionManager

    init() {
        let store = SwingStore()
        let videoStore = VideoStore()
        _store = StateObject(wrappedValue: store)
        _videoStore = StateObject(wrappedValue: videoStore)
        // recorder は videoStore と同一インスタンスを共有する必要があるため App 側で生成する
        // （RecordingCameraView の init 内では @EnvironmentObject がまだ解決できないため）
        _recorder = StateObject(wrappedValue: PracticeVideoRecorder(videoStore: videoStore))
        sessionManager = PhoneSessionManager(store: store)
        sessionManager.activate()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(store)
                .environmentObject(videoStore)
                .environmentObject(recorder)
                .task {
                    store.reload()
                    videoStore.reload()
                }
        }
    }
}

/// アプリのルートタブ（F-I6: スイング一覧 / 録画 の2タブ構成）
private struct RootTabView: View {
    var body: some View {
        TabView {
            ContentView()
                .tabItem { Label("スイング", systemImage: "figure.tennis") }
            RecordingCameraView()
                .tabItem { Label("録画", systemImage: "video") }
        }
    }
}
