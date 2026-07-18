//
//  SwingAnalysis.swift
//  TennisAnalyser (iOS)
//
//  Domain — スイング波形の簡易指標（F-I4 解析エンジンの基礎実装）
//
//  Why not: インパクト時刻の検出そのものは Watch 側 SwingDetector が担うため、
//  ここでは「切り出し済みウィンドウ内の特徴点抽出」のみを扱う。
//  自己ベスト比較・理論値比較などの本格的なスコアリングは Phase 3 詳細設計時の
//  TBD（docs/REQUIREMENTS.md F-I4）であり、ここでは実装しない。

import Foundation

/// スイング波形から抽出した簡易指標
struct SwingAnalysisResult: Equatable {
    /// インパクトからの相対時間 (秒) で見た加速度ピーク時刻
    let peakTimeSec: Double
    /// ピーク加速度 (g)
    let peakMagnitude: Double
    /// ピークから加速度が指定比率まで低下した時刻（インパクトからの相対秒）。
    /// 低下しきる前にウィンドウが終わる場合は nil
    let decelerationOnsetTimeSec: Double?
}

enum SwingAnalyzer {

    /// ピークに対する減速開始判定の閾値比率（ピークの50%まで下がった最初の点を「減速開始」とみなす）
    static let decelerationThresholdRatio = 0.5

    /// サンプル列から簡易指標を計算する
    ///
    /// - Parameters:
    ///   - samples: タイムスタンプ昇順のサンプル列
    ///   - impactMs: インパクトのセンサータイムスタンプ（相対時間の原点）
    static func analyze(samples: [SwingSamplePoint], impactMs: Int64) -> SwingAnalysisResult? {
        guard !samples.isEmpty else { return nil }

        guard let peakIndex = samples.indices.max(by: {
            samples[$0].accelerationMagnitude < samples[$1].accelerationMagnitude
        }) else { return nil }

        let peakSample = samples[peakIndex]
        let peakMagnitude = peakSample.accelerationMagnitude
        let peakTimeSec = Double(peakSample.timestampMs - impactMs) / 1000.0

        let threshold = peakMagnitude * decelerationThresholdRatio
        let onsetSample = samples[(peakIndex + 1)...].first { $0.accelerationMagnitude <= threshold }
        let decelerationOnsetTimeSec = onsetSample.map { Double($0.timestampMs - impactMs) / 1000.0 }

        return SwingAnalysisResult(
            peakTimeSec: peakTimeSec,
            peakMagnitude: peakMagnitude,
            decelerationOnsetTimeSec: decelerationOnsetTimeSec
        )
    }
}
