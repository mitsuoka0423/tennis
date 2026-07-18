//
//  SwingDetectorTests.swift
//  TennisAnalyser Watch AppTests
//
//  SwingDetector（F-W3: スイング検知・ウィンドウ切り出し）のユニットテスト

import Foundation
import Testing
@testable import TennisAnalyser_Watch_App

struct SwingDetectorTests {

    // MARK: - Helpers

    /// 200Hz 相当（5ms間隔）のサンプルを生成する
    private func samples(
        fromMs start: Int64,
        toMs end: Int64,
        magnitude: Double = 1.0,
        intervalMs: Int64 = 5
    ) -> [MotionSample] {
        stride(from: start, through: end, by: Int64.Stride(intervalMs)).map { ts in
            MotionSample(
                timestampMs: ts,
                accX: magnitude, accY: 0, accZ: 0,
                gyroX: 0, gyroY: 0, gyroZ: 0,
                shotClass: nil
            )
        }
    }

    private func makeDetector(
        pre: Double = 2.0, post: Double = 2.0, threshold: Double = 3.0
    ) -> SwingDetector {
        SwingDetector(sessionId: "test-session", preSeconds: pre, postSeconds: post, threshold: threshold)
    }

    // MARK: - Tests

    @Test("閾値未満のサンプルのみではスイングは検知されない")
    func noSwingBelowThreshold() {
        let detector = makeDetector()
        let swings = detector.feed(samples(fromMs: 0, toMs: 10_000, magnitude: 1.0))
        #expect(swings.isEmpty)
    }

    @Test("インパクト後 post 窓が満ちるとスイングが1件確定する")
    func detectsSingleSwing() {
        let detector = makeDetector()
        var swings: [Swing] = []
        // 0〜3秒: 静穏
        swings += detector.feed(samples(fromMs: 0, toMs: 2_995))
        // 3秒地点: インパクト（1サンプルだけ 5g）
        swings += detector.feed(samples(fromMs: 3_000, toMs: 3_000, magnitude: 5.0))
        #expect(swings.isEmpty)  // post窓が満ちるまで未確定
        // 3.005〜5.5秒: 静穏（5秒 = 3+2秒 の windowEnd を超える）
        swings += detector.feed(samples(fromMs: 3_005, toMs: 5_500))

        #expect(swings.count == 1)
        let swing = try! #require(swings.first)
        #expect(swing.sequence == 1)
        #expect(swing.impactTimestampMs == 3_000)
        // ウィンドウ範囲: [1000, 5000]
        #expect(swing.samples.first?.timestampMs == 1_000)
        #expect(swing.samples.last?.timestampMs == 5_000)
        #expect(swing.peakAcceleration == 5.0)
    }

    @Test("セッション開始直後（pre 窓が不足）でも確定できる")
    func detectsSwingWithShortPreWindow() {
        let detector = makeDetector()
        var swings: [Swing] = []
        // 開始 0.5 秒でインパクト
        swings += detector.feed(samples(fromMs: 0, toMs: 495))
        swings += detector.feed(samples(fromMs: 500, toMs: 500, magnitude: 4.0))
        swings += detector.feed(samples(fromMs: 505, toMs: 2_600))

        #expect(swings.count == 1)
        // pre窓は存在する分のみ（0ms 起点）
        #expect(swings[0].samples.first?.timestampMs == 0)
        #expect(swings[0].samples.last?.timestampMs == 2_500)
    }

    @Test("ウィンドウ収集中の再インパクトは無視される（1スイングに統合）")
    func ignoresImpactDuringWindow() {
        let detector = makeDetector()
        var swings: [Swing] = []
        swings += detector.feed(samples(fromMs: 0, toMs: 2_995))
        // 3.0秒と3.5秒に2回の閾値超え（同一ウィンドウ内）
        swings += detector.feed(samples(fromMs: 3_000, toMs: 3_000, magnitude: 5.0))
        swings += detector.feed(samples(fromMs: 3_005, toMs: 3_495))
        swings += detector.feed(samples(fromMs: 3_500, toMs: 3_500, magnitude: 6.0))
        swings += detector.feed(samples(fromMs: 3_505, toMs: 5_500))

        #expect(swings.count == 1)
        #expect(swings[0].impactTimestampMs == 3_000)
    }

    @Test("ウィンドウ終了後の次のインパクトは別スイングとして検知される")
    func detectsConsecutiveSwings() {
        let detector = makeDetector()
        var swings: [Swing] = []
        swings += detector.feed(samples(fromMs: 0, toMs: 2_995))
        // 1本目: 3秒地点
        swings += detector.feed(samples(fromMs: 3_000, toMs: 3_000, magnitude: 5.0))
        swings += detector.feed(samples(fromMs: 3_005, toMs: 8_995))
        // 2本目: 9秒地点（1本目の windowEnd=5秒 より後）
        swings += detector.feed(samples(fromMs: 9_000, toMs: 9_000, magnitude: 4.5))
        swings += detector.feed(samples(fromMs: 9_005, toMs: 11_500))

        #expect(swings.count == 2)
        #expect(swings[0].sequence == 1)
        #expect(swings[0].impactTimestampMs == 3_000)
        #expect(swings[1].sequence == 2)
        #expect(swings[1].impactTimestampMs == 9_000)
    }

    @Test("1回の feed に複数スイングが含まれていてもすべて確定する")
    func detectsMultipleSwingsInSingleFeed() {
        let detector = makeDetector()
        // 3秒と9秒にインパクトを含む 0〜12秒 の一括バッチ
        var batch = samples(fromMs: 0, toMs: 12_000)
        batch = batch.map { s in
            if s.timestampMs == 3_000 || s.timestampMs == 9_000 {
                return MotionSample(
                    timestampMs: s.timestampMs,
                    accX: 5.0, accY: 0, accZ: 0,
                    gyroX: 0, gyroY: 0, gyroZ: 0, shotClass: nil
                )
            }
            return s
        }
        let swings = detector.feed(batch)
        #expect(swings.count == 2)
    }

    @Test("閾値・ウィンドウ秒数は設定で調整可能")
    func configurableParameters() {
        let detector = makeDetector(pre: 1.0, post: 0.5, threshold: 2.0)
        var swings: [Swing] = []
        swings += detector.feed(samples(fromMs: 0, toMs: 2_995))
        swings += detector.feed(samples(fromMs: 3_000, toMs: 3_000, magnitude: 2.5))  // 2.0g 閾値なら検知
        swings += detector.feed(samples(fromMs: 3_005, toMs: 3_600))

        #expect(swings.count == 1)
        // ウィンドウ範囲: [2000, 3500]
        #expect(swings[0].samples.first?.timestampMs == 2_000)
        #expect(swings[0].samples.last?.timestampMs == 3_500)
    }

    @Test("detectedAt はインパクトの壁時計時刻に逆算される")
    func detectedAtIsBackdated() {
        let detector = makeDetector()
        let now = Date(timeIntervalSince1970: 1_000_000)
        var swings: [Swing] = []
        swings += detector.feed(samples(fromMs: 0, toMs: 2_995), now: now)
        swings += detector.feed(samples(fromMs: 3_000, toMs: 3_000, magnitude: 5.0), now: now)
        // 確定時点の最新サンプルは 5500ms → インパクト(3000ms)との差 2.5秒 だけ過去に補正
        swings += detector.feed(samples(fromMs: 3_005, toMs: 5_500), now: now)

        #expect(swings.count == 1)
        #expect(abs(swings[0].detectedAt.timeIntervalSince(now) - (-2.5)) < 0.001)
    }
}
