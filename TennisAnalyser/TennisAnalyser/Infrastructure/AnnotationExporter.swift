//
//  AnnotationExporter.swift
//  TennisAnalyser (iOS)
//
//  Infrastructure — アノテーションを Create ML 向けに書き出す（F-I8-9/10 / W6-T16e）
//
//  Why not TrainingDataExporter を拡張する: 既存はラベル付き CSV を**コピー**する処理で、
//  入力が「1スイング=1ファイル」であることに依存している。連続記録では窓の切り出しが
//  書き出し時の処理になり、入力も出力の作り方も異なる。出力形式（フォルダ構成と
//  manifest.csv）だけを踏襲し、処理は分けた。

import Foundation
import os

enum AnnotationExportError: LocalizedError {
    case noConfirmedEvents
    case noSensorData

    var errorDescription: String? {
        switch self {
        case .noConfirmedEvents:
            return "承認済みのイベントがありません。"
        case .noSensorData:
            return "センサーの連続記録がありません。"
        }
    }
}

/// 書き出しの窓長（F-I8-9）
///
/// 窓長を書き出し時に指定できることが連続記録方式の主要な利点である。
/// 窓長を変えて学習し直す際に、再収集も再タグ付けも要らない。
struct ExportWindow: Equatable {
    var preSeconds: Double = 2.0
    var postSeconds: Double = 2.0

    nonisolated init(preSeconds: Double = 2.0, postSeconds: Double = 2.0) {
        self.preSeconds = preSeconds
        self.postSeconds = postSeconds
    }
}

enum AnnotationExporter {

    private static let csvHeader = "Timestamp(ms),AccX,AccY,AccZ,GyroX,GyroY,GyroZ,ShotClass"

    /// 承認済みイベントを `<ShotClass>/<sessionId>_<index>.csv` として書き出す
    ///
    /// - Parameter includeRejected: 却下を `REJECTED/` へ負例として出力する（F-I8-10）
    /// - Returns: 書き出し先ディレクトリ（共有シートに渡す）
    static func export(
        annotation: SessionAnnotation,
        chunks: [ContinuousChunk],
        window: ExportWindow = ExportWindow(),
        includeRejected: Bool = false
    ) throws -> URL {
        let confirmed = annotation.confirmedEventsForExport
        guard !confirmed.isEmpty else { throw AnnotationExportError.noConfirmedEvents }
        guard !chunks.isEmpty else { throw AnnotationExportError.noSensorData }

        let fm = FileManager.default
        let exportDir = try makeExportDirectory()

        var manifestLines = [
            "EventID,SessionID,Index,ShotClass,ImpactAt,PeakAcceleration,Origin,PreSeconds,PostSeconds,SampleCount"
        ]

        var targets = confirmed.map { (event: $0, label: $0.shotClass?.rawValue ?? "UNKNOWN") }
        if includeRejected {
            // 負例は検知器の改善に使う。学習に含めるかは利用側の判断（F-I8-10）
            targets += annotation.rejectedEventsForExport.map { (event: $0, label: "REJECTED") }
        }

        for (index, target) in targets.enumerated() {
            let range = DateInterval(
                start: target.event.impactAt.addingTimeInterval(-window.preSeconds),
                end: target.event.impactAt.addingTimeInterval(window.postSeconds)
            )
            let samples = WaveformLoader.loadSamples(chunks: chunks, range: range)
            guard !samples.isEmpty else {
                AppLog.store.error(
                    "export skipped (no samples): \(target.event.id, privacy: .public)"
                )
                continue
            }

            let classDir = exportDir.appendingPathComponent(target.label, isDirectory: true)
            if !fm.fileExists(atPath: classDir.path) {
                try fm.createDirectory(at: classDir, withIntermediateDirectories: true)
            }
            let destURL = classDir
                .appendingPathComponent("\(annotation.sessionId)_\(index).csv")
            try buildCSV(
                for: target.event,
                label: target.label,
                chunks: chunks,
                range: range
            ).write(to: destURL, atomically: true, encoding: .utf8)

            manifestLines.append([
                target.event.id,
                annotation.sessionId,
                String(index),
                target.label,
                iso8601.string(from: target.event.impactAt),
                target.event.detectorPeak.map { String(format: "%.3f", $0) } ?? "",
                target.event.origin.rawValue,
                String(format: "%.3f", window.preSeconds),
                String(format: "%.3f", window.postSeconds),
                String(samples.count),
            ].joined(separator: ","))
        }

        let manifestURL = exportDir.appendingPathComponent("manifest.csv")
        try (manifestLines.joined(separator: "\n") + "\n")
            .write(to: manifestURL, atomically: true, encoding: .utf8)

        AppLog.store.info(
            "exported \(targets.count, privacy: .public) events to \(exportDir.lastPathComponent, privacy: .public)"
        )
        return exportDir
    }

    // MARK: - CSV

    /// 窓内のサンプルを、スイング単位CSVと同じ列構成で書き出す
    ///
    /// センサータイムスタンプは元の値をそのまま使う。壁時計へ変換すると
    /// 既存の解析スクリプトが読めなくなるため、対応付けはヘッダーで示す。
    static func buildCSV(
        for event: AnnotatedEvent,
        label: String,
        chunks: [ContinuousChunk],
        range: DateInterval
    ) -> String {
        var lines: [String] = []
        lines.append("# EventID: \(event.id)")
        lines.append("# ShotClass: \(label)")
        lines.append("# ImpactAt: \(iso8601.string(from: event.impactAt))")
        lines.append("# WindowStart: \(iso8601.string(from: range.start))")
        lines.append("# WindowEnd: \(iso8601.string(from: range.end))")
        lines.append("# Origin: \(event.origin.rawValue)")
        lines.append(csvHeader)

        let sorted = chunks.sorted { $0.index < $1.index }
        for (offset, chunk) in sorted.enumerated() {
            let estimated = WaveformLoader.estimatedRange(
                of: chunk, next: offset + 1 < sorted.count ? sorted[offset + 1] : nil
            )
            guard estimated.intersects(range) else { continue }
            for point in ContinuousChunkParser.parseSamples(fileURL: chunk.fileURL) {
                let date = chunk.wallClock(forSensorMs: point.timestampMs)
                guard date >= range.start, date <= range.end else { continue }
                lines.append(String(
                    format: "%lld,%.6f,%.6f,%.6f,%.4f,%.4f,%.4f,%@",
                    point.timestampMs,
                    point.accX, point.accY, point.accZ,
                    point.gyroX, point.gyroY, point.gyroZ,
                    label
                ))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Private

    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// 書き出し先を作る
    ///
    /// Why not 時刻だけで名前を決める: 秒までしか含まないため、窓長を変えて続けて
    /// 書き出すと同じフォルダへ混ざり、中身が異なるのに区別できなくなる。
    /// 存在確認で番号を振る方式も避けた（確認と作成の間に別の書き出しが割り込む）。
    /// 接頭辞を `TrainingDataExporter` と分けているのも同じ理由。
    private static func makeExportDirectory() throws -> URL {
        let fm = FileManager.default
        let name = "TennisAnalyserAnnotationExport-\(timestamp())-\(UUID().uuidString.prefix(4))"
        let dir = fm.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
