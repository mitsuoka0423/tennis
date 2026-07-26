//
//  SensorMonitorViewModelTests.swift
//  TennisAnalyser Watch AppTests
//

import Testing
import Foundation
@testable import TennisAnalyser_Watch_App

@MainActor
struct SensorMonitorViewModelTests {

    // MARK: - サンプリングの開始と停止

    // 正常系: start() でサンプリングが始まり isRunning が true になること
    @Test func startBeginsSampling() async throws {
        let repository = FakeMotionSensorRepository()
        let viewModel = SensorMonitorViewModel(repository: repository)

        viewModel.start()

        #expect(viewModel.isRunning)
        #expect(await waitUntil { repository.isStreaming })
    }

    // 正常系: stop() でサンプリングが止まり、リポジトリへ停止が伝わること
    @Test func stopEndsSampling() async throws {
        let repository = FakeMotionSensorRepository()
        let viewModel = SensorMonitorViewModel(repository: repository)
        viewModel.start()
        #expect(await waitUntil { repository.isStreaming })

        viewModel.stop()

        #expect(!viewModel.isRunning)
        #expect(repository.stopCallCount == 1)
    }

    // MARK: - 時系列

    // 正常系: 加速度・角速度が軸ごとに時系列へ積まれること（合成しない）
    @Test func tracesAreRecordedPerAxis() async throws {
        let repository = FakeMotionSensorRepository()
        let viewModel = SensorMonitorViewModel(repository: repository)
        viewModel.start()
        #expect(await waitUntil { repository.isStreaming })

        repository.emit([
            sample(accX: 0.1, accY: 0.2, accZ: 0.3, gyroX: 10, gyroY: 20, gyroZ: 30)
        ])

        #expect(await waitUntil { !viewModel.accelerationTrace.isEmpty })
        #expect(viewModel.accelerationTrace.x.last == 0.1)
        #expect(viewModel.accelerationTrace.y.last == 0.2)
        #expect(viewModel.accelerationTrace.z.last == 0.3)
        #expect(viewModel.rotationTrace.x.last == 10)
        #expect(viewModel.rotationTrace.y.last == 20)
        #expect(viewModel.rotationTrace.z.last == 30)
    }

    // 正常系: 表示更新の間引き期間中に届いたサンプルも時系列に残ること
    //
    // 画面更新は間引くが、波形そのものが間引かれると動きの形が変わってしまう
    @Test func traceKeepsSamplesDroppedByDisplayThrottling() async throws {
        let repository = FakeMotionSensorRepository()
        let viewModel = SensorMonitorViewModel(repository: repository)
        viewModel.start()
        #expect(await waitUntil { repository.isStreaming })

        // 1件目は即時に公開される（前回公開時刻が未設定のため）
        repository.emit([sample(accX: 0.1)])
        #expect(await waitUntil { viewModel.accelerationTrace.x.count == 1 })

        // 間引き期間中に届くため、この2件では公開が起きない
        repository.emit([sample(accX: 0.2)])
        repository.emit([sample(accX: 0.3)])
        try await Task.sleep(nanoseconds: 100_000_000)

        // 間引き期間明けの1件で公開が起きる
        repository.emit([sample(accX: 0.4)])

        #expect(await waitUntil { viewModel.accelerationTrace.x.count == 4 })
        #expect(viewModel.accelerationTrace.x == [0.1, 0.2, 0.3, 0.4])
    }

    // 正常系: 保持点数を超えたら古い点から捨てられること
    @Test func traceDropsOldestBeyondCapacity() async throws {
        let repository = FakeMotionSensorRepository()
        let viewModel = SensorMonitorViewModel(repository: repository)
        viewModel.start()
        #expect(await waitUntil { repository.isStreaming })

        let capacity = viewModel.traceCapacity
        let overflow = 10
        let batch = (0..<(capacity + overflow)).map { sample(accX: Double($0)) }
        repository.emit(batch)

        #expect(await waitUntil { viewModel.accelerationTrace.x.count == capacity })
        // 先頭は捨てられ、最新は末尾に残る
        #expect(viewModel.accelerationTrace.x.first == Double(overflow))
        #expect(viewModel.accelerationTrace.x.last == Double(capacity + overflow - 1))
    }

    // 正常系: 停止後に再開すると時系列がリセットされること
    @Test func restartClearsTrace() async throws {
        let repository = FakeMotionSensorRepository()
        let viewModel = SensorMonitorViewModel(repository: repository)
        viewModel.start()
        #expect(await waitUntil { repository.isStreaming })
        repository.emit([sample(accX: 1.0)])
        #expect(await waitUntil { !viewModel.accelerationTrace.isEmpty })

        viewModel.stop()
        viewModel.start()

        #expect(viewModel.accelerationTrace.isEmpty)
        #expect(viewModel.rotationTrace.isEmpty)
        #expect(viewModel.latest == nil)
    }

    // MARK: - 縦軸スケール

    // 正常系: 振幅が下限に収まる間は縦軸スケールが下限のままであること
    @Test func scaleStaysAtMinimumForSmallAmplitude() async throws {
        let repository = FakeMotionSensorRepository()
        let viewModel = SensorMonitorViewModel(repository: repository)
        viewModel.start()
        #expect(await waitUntil { repository.isStreaming })

        repository.emit([sample(accX: 1.0, gyroX: 100)])

        #expect(await waitUntil { !viewModel.accelerationTrace.isEmpty })
        #expect(viewModel.accelerationScale == SensorChartScale.accelerationMinimum)
        #expect(viewModel.rotationScale == SensorChartScale.rotationMinimum)
    }

