//
//  SensorMonitorViewModel.swift
//  TennisAnalyser Watch App
//
//  Presentation ViewModel — センサー値のリアルタイム時系列表示（F-W9 デモ）

import Foundation
import Combine
import SwiftUI

/// 3軸ぶんの時系列。古い順に並ぶ
struct AxisTrace: Equatable {
    var x: [Double] = []
    var y: [Double] = []
    var z: [Double] = []

    var isEmpty: Bool { x.isEmpty }

    /// 3軸を通した絶対値の最大。縦軸スケールの決定に使う
    var peakMagnitude: Double {
        [x, y, z].compactMap { $0.lazy.map(abs).max() }.max() ?? 0
    }

    /// 末尾へ1点ずつ追加し、`capacity` を超えた古い点を捨てる
    mutating func append(x newX: Double, y newY: Double, z newZ: Double, capacity: Int) {
        x.append(newX)
        y.append(newY)
        z.append(newZ)
        if x.count > capacity {
            let overflow = x.count - capacity
            x.removeFirst(overflow)
            y.removeFirst(overflow)
            z.removeFirst(overflow)
        }
    }
}

// MARK: - 縦軸スケール

/// 波形の縦軸スケール
///
/// **調整するのはここ。** 表示中の波形の最大振幅に合わせて自動で決まる。
/// 下限は 2026-07-21 の実測分布に基づき、通常の素振りが収まる範囲を残した
/// （合成加速度の中央値 7g・p90 22g。軸ごとに分けると通常の素振りは ±4g 前後）。
/// 上限は設けない。振り切れた波形を見せないことを優先する。
enum SensorChartScale {
    /// 加速度の下限 (±g)
    static let accelerationMinimum: Double = 4
    /// 角速度の下限 (±°/s)
    static let rotationMinimum: Double = 500

    /// 最大振幅に対する余白。線が枠へ張り付いて見えるのを避ける
    private static let headroom: Double = 1.15

    /// 切り上げ先の候補（10の冪との積で 1・2・5・10・20・50… の梯子になる）
    private static let steps: [Double] = [1, 2, 5]

    /// 最大振幅に合う縦軸スケールを返す
    ///
    /// Why not 振幅へ連続的に追従させる: 目盛りが常時わずかに伸縮し、
    /// 波形が呼吸しているように見えて動きの大小が読めなくなる。
    /// 1・2・5 の梯子へ切り上げ、段が変わるときだけ目盛りを動かす。
    ///
    /// - Parameters:
    ///   - peak: 表示中の波形の絶対値の最大
    ///   - minimum: これ以上は縮めない下限
    static func fit(peak: Double, minimum: Double) -> Double {
        let required = peak * headroom
        guard required.isFinite, required > minimum else { return minimum }

        let decade = pow(10, floor(log10(required)))
        for step in steps where step * decade >= required {
            return max(step * decade, minimum)
        }
        return max(10 * decade, minimum)
    }

    static func accelerationLabel(_ scale: Double) -> String {
        String(format: "±%.0fg", scale)
    }

    static func rotationLabel(_ scale: Double) -> String {
        String(format: "±%.0f", scale)
    }
}

/// センサー値を軸ごとの時系列としてリアルタイムに流す ViewModel
///
/// 責務:
/// - `MotionSensorRepository` から届くサンプルを軸ごとの時系列として保持する
/// - 画面更新を一定間隔へ間引く（サンプル到着ごとの再描画を避ける）
/// - 表示中の波形に合う縦軸スケールを決める
/// - 実測サンプリングレートを1秒窓で算出する
///
/// 保存も転送も行わない。画面を開いている間だけ動く。
@MainActor
final class SensorMonitorViewModel: ObservableObject {

    // MARK: - Published State

    /// 加速度3軸の時系列 (g)
    @Published private(set) var accelerationTrace = AxisTrace()
    /// 角速度3軸の時系列 (°/s)
    @Published private(set) var rotationTrace = AxisTrace()
    /// 加速度の縦軸スケール (±g)。表示中の波形に合わせて自動で決まる
    @Published private(set) var accelerationScale = SensorChartScale.accelerationMinimum
    /// 角速度の縦軸スケール (±°/s)。表示中の波形に合わせて自動で決まる
    @Published private(set) var rotationScale = SensorChartScale.rotationMinimum
    /// 最新サンプル。数値表示に使う
    @Published private(set) var latest: MotionSample?
    /// 直近1秒の実測サンプリングレート (Hz)
    @Published private(set) var measuredHz: Double = 0
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var errorMessage: String?

    // MARK: - Configuration

