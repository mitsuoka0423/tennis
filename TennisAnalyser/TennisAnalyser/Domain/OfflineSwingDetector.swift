//
//  OfflineSwingDetector.swift
//  TennisAnalyser (iOS)
//
//  Domain Service — 連続センサー記録からスイング候補を抽出する（W6-T15）

import Foundation

/// 検知パラメータ
///
/// 撮影時ではなく事後に検知するため、値を変えて何度でも走らせ直せる。
/// 既定値は 2026-07-21 の実データ分析（W5-T11）に基づく。
struct OfflineDetectorParameters: Equatable, Codable {

    /// インパクト判定の加速度閾値 (g)
    ///
    /// 3.0g 据え置き。4.0g へ上げると実打の30.5%が脱落し、低g帯（3〜4g）は
    /// 加速度あたりの回転がむしろ大きいため誤検知とは言えない（W5-T11）。
    var accelerationThreshold: Double = 3.0

    /// 検知後の不感時間（秒）。この時間が経過するまで次の候補を出さない
    ///
    /// Watch 側の実装は窓終端（インパクト後2秒）まで不感だったため、
    /// 3g 超イベントの42%を取りこぼしていた（W5-T11）。実打の間隔は 0.6 秒まで
    /// 確認できているため、インパクト直後の残響だけを潰す長さに留める。
    var rearmSeconds: Double = 0.4

    /// 閾値超過から真のピークを探す範囲（秒）
    ///
    /// 閾値を超えた最初のサンプルは真のインパクトよりわずかに早い。
    var peakSearchSeconds: Double = 0.15

    /// 角速度ゲートの判定範囲（インパクト前後・秒）
    var gyroGateSeconds: Double = 0.1

    /// 角速度ゲートの下限 (°/s)。nil = ゲート無効
    ///
    /// W5-T11 の分析では「3.0g + ジャイロ 300°/s 以上」が最も筋の良い絞り方だったが、
    /// ラベルが無く precision/recall を測れていないため既定は無効とする。
    /// 有効にした場合も候補が消えるだけで記録は残るため、事後に付け直せる。
    var minGyroPeakDegPerSec: Double?

    // バックグラウンドで検知を走らせるため nonisolated（既定の MainActor 隔離を外す）
    nonisolated init(
        accelerationThreshold: Double = 3.0,
        rearmSeconds: Double = 0.4,
        peakSearchSeconds: Double = 0.15,
        gyroGateSeconds: Double = 0.1,
        minGyroPeakDegPerSec: Double? = nil
    ) {
        self.accelerationThreshold = accelerationThreshold
        self.rearmSeconds = rearmSeconds
        self.peakSearchSeconds = peakSearchSeconds
        self.gyroGateSeconds = gyroGateSeconds
        self.minGyroPeakDegPerSec = minGyroPeakDegPerSec
    }
}

/// 検知されたスイング候補（センサー時間軸）
struct SwingCandidate: Equatable {
    /// インパクトのセンサータイムスタンプ (ms)
    let impactSensorMs: Int64
    /// インパクト位置の加速度 (g)
    let peakAcceleration: Double
    /// インパクト前後の角速度ピーク (°/s)
    let gyroPeak: Double
}

/// 検知されたスイング候補（壁時計に対応付け済み）
struct DetectedImpact: Equatable, Identifiable {
    var id: String { "\(sessionId)#\(impactSensorMs)" }

    let sessionId: String
    /// 検知元のチャンク番号
    let chunkIndex: Int
    let impactSensorMs: Int64
    /// 動画との対応付けに用いる壁時計時刻
    let impactAt: Date
    let peakAcceleration: Double
    let gyroPeak: Double
}

/// 連続センサー記録に対する検知器
///
/// Watch 側 `SwingDetector` と異なり、ウィンドウの切り出しは行わない。
/// 候補の位置だけを返し、窓の切り出しは書き出し時に行う（F-I8-9）。
enum OfflineSwingDetector {

    // 注: プロジェクトは SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor のため、
    // 純関数はバックグラウンドから呼べるよう nonisolated を明示する

