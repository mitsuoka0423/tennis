//
//  LiquidGlass.swift
//  TennisAnalyser Watch App
//
//  Presentation — 画面をまたぐ Liquid Glass の共通スタイル

import SwiftUI

// MARK: - 色

/// 画面をまたいで使う色
///
/// 黒地の上では、面そのものに色を持たせず白の半透明で作る。
/// 色は「その操作・状態が何を意味するか」にだけ使う。
enum GlassPalette {
    /// 計測・正常（#30D158）
    static let accent = Color(red: 0.188, green: 0.820, blue: 0.345)
    /// 停止・異常（#FF453A）
    static let danger = Color(red: 1.000, green: 0.271, blue: 0.227)
    /// 一時停止・注意（#FF9F0A）
    static let caution = Color(red: 1.000, green: 0.624, blue: 0.039)
    /// 補助情報（#64D2FF）
    static let info = Color(red: 0.392, green: 0.824, blue: 1.000)
    /// ラベル（#8E8E93）
    static let label = Color(red: 0.557, green: 0.557, blue: 0.576)
    /// レートが健全でないときの中間色（#FFD60A）
    static let warning = Color(red: 1.000, green: 0.839, blue: 0.039)
}

// MARK: - ガラスの面

/// ガラスの面
///
/// Why not `.ultraThinMaterial`: 背景が黒一色で透過するものが無く、面が
/// 濃いグレーに沈んで縁も出ない。黒の上で層を層として見せているのは
/// 素材のぼかしではなく、白の半透明と上辺のハイライトである。
private struct GlassSurface: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                Color.white.opacity(0.11),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.40), .white.opacity(0.10)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
            }
    }
}

extension View {
    /// ガラスの面を敷く
    func glassSurface(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius))
    }
}

// MARK: - 角丸バー

/// 画面下端に置く操作の共通形（角丸バー）
///
/// **全画面でこの形に統一する。** 大きさ・位置・角丸を揃え、色だけが
/// 動作の意味を表す。画面が切り替わってもボタンが動かないため、
/// 押す場所を探し直さずに済む。
struct GlassBarButton: View {

    /// ラベル左の記号。SF Symbol ではなく素の図形を使い、文字と同じ重さに見せる
    enum Glyph {
        case record
        case stop
        case none
    }

    let title: String
    var glyph: Glyph = .none
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                switch glyph {
                case .record:
                    Circle()
                        .fill(.white)
                        .frame(width: 7, height: 7)
                case .stop:
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(.white)
                        .frame(width: 7, height: 7)
                case .none:
                    EmptyView()
                }
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.white)
        }
        .buttonStyle(GlassBarButtonStyle(tint: tint))
    }
}

/// 角丸バーの見た目
///
/// Why not カタログ 1c の鏡面（走る光）を再現する: 常時アニメーションは
/// 再描画が止まらず、計測中の消費電力に効く。層の存在は縁のハイライトで
/// 足りるため、動く光は落とした。
private struct GlassBarButtonStyle: ButtonStyle {
    let tint: Color

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                LinearGradient(
                    colors: [tint.opacity(0.42), tint.opacity(0.22)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: shape
            )
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.45), .white.opacity(0.12)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.5
                )
            }
            .shadow(color: tint.opacity(0.22), radius: 8, y: 4)
            .opacity(configuration.isPressed ? 0.72 : 1.0)
    }
}

// MARK: - Preview

#Preview("角丸バー") {
    VStack(spacing: 8) {
        GlassBarButton(title: "計測開始", glyph: .record, tint: GlassPalette.accent) {}
        GlassBarButton(title: "停止・保存", glyph: .stop, tint: GlassPalette.danger) {}
        GlassBarButton(title: "一時停止", tint: GlassPalette.caution) {}
        GlassBarButton(title: "再開", tint: GlassPalette.accent) {}
    }
    .padding(.horizontal, 10)
}
