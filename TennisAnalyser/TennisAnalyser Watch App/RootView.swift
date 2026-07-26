//
//  RootView.swift
//  TennisAnalyser Watch App
//
//  Presentation View — 用途を選ぶ入口

import SwiftUI

/// 起動直後に表示する画面
///
/// 計測（F-W1〜W6）とセンサー表示（F-W9）は用途が独立しているため、
/// どちらかの中にもう一方を埋め込まず、ここから分岐させる。
///
/// Why not 片方をルートにしてもう片方をシート/タブで出す: センサー表示は
/// `CMMotionManager`、計測は `CMBatchedSensorManager` を使う。同時に動くと
/// 200Hz の計測レートへ影響しうるため、両者が並走しない構造にしている
/// （計測中は下の `ContentView` が戻る導線を閉じる）。
struct RootView: View {

    /// App から注入される WorkoutSessionManager（HealthKit 認可済み）
    let workoutSessionManager: WorkoutSessionManager?

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    ContentView(workoutSessionManager: workoutSessionManager)
                } label: {
                    MenuRow(
                        title: "計測",
                        detail: "スイングを記録する",
                        systemImage: "figure.tennis",
                        tint: .green
                    )
                }

                NavigationLink {
                    SensorMonitorView()
                } label: {
                    MenuRow(
                        title: "センサー",
                        detail: "加速度・角速度を波形で見る",
                        systemImage: "waveform.path.ecg",
                        tint: .blue
                    )
                }
            }
            .navigationTitle("Tennis Analyser")
        }
    }
}

// MARK: - MenuRow

private struct MenuRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.gray)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Preview

#Preview {
    RootView(workoutSessionManager: nil)
}
