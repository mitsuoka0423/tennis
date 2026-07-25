//
//  WaveformDownsampler.swift
//  TennisAnalyser (iOS)
//
//  Domain — 波形描画用の間引き（F-I8-4 / W6-T16b）

import Foundation

/// 壁時計に対応付けたセンサー1点
struct TimedSample: Equatable, Sendable {
    let date: Date
    let acceleration: Double
    let gyro: Double
}

/// 描画1本分の区間
struct WaveformBin: Equatable, Identifiable, Sendable {
    var id: Date { startedAt }
    let startedAt: Date
    /// 区間内の加速度の最大値 (g)
    let peakAcceleration: Double
    /// 区間内の角速度の最大値 (°/s)
    let peakGyro: Double
    /// 区間にサンプルが存在したか（センサー記録の欠落を動画の欠落と区別する）
    let hasSamples: Bool
}

/// サンプル列を表示倍率に応じて間引く
enum WaveformDownsampler {

    /// 区間ごとの最大値でビン化する
    ///
    /// - Parameters:
    ///   - samples: 壁時計順のサンプル列
    ///   - range: 描画対象の範囲
    ///   - binCount: 描画する本数（表示幅に応じて決める）
    ///
    /// Why not 区間内の平均: 1セッションは約68万サンプルあり、画面幅に収めるには
    /// 数十〜数百倍の間引きが要る。平均ではインパクトのピークが平滑化されて消え、
    /// 「マーカーの無いピーク」として見落としを発見する作業（F-I8-5）が成立しない。
    nonisolated static func bins(
        from samples: [TimedSample],
        range: DateInterval,
        binCount: Int
    ) -> [WaveformBin] {
        guard binCount > 0, range.duration > 0 else { return [] }

        let binDuration = range.duration / Double(binCount)
        var accelerationPeaks = [Double](repeating: 0, count: binCount)
        var gyroPeaks = [Double](repeating: 0, count: binCount)
        var filled = [Bool](repeating: false, count: binCount)

        for sample in samples {
            let offset = sample.date.timeIntervalSince(range.start)
            guard offset >= 0, offset < range.duration else { continue }
            let index = min(Int(offset / binDuration), binCount - 1)
            filled[index] = true
            accelerationPeaks[index] = max(accelerationPeaks[index], sample.acceleration)
            gyroPeaks[index] = max(gyroPeaks[index], sample.gyro)
        }

        return (0..<binCount).map { index in
            WaveformBin(
                startedAt: range.start.addingTimeInterval(binDuration * Double(index)),
                peakAcceleration: accelerationPeaks[index],
                peakGyro: gyroPeaks[index],
                hasSamples: filled[index]
            )
        }
    }
}
