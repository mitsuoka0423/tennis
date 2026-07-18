//
//  TennisAnalyserApp.swift
//  TennisAnalyser
//
//  Created by Mitsuoka Takahiro on 2026/07/15.
//

import SwiftUI

@main
struct TennisAnalyserApp: App {

    @StateObject private var store: SwingStore
    private let sessionManager: PhoneSessionManager

    init() {
        let store = SwingStore()
        _store = StateObject(wrappedValue: store)
        sessionManager = PhoneSessionManager(store: store)
        sessionManager.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .task { store.reload() }
        }
    }
}
