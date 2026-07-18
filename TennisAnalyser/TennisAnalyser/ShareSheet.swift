//
//  ShareSheet.swift
//  TennisAnalyser
//
//  Presentation — UIActivityViewController の SwiftUI ラッパー（P3-T5 エクスポート用）

import SwiftUI

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
