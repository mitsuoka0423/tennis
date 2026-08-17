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
    /// 補助情報（#64D2FF）
    static let info = Color(red: 0.392, green: 0.824, blue: 1.000)
    /// ラベル（#8E8E93）
    static let label = Color(red: 0.557, green: 0.557, blue: 0.576)
    /// レートが健全でないときの中間色（#FFD60A）
    static let warning = Color(red: 1.000, green: 0.839, blue: 0.039)

    /// 文字の階層を作る基色（#EBEBF5）
    ///
    /// watchOS の secondaryLabel と同じ色で、濃度だけで主・副・補足を分ける。
    /// グレー（`label`）を濃くしていく方式に比べ、黒地で沈みにくい。
    static let text = Color(red: 0.922, green: 0.922, blue: 0.961)
    /// 副の文字（60%）
    static let secondaryText = text.opacity(0.6)
    /// 補足の文字（40%）
    static let tertiaryText = text.opacity(0.4)
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

/// カードとボタンに敷くガラス（watchOS 26 のリスト行と同じ作り）
///
/// 白の単色ではなく、上を白・下を #CCC 寄りへ落とすグラデーションにする。
/// 縁は描かず、上辺 34% / 下辺 8% の内側ハイライトだけで層の厚みを出す。
private struct ListGlass: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                LinearGradient(
                    colors: [
                        .white.opacity(0.14),
                        Color(white: 0.8).opacity(0.08)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.34), .white.opacity(0.08)],
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

    /// リスト行・カードのガラスを敷く
    func listGlass(cornerRadius: CGFloat = 25) -> some View {
        modifier(ListGlass(cornerRadius: cornerRadius))
    }
}

// MARK: - ピルボタン

/// 画面下端に置く操作の共通形（高さ 44pt の完全なピル）
///
/// **全画面でこの形に統一する。** 大きさ・位置を揃え、色と塗りの強さだけが
/// 動作の意味を表す。画面が切り替わってもボタンが動かないため、
/// 押す場所を探し直さずに済む。
struct GlassBarButton: View {

    /// 塗りの強さ。watchOS 26 の prominent / tinted / plain に対応する
    enum Kind {
        /// その画面で最も期待される操作。tint のベタ塗りに黒の文字
        case prominent
        /// 破壊的・副次の操作。tint 15% の面に tint の文字
        case tinted
        /// 意味を色で示さない操作。ガラスのみ
        case plain
    }

    /// ラベル左の記号。SF Symbol ではなく素の図形を使い、文字と同じ重さに見せる
    enum Glyph {
        case record
        case stop
        case none
    }

    let title: String
    var glyph: Glyph = .none
    var kind: Kind = .prominent
    var tint: Color = GlassPalette.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                switch glyph {
                case .record:
                    Circle()
                        .fill(foreground)
                        .frame(width: 7, height: 7)
                case .stop:
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(foreground)
                        .frame(width: 7, height: 7)
                case .none:
                    EmptyView()
                }
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(foreground)
        }
        .buttonStyle(GlassBarButtonStyle(kind: kind, tint: tint))
    }

    /// 文字と記号の色。塗りの強さで決まる
    private var foreground: Color {
        switch kind {
        case .prominent: .black
        case .tinted: tint
        case .plain: .white
        }
    }
}

/// ピルボタンの見た目
///
/// Why not カタログ 1c の鏡面（走る光）を再現する: 常時アニメーションは
/// 再描画が止まらず、計測中の消費電力に効く。層の存在は縁のハイライトで
/// 足りるため、動く光は落とした。
private struct GlassBarButtonStyle: ButtonStyle {
    let kind: GlassBarButton.Kind
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(background)
            .clipShape(Capsule(style: .continuous))
            .overlay {
                // ベタ塗りの上では白の縁が濁るため、内側ハイライトは半透明の面にだけ置く
                if kind != .prominent {
                    Capsule(style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(kind == .plain ? 0.34 : 0.20), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                }
            }
            .opacity(configuration.isPressed ? 0.72 : 1.0)
    }

    @ViewBuilder
    private var background: some View {
        switch kind {
        case .prominent:
            tint
        case .tinted:
            tint.opacity(0.15)
        case .plain:
            LinearGradient(
                colors: [.white.opacity(0.14), Color(white: 0.8).opacity(0.08)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

// MARK: - Preview

#Preview("ピルボタン") {
    VStack(spacing: 8) {
        GlassBarButton(title: "計測開始", glyph: .record, kind: .prominent, tint: GlassPalette.accent) {}
        GlassBarButton(title: "停止・保存", glyph: .stop, kind: .tinted, tint: GlassPalette.danger) {}
        GlassBarButton(title: "OK", kind: .plain) {}
    }
    .padding(.horizontal, 10)
}
