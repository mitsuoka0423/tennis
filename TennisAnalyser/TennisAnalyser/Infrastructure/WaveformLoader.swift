//
//  WaveformLoader.swift
//  TennisAnalyser (iOS)
//
//  Infrastructure — 連続記録から波形を読み出す（F-I8-4 / W6-T16b）

import Foundation
import os

/// 連続センサー記録からの波形読み出し
enum WaveformLoader {

    /// チャンク1本が覆う時間の推定上限（秒）
    ///
    /// Watch 側のチャンク分割長（200Hz で5分）に合わせる。
    nonisolated static let maxChunkSeconds: Double = 300

    /// アンカーより前に存在し得るサンプルの見込み（秒）
    ///
    /// アンカーはチャンク先頭バッチの**末尾**サンプルから採るため、
    /// チャンクの実際の開始はアンカーよりわずかに早い。
    nonisolated static let anchorLeadSeconds: Double = 5

    /// 対象範囲に重なるチャンクだけを読み、壁時計に対応付けたサンプル列を返す
    ///
    /// Why not 全チャンクを読む: 1セッションは46MB・約68万サンプルある。
    /// 選別画面は候補の前後数秒しか要らないため、範囲に重なるチャンクに限って読む。
    nonisolated static func loadSamples(
        chunks: [ContinuousChunk],
        range: DateInterval
    ) -> [TimedSample] {
        let sorted = chunks.sorted { $0.index < $1.index }
        var samples: [TimedSample] = []
        for (offset, chunk) in sorted.enumerated() {
            let estimated = estimatedRange(of: chunk, next: sorted[safe: offset + 1])
            guard estimated.intersects(range) else { continue }
            for point in ContinuousChunkParser.parseSamples(fileURL: chunk.fileURL) {
                let date = chunk.wallClock(forSensorMs: point.timestampMs)
                guard date >= range.start, date <= range.end else { continue }
                samples.append(TimedSample(
                    date: date,
                    acceleration: point.accelerationMagnitude,
                    gyro: point.gyroMagnitude
                ))
            }
        }
        return samples.sorted { $0.date < $1.date }
    }

    /// 対象範囲の波形をビン化して返す
    nonisolated static func loadBins(
        chunks: [ContinuousChunk],
        range: DateInterval,
        binCount: Int
    ) -> [WaveformBin] {
        WaveformDownsampler.bins(
            from: loadSamples(chunks: chunks, range: range),
            range: range,
            binCount: binCount
        )
    }

    /// チャンクが覆う時間範囲を推定する
    ///
    /// Why not チャンクの実際の終端を記録する: 終端はファイル末尾のサンプルにしか無く、
    /// 知るには全量を読む必要がある。ヘッダーのアンカーはチャンク先頭のバッチから
    /// 採っているため、次チャンクのアンカーまでを覆う範囲として扱える。
    /// 過大に見積もっても余分なチャンクを1本読むだけで結果は変わらない。
    nonisolated static func estimatedRange(
        of chunk: ContinuousChunk,
        next: ContinuousChunk?
    ) -> DateInterval {
        let start = chunk.anchorWallClock.addingTimeInterval(-anchorLeadSeconds)
        let end = next?.anchorWallClock ?? start.addingTimeInterval(maxChunkSeconds)
        return DateInterval(start: start, end: max(end, start))
    }
}

private extension Array {
    nonisolated subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
