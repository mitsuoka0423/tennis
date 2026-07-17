//
//  TennisAnalyserApp.swift
//  TennisAnalyser Watch App
//

import SwiftUI
import HealthKit

@main
struct TennisAnalyser_Watch_AppApp: App {

    // WorkoutSessionManager は ObservableObject でないため @State で保持する
    @State private var workoutSessionManager = WorkoutSessionManager()

    var body: some Scene {
        WindowGroup {
            ContentView(workoutSessionManager: workoutSessionManager)
                .task {
                    // アプリ起動時に HealthKit 認可をリクエストする（初回のみダイアログ表示）
                    try? await workoutSessionManager.requestAuthorization()
                }
        }
    }
}
