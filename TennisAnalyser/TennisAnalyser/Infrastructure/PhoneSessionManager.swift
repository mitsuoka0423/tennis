//
//  PhoneSessionManager.swift
//  TennisAnalyser (iOS)
//
//  Infrastructure — WCSession による Watch からのファイル受信（F-I1）

import Foundation
import WatchConnectivity

/// Watch からのスイングファイルをバックグラウンド受信するセッションマネージャ
///
/// 受信したファイルは `SwingStore` に取り込み、永続保管する。
/// delegate コールバックは WCSession 内部スレッドから呼ばれるため actor 隔離しない。
final class PhoneSessionManager: NSObject {

    private let store: SwingStore

    init(store: SwingStore) {
        self.store = store
        super.init()
    }

    /// 受信セッションを有効化する（アプリ起動時に1回）
    func activate() {
        guard WCSession.isSupported() else {
            print("[PhoneSession] WCSession not supported")
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }
}

// MARK: - WCSessionDelegate

extension PhoneSessionManager: WCSessionDelegate {

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            print("[PhoneSession] activation error: \(error)")
        } else {
            print("[PhoneSession] activated: \(activationState.rawValue)")
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        print("[PhoneSession] became inactive")
    }

    func sessionDidDeactivate(_ session: WCSession) {
        // Watch の切り替え等でセッションが無効化された場合は再有効化する
        session.activate()
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // 注意: file.fileURL は本メソッドの return 後に無効になるため同期的に取り込む
        print("[PhoneSession] received \(file.fileURL.lastPathComponent)")
        store.ingest(tempURL: file.fileURL, metadata: file.metadata)
    }
}
