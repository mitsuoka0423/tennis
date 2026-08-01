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
            ScrollView {
                VStack(spacing: 6) {
                    NavigationLink {
                        ContentView(workoutSessionManager: workoutSessionManager)
                    } label: {
                        MenuRow(
                            title: "計測",
                            detail: "スイングを記録する",
                            systemImage: "figure.tennis",
                            tint: GlassPalette.accent
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        SensorMonitorView()
                    } label: {
                        MenuRow(
                            title: "モニター",
                            detail: "加速度・角速度を波形で見る",
                            systemImage: "waveform.path.ecg",
                            tint: GlassPalette.info
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 6)
            }
            .navigationTitle("Tennis Analyser")
        }
    }
}

// MARK: - MenuRow

/// 用途を選ぶ行
///
/// Why not `List` のまま組む: 行の背景と選択時のハイライトが標準のグレーで
/// 描かれ、ガラスの面がその上に重なって二重の板に見える。面をこちらで
/// 敷くため、素の `ScrollView` に置いている。
private struct MenuRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(
                    tint.opacity(0.13),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(tint.opacity(0.40), lineWidth: 0.5)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(GlassPalette.label)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .glassSurface()
    }
}

// MARK: - Preview

#Preview {
    RootView(workoutSessionManager: nil)
}