    /// サンプル列から候補を抽出する
    ///
    /// - Parameters:
    ///   - samples: センサータイムスタンプ昇順のサンプル列
    ///   - rearmAfterSensorMs: 不感時間の終端。チャンクをまたいで引き継ぐため in-out で受ける
    ///     （センサータイムスタンプは Watch の起動時刻を基準とするためセッション内で連続する）
    nonisolated static func detect(
        samples: [SwingSamplePoint],
        parameters: OfflineDetectorParameters,
        rearmAfterSensorMs: inout Int64?
    ) -> [SwingCandidate] {
        var candidates: [SwingCandidate] = []
        let rearmMs = Int64(parameters.rearmSeconds * 1000)

        var index = 0
        while index < samples.count {
            let sample = samples[index]
            let isAboveThreshold = sample.accelerationMagnitude >= parameters.accelerationThreshold
            let isRearmed = rearmAfterSensorMs.map { sample.timestampMs > $0 } ?? true
            guard isAboveThreshold, isRearmed else {
                index += 1
                continue
            }

            let peakIndex = indexOfPeak(
                from: index, in: samples, within: parameters.peakSearchSeconds
            )
            let impact = samples[peakIndex]
            let gyroPeak = gyroPeak(
                around: peakIndex, in: samples, within: parameters.gyroGateSeconds
            )

            // 却下された超過も不感時間を進める。残響で連続する超過を候補として
            // 並べてしまうと、ゲートの有効・無効で候補数が桁違いに変わる
            rearmAfterSensorMs = impact.timestampMs + rearmMs

            if let minGyro = parameters.minGyroPeakDegPerSec, gyroPeak < minGyro {
                index = peakIndex + 1
                continue
            }
            candidates.append(SwingCandidate(
                impactSensorMs: impact.timestampMs,
                peakAcceleration: impact.accelerationMagnitude,
                gyroPeak: gyroPeak
            ))
            index = peakIndex + 1
        }
        return candidates
    }

    /// セッションの全チャンクを順に走らせ、壁時計付きの候補を返す
    ///
    /// Why not 全チャンクを読み込んでから検知する: 1セッションは 200Hz で約68万サンプル・
    /// 46MB あり、全量を同時に保持すると端末上で成立しない。チャンク単位で読み捨て、
    /// 不感時間だけを引き継ぐ。
    nonisolated static func detect(
        chunks: [ContinuousChunk],
        parameters: OfflineDetectorParameters
    ) -> [DetectedImpact] {
        var results: [DetectedImpact] = []
        var rearmAfterSensorMs: Int64?
        for chunk in chunks.sorted(by: { $0.index < $1.index }) {
            let samples = ContinuousChunkParser.parseSamples(fileURL: chunk.fileURL)
            let candidates = detect(
                samples: samples,
                parameters: parameters,
                rearmAfterSensorMs: &rearmAfterSensorMs
            )
            results.append(contentsOf: candidates.map { candidate in
                DetectedImpact(
                    sessionId: chunk.sessionId,
                    chunkIndex: chunk.index,
                    impactSensorMs: candidate.impactSensorMs,
                    impactAt: chunk.wallClock(forSensorMs: candidate.impactSensorMs),
                    peakAcceleration: candidate.peakAcceleration,
                    gyroPeak: candidate.gyroPeak
                )
            })
        }
        return results
    }

    // MARK: - Private

    /// 閾値超過位置から `within` 秒の範囲で加速度が最大のサンプルの添字を返す
    nonisolated private static func indexOfPeak(
        from startIndex: Int,
        in samples: [SwingSamplePoint],
        within seconds: Double
    ) -> Int {
        let limitMs = samples[startIndex].timestampMs + Int64(seconds * 1000)
        var peakIndex = startIndex
        var peakValue = samples[startIndex].accelerationMagnitude
        var index = startIndex + 1
        while index < samples.count, samples[index].timestampMs <= limitMs {
            let value = samples[index].accelerationMagnitude
            if value > peakValue {
                peakValue = value
                peakIndex = index
            }
            index += 1
        }
        return peakIndex
    }

    /// インパクト前後 `within` 秒の角速度ピークを返す
    nonisolated private static func gyroPeak(
        around impactIndex: Int,
        in samples: [SwingSamplePoint],
        within seconds: Double
    ) -> Double {
        let windowMs = Int64(seconds * 1000)
        let impactMs = samples[impactIndex].timestampMs
        var peak = samples[impactIndex].gyroMagnitude

        var backward = impactIndex - 1
        while backward >= 0, samples[backward].timestampMs >= impactMs - windowMs {
            peak = max(peak, samples[backward].gyroMagnitude)
            backward -= 1
        }
        var forward = impactIndex + 1
        while forward < samples.count, samples[forward].timestampMs <= impactMs + windowMs {
            peak = max(peak, samples[forward].gyroMagnitude)
            forward += 1
        }
        return peak
    }
}
