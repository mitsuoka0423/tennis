//
//  MockMotionSensorRepository.swift
//  TennisAnalyser Watch App
//
//  Infrastructure — シミュレータ / プレビュー用の疑似センサーデータ実装
//
//  実機不要で UI / ViewModel / UseCase の動作確認に使用する。
//  サイン波ベースの加速度・角速度を指定 Hz で生成して流す。

import Foundation

/// シミュレータ向け疑似センサーデータ生成の `MotionSensorRepository` 実装
///
/// - targetHz をそのまま使用（上限なし）
/// - 加速度: X 軸にサイン波（振幅 1g）、Y/Z にオフセット
/// - 角速度: Z 軸にコサイン波（振幅 90°/s）
/// - 連続スイングを模擬するため 3g 超のパルスを 2 秒ごとに発生させる
final class MockMotionSensorRepository: MotionSensorRepository {

    // MARK: - State

    private var samplingTask: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<[MotionSample], Error>.Continuation?

    // MARK: - MotionSensorRepository

    func startSampling(targetHz: Int) -> AsyncThrowingStream<[MotionSample], Error> {
        AsyncThrowingStream { [weak self] continuation in
            guard let self else {
                continuation.finish(throwing: MotionSensorError.managerUnavailable)
                return
            }
            self.continuation = continuation

            let hz = max(1, targetHz)
            let intervalNs = UInt64(1_000_000_000 / hz)

            self.samplingTask = Task {
                var tick: Int = 0
                let startTime = Date()

                while !Task.isCancelled {
                    let elapsed = Date().timeIntervalSince(startTime)
                    let sample = Self.makeSample(tick: tick, elapsedSeconds: elapsed)
                    continuation.yield([sample])
                    tick += 1

                    do {
                        try await Task.sleep(nanoseconds: intervalNs)
                    } catch {
                        break // キャンセル
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { [weak self] _ in
                self?.samplingTask?.cancel()
                self?.samplingTask = nil
            }
        }
    }

    func stopSampling() {
        samplingTask?.cancel()
        samplingTask = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Private

    /// tick と経過時間から疑似 MotionSample を生成する
    private static func makeSample(tick: Int, elapsedSeconds: Double) -> MotionSample {
        let t = elapsedSeconds
        let twoPi = Double.pi * 2

        // 基本波形（1Hz のサイン波）
        let baseAcc = sin(twoPi * 1.0 * t)

        // 2 秒ごとにスイングパルスを発生（振幅 4g）
        let swingPhase = t.truncatingRemainder(dividingBy: 2.0)
        let swingPulse = swingPhase < 0.05 ? 4.0 * sin(Double.pi * swingPhase / 0.05) : 0.0

        let accX = baseAcc + swingPulse
        let accY = 0.2 * cos(twoPi * 0.5 * t)
        let accZ = -1.0 + 0.1 * sin(twoPi * 2.0 * t) // -1g は重力成分

        let gyroX = 30.0 * sin(twoPi * 1.0 * t)
        let gyroY = 15.0 * cos(twoPi * 0.8 * t)
        let gyroZ = 90.0 * cos(twoPi * 1.0 * t) + (swingPulse != 0 ? 200.0 : 0.0)

        return MotionSample(
            timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
            accX:  accX,
            accY:  accY,
            accZ:  accZ,
            gyroX: gyroX,
            gyroY: gyroY,
            gyroZ: gyroZ,
            shotClass: nil
        )
    }
}
