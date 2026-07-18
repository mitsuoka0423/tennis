//
//  MotionSample.swift
//  TennisAnalyser Watch App
//
//  Domain Entity — 外部フレームワーク依存なし

import Foundation

/// 1サンプル分のセンサーデータ（加速度 + 角速度）
struct MotionSample: Equatable, Sendable {
    /// エポックからのミリ秒タイムスタンプ
    let timestampMs: Int64
    /// 加速度 X軸 (g)
    let accX: Double
    /// 加速度 Y軸 (g)
    let accY: Double
    /// 加速度 Z軸 (g)
    let accZ: Double
    /// 角速度 X軸 (°/s)
    let gyroX: Double
    /// 角速度 Y軸 (°/s)
    let gyroY: Double
    /// 角速度 Z軸 (°/s)
    let gyroZ: Double
    /// ショット分類（未分類は nil）
    let shotClass: ShotClass?

    /// 加速度ベクトルの大きさ (g)
    var accelerationMagnitude: Double {
        sqrt(accX * accX + accY * accY + accZ * accZ)
    }
}

/// ショット種別（6分類）
///
/// 要求2.3（試合モードのショット別分析）に合わせ、ストローク/ボレーをフォア・バックで区別する。
/// rawValue は iOS 側の同名 enum（TennisAnalyser/Domain/SwingRecord.swift）と
/// CSV 経由で往復するため一致させること。
enum ShotClass: String, Equatable, Sendable, CaseIterable {
    case strokeForehand = "STROKE_FOREHAND"
    case strokeBackhand = "STROKE_BACKHAND"
    case volleyForehand = "VOLLEY_FOREHAND"
    case volleyBackhand = "VOLLEY_BACKHAND"
    case serve          = "SERVE"
    case other           = "OTHER"
}
