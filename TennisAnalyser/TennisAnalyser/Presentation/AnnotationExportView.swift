//
//  AnnotationExportView.swift
//  TennisAnalyser (iOS)
//
//  Presentation — 窓長を指定して学習データを書き出す（F-I8-9/10 / W6-T16e）

import SwiftUI

struct AnnotationExportView: View {

    let session: RecordingSession

    @EnvironmentObject private var annotations: AnnotationStore
    @EnvironmentObject private var continuousStore: ContinuousSensorStore

    @State private var preSeconds: Double = 2.0
    @State private var postSeconds: Double = 2.0
    @State private var includeRejected = false
    @State private var exportResult: ExportResult?
    @State private var isExporting = false
    @State private var errorMessage: String?

    private var annotation: SessionAnnotation { annotations.annotation(for: session.id) }

    var body: some View {
        Form {
            Section("対象") {
                LabeledContent("承認済み", value: "\(annotation.confirmedCount) 件")
                LabeledContent("却下", value: "\(annotation.rejectedCount) 件")
                LabeledContent("未判断", value: "\(annotation.remainingCount) 件")
                Toggle("却下も負例として出力", isOn: $includeRejected)
            }

            Section {
                Stepper(
                    String(format: "インパクト前 %.1f 秒", preSeconds),
                    value: $preSeconds, in: 0.5...5.0, step: 0.5
                )
                Stepper(
                    String(format: "インパクト後 %.1f 秒", postSeconds),
                    value: $postSeconds, in: 0.5...5.0, step: 0.5
                )
            } header: {
                Text("窓長")
            } footer: {
                // 連続記録方式の主要な利点。窓長を変えても再収集・再タグ付けは要らない
                Text("窓長を変えて書き出し直せます。タグ付けのやり直しは不要です。")
            }

            Section {
                Button {
                    export()
                } label: {
                    if isExporting {
                        ProgressView()
                    } else {
                        Text("書き出す")
                    }
                }
                .disabled(annotation.confirmedCount == 0 || isExporting)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("書き出し")
        .sheet(item: $exportResult) { result in
            ShareSheet(items: [result.url])
        }
    }

    // MARK: - Private

    private func export() {
        isExporting = true
        errorMessage = nil
        let annotation = annotation
        let chunks = continuousStore.chunks(for: session.id)
        let window = ExportWindow(preSeconds: preSeconds, postSeconds: postSeconds)
        let includeRejected = includeRejected

        Task {
            // 窓ごとにチャンクを読み直すため、件数に比例して時間がかかる
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try AnnotationExporter.export(
                        annotation: annotation,
                        chunks: chunks,
                        window: window,
                        includeRejected: includeRejected
                    )
                }
            }.value
            isExporting = false
            switch result {
            case .success(let url): exportResult = ExportResult(url: url)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
    }
}

/// 書き出し先を `sheet(item:)` へ渡すための包み
///
/// Why not URL に Identifiable を後付けする: 標準型への遡及的な適合は
/// 将来 SDK 側で同じ適合が入ると衝突する。用途はこの画面に限られるため包みで足りる。
private struct ExportResult: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
