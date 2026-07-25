//
//  ContinuousWaveformView.swift
//  TennisAnalyser (iOS)
//
//  Presentation — 連続波形の描画とスクラブ（F-I8-4/5 / W6-T16b）

import SwiftUI

/// 波形上に立てる目印
struct WaveformMarker: Identifiable, Equatable {
    let id: String
    let date: Date
    let status: AnnotationStatus
    let origin: EventOrigin

    var color: Color {
        switch status {
        case .proposed: return .orange
        case .confirmed: return .green
        case .rejected: return .gray
        }
    }
}

/// 連続波形
///
/// 横軸は壁時計。動画の欠落区間・センサーの欠落区間・アノテーションの位置・
/// 再生位置をすべて同じ軸の上に重ねる。
struct ContinuousWaveformView: View {

    let bins: [WaveformBin]
    let range: DateInterval
    /// 動画が存在しない区間（F-I8-4）
    let gaps: [TimelineGap]
    let markers: [WaveformMarker]
    /// 再生位置（壁時計）
    let currentDate: Date
    /// スクラブ時に呼ばれる（動画がこれに追従する）
    let onScrub: (Date) -> Void

    /// 縦軸の上限 (g)
    ///
    /// 実測では加速度計が ±15.9g で飽和する。固定上限にすると強打のたびに
    /// 天井へ張り付くため、表示範囲内の最大値へ合わせる（下限は 4g）。
    private var verticalScale: Double {
        max(bins.map(\.peakAcceleration).max() ?? 0, 4.0)
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                Canvas { context, canvasSize in
                    drawGaps(in: &context, size: canvasSize)
                    drawBins(in: &context, size: canvasSize)
                    drawMarkers(in: &context, size: canvasSize)
                    drawPlayhead(in: &context, size: canvasSize)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in onScrub(date(atX: value.location.x, width: size.width)) }
            )
        }
        .frame(height: 120)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 描画

    private func drawGaps(in context: inout GraphicsContext, size: CGSize) {
        for gap in gaps {
            let startX = x(of: gap.startedAt, width: size.width)
            let endX = x(of: gap.endedAt, width: size.width)
            guard endX > startX else { continue }
            context.fill(
                Path(CGRect(x: startX, y: 0, width: endX - startX, height: size.height)),
                with: .color(.red.opacity(0.12))
            )
        }
    }

    private func drawBins(in context: inout GraphicsContext, size: CGSize) {
        guard !bins.isEmpty else { return }
        let binWidth = size.width / Double(bins.count)
        for (index, bin) in bins.enumerated() {
            guard bin.hasSamples else { continue }
            let height = size.height * min(bin.peakAcceleration / verticalScale, 1.0)
            let rect = CGRect(
                x: Double(index) * binWidth,
                y: size.height - height,
                width: max(binWidth, 0.5),
                height: height
            )
            context.fill(Path(rect), with: .color(.accentColor.opacity(0.7)))
        }
    }

    private func drawMarkers(in context: inout GraphicsContext, size: CGSize) {
        for marker in markers {
            let markerX = x(of: marker.date, width: size.width)
            var path = Path()
            path.move(to: CGPoint(x: markerX, y: 0))
            path.addLine(to: CGPoint(x: markerX, y: size.height))
            context.stroke(
                path,
                with: .color(marker.color),
                style: StrokeStyle(
                    lineWidth: 1.5,
                    dash: marker.origin == .manual ? [3, 2] : []
                )
            )
        }
    }

    private func drawPlayhead(in context: inout GraphicsContext, size: CGSize) {
        let playheadX = x(of: currentDate, width: size.width)
        var path = Path()
        path.move(to: CGPoint(x: playheadX, y: 0))
        path.addLine(to: CGPoint(x: playheadX, y: size.height))
        context.stroke(path, with: .color(.primary), lineWidth: 2)
    }

    // MARK: - 座標変換

    private func x(of date: Date, width: Double) -> Double {
        guard range.duration > 0 else { return 0 }
        let ratio = date.timeIntervalSince(range.start) / range.duration
        return min(max(ratio, 0), 1) * width
    }

    private func date(atX x: Double, width: Double) -> Date {
        guard width > 0 else { return range.start }
        let ratio = min(max(x / width, 0), 1)
        return range.start.addingTimeInterval(range.duration * ratio)
    }
}
