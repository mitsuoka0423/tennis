//
//  TrainingDataExporter.swift
//  TennisAnalyser (iOS)
//
//  Infrastructure — アノテーション済みスイングを Create ML 向けに書き出す（P3-T5）
//
//  Why not zip: 独自の ZIP エンコーダを書く選択肢もあったが、正しさの検証が
//  このプロジェクトでは難しく（Process/unzip は iOS では使えずテストで裏取りできない）、
//  UIActivityViewController はフォルダ URL をそのまま共有できる（Files app の
//  「ファイルに保存」・AirDrop が対応）ため、フォルダ構成のまま共有する方式を採用した。
//  1つの zip が欲しければ Files app 側の「圧縮」機能で後から作れる。

import Foundation

enum TrainingDataExportError: LocalizedError {
    case noLabeledSwings

    var errorDescription: String? {
        switch self {
        case .noLabeledSwings:
            return "ショット種別がタグ付けされたスイングがありません。"
        }
    }
}

enum TrainingDataExporter {

    /// ラベル付きスイングを `<ShotClass>/<sessionId>_<sequence>.csv` の構造でエクスポート用フォルダに整理する
    ///
    /// - Returns: エクスポート先ディレクトリの URL（呼び出し側で共有シート等に渡す）
    static func export(records: [SwingRecord]) throws -> URL {
        let labeled = records.filter { $0.shotClass != nil }
        guard !labeled.isEmpty else { throw TrainingDataExportError.noLabeledSwings }

        let fm = FileManager.default
        let exportDir = fm.temporaryDirectory
            .appendingPathComponent("TennisAnalyserExport-\(exportTimestamp())", isDirectory: true)
        try fm.createDirectory(at: exportDir, withIntermediateDirectories: true)

        var manifestLines = ["SwingID,SessionID,Sequence,ShotClass,DetectedAt,PeakAcceleration"]

        for record in labeled {
            guard let shotClass = record.shotClass else { continue }
            let classDir = exportDir.appendingPathComponent(shotClass.rawValue, isDirectory: true)
            if !fm.fileExists(atPath: classDir.path) {
                try fm.createDirectory(at: classDir, withIntermediateDirectories: true)
            }
            let destURL = classDir.appendingPathComponent("\(record.sessionId)_\(record.sequence).csv")
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: record.fileURL, to: destURL)

            let detectedAtStr = record.detectedAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""
            let peakStr = record.peakAcceleration.map { String(format: "%.3f", $0) } ?? ""
            manifestLines.append(
                "\(record.id),\(record.sessionId),\(record.sequence),\(shotClass.rawValue),\(detectedAtStr),\(peakStr)"
            )
        }

        let manifestURL = exportDir.appendingPathComponent("manifest.csv")
        try (manifestLines.joined(separator: "\n") + "\n").write(to: manifestURL, atomically: true, encoding: .utf8)

        return exportDir
    }

    private static func exportTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
