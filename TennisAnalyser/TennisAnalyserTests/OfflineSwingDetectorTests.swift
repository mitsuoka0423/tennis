//
//  OfflineSwingDetectorTests.swift
//  TennisAnalyserTests
//
//  OfflineSwingDetector（W6-T15: 連続記録からのスイング候補抽出）のユニットテスト

import Foundation
import Testing
@testable import TennisAnalyser

struct OfflineSwingDetectorTests {

    // MARK: - Helpers

    /// 5ms 間隔（200Hz）で加速度の大きさを与えたサンプル列を作る
    ///
    /// - Parameter magnitudes: 各サンプルの加速度の大きさ (g)。X軸のみに乗せる
    private func makeSamples(
        magnitudes: [Double],
        startMs: Int64 = 0,
        gyroMagnitude: Double = 500
    ) -> [SwingSamplePoint] {
        magnitudes.enumerated().map { index, magnitude in
            SwingSamplePoint(
                timestampMs: startMs + Int64(index * 5),
                accX: magnitude, accY: 0, accZ: 0,
                gyroX: gyroMagnitude, gyroY: 0, gyroZ: 0
            )
        }
    }

    /// 静止（0.1g）の中に1発のピークを置いた波形
    private func makeImpact(peak: Double, leadingRest: Int, trailingRest: Int) -> [Double] {
        Array(repeating: 0.1, count: leadingRest)
            + [peak * 0.6, peak, peak * 0.5]
            + Array(repeating: 0.1, count: trailingRest)
    }

    // MARK: - 検知

    // 正常系: 閾値を超えたピーク1発が候補1件として抽出されること
    @Test func detectsSingleImpact() {
        let samples = makeSamples(
            magnitudes: makeImpact(peak: 8.0, leadingRest: 100, trailingRest: 200)
        )
        var rearm: Int64?

        let candidates = OfflineSwingDetector.detect(
            samples: samples, parameters: OfflineDetectorParameters(), rearmAfterSensorMs: &rearm
        )

        #expect(candidates.count == 1)
        #expect(candidates[0].peakAcceleration == 8.0)
    }

    // 正常系: 候補の位置が閾値超過点ではなく加速度が最大のサンプルであること
    @Test func snapsImpactToPeakSample() {
        // 3.5g で超過し、その 10ms 後（2サンプル後）に 9.0g のピークが来る
        let samples = makeSamples(
            magnitudes: Array(repeating: 0.1, count: 50) + [3.5, 5.0, 9.0, 4.0]
                + Array(repeating: 0.1, count: 50)
        )
        var rearm: Int64?

        let candidates = OfflineSwingDetector.detect(
            samples: samples, parameters: OfflineDetectorParameters(), rearmAfterSensorMs: &rearm
        )

        #expect(candidates.count == 1)
        #expect(candidates[0].impactSensorMs == 52 * 5)
        #expect(candidates[0].peakAcceleration == 9.0)
    }

    // 正常系: 閾値未満の波形からは候補が出ないこと
    @Test func ignoresBelowThreshold() {
        let samples = makeSamples(
            magnitudes: makeImpact(peak: 2.5, leadingRest: 50, trailingRest: 50)
        )
        var rearm: Int64?

        let candidates = OfflineSwingDetector.detect(
            samples: samples, parameters: OfflineDetectorParameters(), rearmAfterSensorMs: &rearm
        )

        #expect(candidates.isEmpty)
    }

    // 正常系: 0.6秒間隔の連続ショットが2件とも抽出されること
    //（Watch 実装は不感時間2秒のため取りこぼしていた。W5-T11 の課題の回帰テスト）
    @Test func detectsConsecutiveImpactsWithinTwoSeconds() {
        // 0.6秒 = 120サンプル間隔で2発
        let magnitudes = makeImpact(peak: 8.0, leadingRest: 20, trailingRest: 117)
            + makeImpact(peak: 7.0, leadingRest: 0, trailingRest: 100)
        let samples = makeSamples(magnitudes: magnitudes)
        var rearm: Int64?

        let candidates = OfflineSwingDetector.detect(
            samples: samples, parameters: OfflineDetectorParameters(), rearmAfterSensorMs: &rearm
        )

        #expect(candidates.count == 2)
        #expect(candidates[1].impactSensorMs - candidates[0].impactSensorMs == 600)
    }

