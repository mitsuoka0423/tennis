//
//  PracticeVideoTests.swift
//  TennisAnalyserTests
//
//  PracticeVideo（F-I6: 時刻マッチング）のユニットテスト

import Foundation
import Testing
@testable import TennisAnalyser

struct PracticeVideoTests {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func video(durationSec: TimeInterval = 60, ended: Bool = true) -> PracticeVideo {
        PracticeVideo(
            id: "v1",
            startedAt: start,
            endedAt: ended ? start.addingTimeInterval(durationSec) : nil,
            fileName: "v1.mov"
        )
    }

    @Test("録画範囲内の時刻は contains が true を返す")
    func containsWithinRange() {
        let v = video(durationSec: 60)
        #expect(v.contains(start.addingTimeInterval(30)))
        #expect(v.contains(start))            // 開始丁度
        #expect(v.contains(start.addingTimeInterval(60)))  // 終了丁度
    }

    @Test("録画範囲外の時刻は contains が false を返す")
    func containsOutsideRange() {
        let v = video(durationSec: 60)
        #expect(!v.contains(start.addingTimeInterval(-1)))
        #expect(!v.contains(start.addingTimeInterval(61)))
    }

    @Test("録画中（endedAt が nil）は常に false")
    func containsFalseWhileRecording() {
        let v = video(ended: false)
        #expect(!v.contains(start.addingTimeInterval(10)))
    }

    @Test("offsetSeconds は開始時刻からの経過秒数を返す")
    func offsetSecondsComputesElapsed() {
        let v = video(durationSec: 60)
        #expect(v.offsetSeconds(for: start.addingTimeInterval(12.5)) == 12.5)
    }

    @Test("範囲外の時刻には offsetSeconds が nil を返す")
    func offsetSecondsNilOutsideRange() {
        let v = video(durationSec: 60)
        #expect(v.offsetSeconds(for: start.addingTimeInterval(100)) == nil)
    }
}
