//
//  SwingDetailView.swift
//  TennisAnalyser
//
//  Presentation — スイング波形の詳細表示（F-I2, Swift Charts）

import SwiftUI
import Charts

struct SwingDetailView: View {

    let record: SwingRecord

    @State private var samples: [SwingSamplePoint] = []
    @State private var isLoading = true

    /// X/Y/Z 軸の系列色（dataviz 検証済みパレット: ライト/ダーク両モードで CVD ΔE 9.5）
    /// 固定順で割り当て、循環させない
    private static let axisColors: KeyValuePairs<String, Color> = [
        "X": Color(red: 0x42 / 255.0, green: 0x69 / 255.0, blue: 0xD0 / 255.0),  // #4269D0
        "Y": Color(red: 0xB4 / 255.0, green: 0x53 / 255.0, blue: 0x09 / 255.0),  // #B45309
        "Z": Color(red: 0x3C / 255.0, green: 0xA9 / 255.0, blue: 0x51 / 255.0),  // #3CA951
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if isLoading {
                    ProgressView("読み込み中...")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if samples.isEmpty {
                    ContentUnavailableView(
                        "波形データを読み込めません",
                        systemImage: "waveform.slash"
                    )
                } else {
                    waveformChart(
                        title: "加速度 (g)",
                        points: accelerationPoints
                    )
                    waveformChart(
                        title: "角速度 (°/s)",
                        points: gyroPoints
                    )
                }
            }
            .padding()
        }
        .navigationTitle("スイング #\(record.sequence)")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 波形は詳細表示時に遅延ロード（一覧はメタ情報のみで軽量に保つ）
            let url = record.fileURL
            let loaded = await Task.detached(priority: .userInitiated) {
                SwingCSVParser.parseSamples(fileURL: url)
            }.value
            samples = loaded
            isLoading = false
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let date = record.detectedAt {
                Text(date.formatted(date: .abbreviated, time: .standard))
                    .font(.headline)
            }
            HStack(spacing: 16) {
                if let peak = record.peakAcceleration {
                    Label(String(format: "ピーク %.1f g", peak), systemImage: "bolt")
                }
                Label("\(samples.count) サンプル", systemImage: "waveform")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Chart

    private struct ChartPoint: Identifiable {
        let id = UUID()
        /// インパクトからの相対時間 (秒)
        let time: Double
        let value: Double
        let axis: String
    }

    /// インパクト時刻（相対時間の原点）。メタ欠損時は先頭サンプル
    private var impactMs: Int64 {
        record.impactTimestampMs ?? samples.first?.timestampMs ?? 0
    }

    private var accelerationPoints: [ChartPoint] {
        chartPoints { [("X", $0.accX), ("Y", $0.accY), ("Z", $0.accZ)] }
    }

    private var gyroPoints: [ChartPoint] {
        chartPoints { [("X", $0.gyroX), ("Y", $0.gyroY), ("Z", $0.gyroZ)] }
    }

    private func chartPoints(
        _ extract: (SwingSamplePoint) -> [(String, Double)]
    ) -> [ChartPoint] {
        samples.flatMap { sample in
            extract(sample).map { axis, value in
                ChartPoint(
                    time: Double(sample.timestampMs - impactMs) / 1000.0,
                    value: value,
                    axis: axis
                )
            }
        }
    }

    @ViewBuilder
    private func waveformChart(title: String, points: [ChartPoint]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Chart {
                // インパクト時点の基準線（系列色ではなく無彩色）
                RuleMark(x: .value("インパクト", 0.0))
                    .foregroundStyle(.gray.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                ForEach(points) { point in
                    LineMark(
                        x: .value("時間 (秒)", point.time),
                        y: .value(title, point.value),
                        series: .value("軸", point.axis)
                    )
                    .foregroundStyle(by: .value("軸", point.axis))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
            .chartForegroundStyleScale(Self.axisColors)
            .chartXAxisLabel("インパクトからの時間 (秒)", alignment: .center)
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: 220)
        }
    }
}