    // 正常系: 不感時間中の超過は候補にならないこと（インパクト直後の残響を潰す）
    @Test func suppressesImpactsWithinRearmWindow() {
        // 50ms（10サンプル）間隔で2発 = 既定の不感時間 0.4 秒より短い
        let magnitudes = makeImpact(peak: 8.0, leadingRest: 20, trailingRest: 7)
            + makeImpact(peak: 6.0, leadingRest: 0, trailingRest: 100)
        let samples = makeSamples(magnitudes: magnitudes)
        var rearm: Int64?

        let candidates = OfflineSwingDetector.detect(
            samples: samples, parameters: OfflineDetectorParameters(), rearmAfterSensorMs: &rearm
        )

        #expect(candidates.count == 1)
        #expect(candidates[0].peakAcceleration == 8.0)
    }

    // 正常系: 不感時間を短くすると同じ波形からより多くの候補が出ること（事後調整の担保）
    @Test func rearmSecondsIsAdjustable() {
        let magnitudes = makeImpact(peak: 8.0, leadingRest: 20, trailingRest: 7)
            + makeImpact(peak: 6.0, leadingRest: 0, trailingRest: 100)
        let samples = makeSamples(magnitudes: magnitudes)

        var strictRearm: Int64?
        let fewer = OfflineSwingDetector.detect(
            samples: samples,
            parameters: OfflineDetectorParameters(rearmSeconds: 0.4),
            rearmAfterSensorMs: &strictRearm
        )
        var looseRearm: Int64?
        let more = OfflineSwingDetector.detect(
            samples: samples,
            parameters: OfflineDetectorParameters(rearmSeconds: 0.02),
            rearmAfterSensorMs: &looseRearm
        )

        #expect(fewer.count == 1)
        #expect(more.count == 2)
    }

    // 正常系: 閾値を上げると候補が減ること（事後調整の担保）
    @Test func thresholdIsAdjustable() {
        let magnitudes = makeImpact(peak: 3.5, leadingRest: 20, trailingRest: 200)
            + makeImpact(peak: 9.0, leadingRest: 0, trailingRest: 100)
        let samples = makeSamples(magnitudes: magnitudes)

        var lowRearm: Int64?
        let low = OfflineSwingDetector.detect(
            samples: samples,
            parameters: OfflineDetectorParameters(accelerationThreshold: 3.0),
            rearmAfterSensorMs: &lowRearm
        )
        var highRearm: Int64?
        let high = OfflineSwingDetector.detect(
            samples: samples,
            parameters: OfflineDetectorParameters(accelerationThreshold: 5.0),
            rearmAfterSensorMs: &highRearm
        )

        #expect(low.count == 2)
        #expect(high.count == 1)
        #expect(high[0].peakAcceleration == 9.0)
    }

    // MARK: - 角速度ゲート

    // 正常系: 角速度ゲートが下限未満の候補を落とすこと
    @Test func gyroGateRejectsLowRotation() {
        let samples = makeSamples(
            magnitudes: makeImpact(peak: 8.0, leadingRest: 50, trailingRest: 50),
            gyroMagnitude: 100
        )
        var rearm: Int64?

        let candidates = OfflineSwingDetector.detect(
            samples: samples,
            parameters: OfflineDetectorParameters(minGyroPeakDegPerSec: 300),
            rearmAfterSensorMs: &rearm
        )

        #expect(candidates.isEmpty)
    }

    // 正常系: ゲート既定（無効）では角速度が小さくても候補として残ること
    @Test func gyroGateDisabledByDefault() {
        let samples = makeSamples(
            magnitudes: makeImpact(peak: 8.0, leadingRest: 50, trailingRest: 50),
            gyroMagnitude: 100
        )
        var rearm: Int64?

        let candidates = OfflineSwingDetector.detect(
            samples: samples, parameters: OfflineDetectorParameters(), rearmAfterSensorMs: &rearm
        )

        #expect(candidates.count == 1)
        #expect(candidates[0].gyroPeak == 100)
    }

    // MARK: - チャンクの引き継ぎ

    // 正常系: 不感時間がチャンク境界を越えて引き継がれること
    @Test func carriesRearmAcrossChunks() {
        let firstChunk = makeSamples(
            magnitudes: makeImpact(peak: 8.0, leadingRest: 20, trailingRest: 0)
        )
        // 前チャンク末尾のインパクトから 50ms 後（不感時間内）に超過するチャンク
        let secondChunk = makeSamples(
            magnitudes: makeImpact(peak: 6.0, leadingRest: 8, trailingRest: 50),
            startMs: firstChunk.last!.timestampMs + 5
        )
        var rearm: Int64?

        let first = OfflineSwingDetector.detect(
            samples: firstChunk, parameters: OfflineDetectorParameters(), rearmAfterSensorMs: &rearm
        )
        let second = OfflineSwingDetector.detect(
            samples: secondChunk, parameters: OfflineDetectorParameters(), rearmAfterSensorMs: &rearm
        )

        #expect(first.count == 1)
        #expect(second.isEmpty)
    }
}
