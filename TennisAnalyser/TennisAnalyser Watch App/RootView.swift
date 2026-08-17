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
                VStack(spacing: 20) {
                    NavigationLink {
                        ContentView(workoutSessionManager: workoutSessionManager)
                    } label: {
                        ModeCard(
                            title: "計測",
                            detail: "スイングを記録",
                            systemImage: "figure.tennis",
                            tint: GlassPalette.accent
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        SensorMonitorView()
                    } label: {
                        ModeCard(
                            title: "モニター",
                            detail: "波形を見る",
                            systemImage: "waveform.path.ecg",
                            tint: GlassPalette.info
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .navigationTitle("Tennis Analyser")
            // Why not 大きいタイトルのまま送る: 起動直後に見せたいのはカード2枚で、
            // 大タイトルは1枚目の下半分を画面外へ押し出す
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - ModeCard

/// 用途を選ぶカード
///
/// 手前に来た1枚だけを不透明で描き、外れた枚は 60% へ落とす。Digital Crown で
/// 送ったとき、いま選んでいるのがどれかを位置ではなく濃さで示すため。
///
/// Why not `List` の行にする: 行の背景と選択時のハイライトが標準のグレーで
/// 描かれ、ガラスの面がその上に重なって二重の板に見える。面をこちらで
/// 敷くため、素の `ScrollView` に置いている。
private struct ModeCard: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(
                        tint.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(tint.opacity(0.45), lineWidth: 0.5)
                    }

                Spacer(minLength: 0)

                Image(systemName: "chevron.forward")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 18, height: 18)
                    .background(tint.opacity(0.2), in: Circle())
            }

            Spacer(minLength: 0)

            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(GlassPalette.secondaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(height: 92, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .listGlass()
        .scrollTransition { content, phase in
            content.opacity(phase.isIdentity ? 1 : 0.6)
        }
    }
}

// MARK: - Preview

#Preview {
    RootView(workoutSessionManager: nil)
}
