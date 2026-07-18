//
//  SwingAnalyzerTests.swift
//  TennisAnalyserTests
//
//  SwingAnalyzer（F-I4: 解析エンジンの基礎）のユニットテスト

import Foundation
import Testing
@testable import TennisAnalyser

struct SwingAnalyzerTests {

    private func sample(ms: Int64, magnitude: Double) -> SwingSamplePoint {
        // accelerationMagnitude = sqrt(x^2) となるよう X 軸のみに値を入れる
        SwingSamplePoint(timestampMs: ms, accX: magnitude, accY: 0, accZ: 0, gyroX: 0, gyroY: 0, gyroZ: 0)
    }

    @Test("空配列では nil を返す")
    func returnsNilForEmptySamples() {
        #expect(SwingAnalyzer.analyze(samples: [], impactMs: 0) == nil)
    }

    @Test("ピーク時刻とピーク値を正しく検出する")
    func detectsPeak() {
        let samples = [
            sample(ms: 1_000, magnitude: 1.0),
            sample(ms: 1_100, magnitude: 4.0),  // peak
            sample(ms: 1_200, magnitude: 2.0),
        ]
        let result = SwingAnalyzer.analyze(samples: samples, impactMs: 1_000)
        #expect(result?.peakMagnitude == 4.0)
        #expect(result?.peakTimeSec == 0.1)
    }

    @Test("ピークの50%まで低下した最初の時刻を減速開始とみなす")
    func detectsDecelerationOnset() {
        let samples = [
            sample(ms: 1_000, magnitude: 1.0),
            sample(ms: 1_100, magnitude: 4.0),  // peak
            sample(ms: 1_150, magnitude: 3.0),  // 75% (閾値未満ではない)
            sample(ms: 1_200, magnitude: 1.5),  // 37.5% (閾値=2.0 を下回る)
            sample(ms: 1_250, magnitude: 0.5),
        ]
        let result = SwingAnalyzer.analyze(samples: samples, impactMs: 1_000)
        #expect(result?.decelerationOnsetTimeSec == 0.2)
    }

    @Test("ウィンドウ末尾まで閾値を下回らない場合は nil")
    func returnsNilWhenNoDecelerationWithinWindow() {
        let samples = [
            sample(ms: 1_000, magnitude: 1.0),
            sample(ms: 1_100, magnitude: 4.0),  // peak
            sample(ms: 1_200, magnitude: 3.9),
        ]
        let result = SwingAnalyzer.analyze(samples: samples, impactMs: 1_000)
        #expect(result?.decelerationOnsetTimeSec == nil)
    }

    @Test("インパクトより前にピークがある場合は負の相対時間になる")
    func peakBeforeImpactYieldsNegativeTime() {
        let samples = [
            sample(ms: 900, magnitude: 5.0),   // peak（インパクト前）
            sample(ms: 1_000, magnitude: 3.0), // インパクト
            sample(ms: 1_100, magnitude: 1.0),
        ]
        let result = SwingAnalyzer.analyze(samples: samples, impactMs: 1_000)
        #expect(result?.peakTimeSec == -0.1)
    }
}