    /// 目標サンプリングレート (Hz)
    ///
    /// 波形の滑らかさに直結する。`CMMotionManager` はハードウェア上限まで
    /// 指定でき、watchOS では 100Hz 程度まで出るが、描画点数が増えるほど
    /// Watch の再描画が重くなるため 50Hz とした。
    let targetHz: Int = 50

    /// 画面へ残す時間の長さ (秒)
    ///
    /// 素振り1回（約0.5秒）が横幅の1/6程度に収まる長さ。長くすると
    /// 1回の動作が細くなり、短くすると流れが速すぎて追えない。
    let windowSeconds: TimeInterval = 3.0

    /// 画面更新の間隔 (秒)
    ///
    /// Why not サンプルごとに更新する: 50Hz で `@Published` を更新すると
    /// SwiftUI の再描画が追いつかず、Watch では発熱とコマ落ちを招く。
    /// デモでは滑らかさが要るため 20Hz とした（数値表示だけなら 10Hz で足りる）。
    private static let publishInterval: TimeInterval = 0.05

    /// 時系列として保持する点数。波形の横軸の目盛りとして View も参照する
    var traceCapacity: Int {
        Int(windowSeconds * Double(targetHz))
    }

    // MARK: - Private

    private let repository: any MotionSensorRepository
    private var samplingTask: Task<Void, Never>?

    /// 描画用に蓄積中の時系列。`publishInterval` ごとに `@Published` へ反映する
    ///
    /// Why not `@Published` を直接更新する: 1サンプルごとに published を
    /// 書き換えると、間引きの意味がなくなり再描画が 50Hz で走る。
    private var bufferedAcceleration = AxisTrace()
    private var bufferedRotation = AxisTrace()

    private var lastPublishedAt: Date = .distantPast
    /// 実測Hz算出用の1秒窓
    private var windowStartedAt: Date = .distantPast
    private var samplesInWindow: Int = 0

    // MARK: - Init

    /// - Parameter repository: 省略時はシミュレータでモック、実機で `CMMotionManager` 実装を使う
    init(repository: (any MotionSensorRepository)? = nil) {
        if let repository {
            self.repository = repository
        } else {
            let isSimulator = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil
            self.repository = isSimulator
                ? MockMotionSensorRepository()
                : LiveMotionSensorRepositoryImpl()
        }
    }

    // MARK: - Public API

    func start() {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        reset()

        samplingTask = Task.detached { [weak self] in
            guard let self else { return }
            let stream = await self.repository.startSampling(targetHz: await self.targetHz)
            do {
                for try await batch in stream {
                    await self.receive(batch)
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isRunning = false
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        repository.stopSampling()
        samplingTask?.cancel()
        samplingTask = nil
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - Private

    private func reset() {
        accelerationTrace = AxisTrace()
        rotationTrace = AxisTrace()
        accelerationScale = SensorChartScale.accelerationMinimum
        rotationScale = SensorChartScale.rotationMinimum
        bufferedAcceleration = AxisTrace()
        bufferedRotation = AxisTrace()
        latest = nil
        measuredHz = 0
        samplesInWindow = 0
        lastPublishedAt = .distantPast
        windowStartedAt = Date()
    }

    /// 届いたサンプルを時系列へ積み、表示間隔に達していれば画面へ反映する
    private func receive(_ batch: [MotionSample]) {
        guard let last = batch.last else { return }

        for sample in batch {
            bufferedAcceleration.append(
                x: sample.accX, y: sample.accY, z: sample.accZ, capacity: traceCapacity
            )
            bufferedRotation.append(
                x: sample.gyroX, y: sample.gyroY, z: sample.gyroZ, capacity: traceCapacity
            )
        }
        samplesInWindow += batch.count

        let now = Date()
        guard now.timeIntervalSince(lastPublishedAt) >= Self.publishInterval else { return }
        lastPublishedAt = now

        accelerationTrace = bufferedAcceleration
        rotationTrace = bufferedRotation
        latest = last

        // Why not ピークを別に保持して時間で減衰させる: 時系列は3秒で入れ替わるため、
        // 表示中の点だけを見れば大きな山が画面から消えた時点でスケールも下がる。
        accelerationScale = SensorChartScale.fit(
            peak: bufferedAcceleration.peakMagnitude,
            minimum: SensorChartScale.accelerationMinimum
        )
        rotationScale = SensorChartScale.fit(
            peak: bufferedRotation.peakMagnitude,
            minimum: SensorChartScale.rotationMinimum
        )

        // 実測Hz は1秒窓で確定させる。窓が短いと1サンプルの増減で値が跳ねて読めない
        let windowSeconds = now.timeIntervalSince(windowStartedAt)
        if windowSeconds >= 1.0 {
            measuredHz = Double(samplesInWindow) / windowSeconds
            samplesInWindow = 0
            windowStartedAt = now
        }
    }
}
