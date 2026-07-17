//
//  MotionSensorRepository.swift
//  TennisAnalyser Watch App
//
//  Domain Repository Protocol — 外部フレームワーク依存なし

import Foundation

/// センサーデータ取得の抽象インターフェース
///
/// 実装は Infrastructure 層（CMBatchedSensorManagerを使った実装、またはテスト用モック）が提供する。
protocol MotionSensorRepository: AnyObject {
    /// サンプリング開始。受信したサンプルのバッチを非同期ストリームで返す。
    /// - Parameter targetHz: 目標サンプリングレート（Hz）
    func startSampling(targetHz: Int) -> AsyncThrowingStream<[MotionSample], Error>

    /// サンプリング停止
    func stopSampling()
}