    // 正常系: 下限を超える振幅が届くと縦軸スケールが広がること
    @Test func scaleGrowsWithAmplitude() async throws {
        let repository = FakeMotionSensorRepository()
        let viewModel = SensorMonitorViewModel(repository: repository)
        viewModel.start()
        #expect(await waitUntil { repository.isStreaming })

        repository.emit([sample(accX: -10, gyroX: 1200)])

        #expect(await waitUntil { viewModel.accelerationScale == 20 })
        #expect(viewModel.rotationScale == 2000)
    }

    // 正常系: 大きな振幅が表示範囲から流れ去ると縦軸スケールが下限へ戻ること
    @Test func scaleShrinksAfterPeakLeavesWindow() async throws {
        let repository = FakeMotionSensorRepository()
        let viewModel = SensorMonitorViewModel(repository: repository)
        viewModel.start()
        #expect(await waitUntil { repository.isStreaming })
        repository.emit([sample(accX: 10)])
        #expect(await waitUntil { viewModel.accelerationScale == 20 })

        // 表示更新の間引き明けに、保持点数ぶんの小さな値で押し出す
        try await Task.sleep(nanoseconds: 100_000_000)
        repository.emit((0..<viewModel.traceCapacity).map { _ in sample(accX: 0.5) })

        #expect(
            await waitUntil {
                viewModel.accelerationScale == SensorChartScale.accelerationMinimum
            }
        )
    }

    // 正常系: 停止後に再開すると縦軸スケールが下限へ戻ること
    @Test func restartResetsScale() async throws {
        let repository = FakeMotionSensorRepository()
        let viewModel = SensorMonitorViewModel(repository: repository)
        viewModel.start()
        #expect(await waitUntil { repository.isStreaming })
        repository.emit([sample(accX: 10)])
        #expect(await waitUntil { viewModel.accelerationScale == 20 })

        viewModel.stop()
        viewModel.start()

        #expect(viewModel.accelerationScale == SensorChartScale.accelerationMinimum)
        #expect(viewModel.rotationScale == SensorChartScale.rotationMinimum)
    }

    // MARK: - Helpers

    private func sample(
        accX: Double = 0, accY: Double = 0, accZ: Double = 0,
        gyroX: Double = 0, gyroY: Double = 0, gyroZ: Double = 0
    ) -> MotionSample {
        MotionSample(
            timestampMs: 0,
            accX: accX, accY: accY, accZ: accZ,
            gyroX: gyroX, gyroY: gyroY, gyroZ: gyroZ,
            shotClass: nil
        )
    }

    /// 条件が満たされるまで待つ。非同期に届くサンプルの反映を待ち合わせる
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}

// MARK: - 縦軸スケールの算出

struct SensorChartScaleTests {

    // 正常系: 振幅が下限に収まる場合は下限を返すこと（波形が無い場合を含む）
    @Test func returnsMinimumForSmallPeak() {
        #expect(SensorChartScale.fit(peak: 0, minimum: 4) == 4)
        #expect(SensorChartScale.fit(peak: 3.4, minimum: 4) == 4)
    }

    // 正常系: 1・2・5 の梯子へ切り上げること（余白 15% を含めて判定する）
    @Test func roundsUpToLadder() {
        #expect(SensorChartScale.fit(peak: 4.2, minimum: 4) == 5)
        #expect(SensorChartScale.fit(peak: 6, minimum: 4) == 10)
        #expect(SensorChartScale.fit(peak: 10, minimum: 4) == 20)
        #expect(SensorChartScale.fit(peak: 1200, minimum: 500) == 2000)
        #expect(SensorChartScale.fit(peak: 2000, minimum: 500) == 5000)
    }

    // 正常系: 上限を設けず、桁が増えても切り上げ先があること
    @Test func hasNoUpperBound() {
        #expect(SensorChartScale.fit(peak: 80_000, minimum: 500) == 100_000)
    }

    // 準正常系: 余白を足すと梯子の先頭を超える場合、次の桁へ繰り上がること
    @Test func carriesToNextDecade() {
        // 5.0 * 1.15 = 5.75 は 5 に収まらないため 10 へ上がる
        #expect(SensorChartScale.fit(peak: 5, minimum: 4) == 10)
    }
}

// MARK: - Test Double

/// テストから任意のタイミングでサンプルを流せる `MotionSensorRepository`
private final class FakeMotionSensorRepository: MotionSensorRepository {

    private var continuation: AsyncThrowingStream<[MotionSample], Error>.Continuation?
    private(set) var stopCallCount = 0

    /// ストリームが確立され、`emit` を受け付けられる状態か
    var isStreaming: Bool { continuation != nil }

    func startSampling(targetHz: Int) -> AsyncThrowingStream<[MotionSample], Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
        }
    }

    func stopSampling() {
        stopCallCount += 1
        continuation?.finish()
        continuation = nil
    }

    func emit(_ samples: [MotionSample]) {
        continuation?.yield(samples)
    }
}
