//
//  PhoneSessionManager.swift
//  TennisAnalyser (iOS)
//
//  Infrastructure — WCSession による Watch からのファイル受信（F-I1）+
//  セッション開始/終了通知の受信によるカメラ自動録画トリガー（F-I6）

import Foundation
import WatchConnectivity

/// Watch からのスイングファイル受信・セッション状態通知を扱うセッションマネージャ
///
/// - スイングファイルは `SwingStore` に取り込み、永続保管する（F-I1）
/// - セッション開始/終了の `applicationContext` を受けて `PracticeVideoRecorder` を自動制御する（F-I6）
/// - delegate コールバックは WCSession 内部スレッドから呼ばれるため actor 隔離しない。
final class PhoneSessionManager: NSObject {

    private let store: SwingStore
    private let videoStore: VideoStore
    private let recorder: PracticeVideoRecorder

    /// セッション終了通知からこの秒数だけ待ってから継続録画（中間データ）を削除する。
    /// Watch→iPhone のスイング転送は F-W5 で「10秒以内」を目安としているため、
    /// 遅延到着分の処理猶予として十分な余裕を持たせる。
    private static let sourceCleanupDelaySeconds: UInt64 = 60

    init(store: SwingStore, videoStore: VideoStore, recorder: PracticeVideoRecorder) {
        self.store = store
        self.videoStore = videoStore
        self.recorder = recorder
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

    /// F-I6: Watch からのセッション開始/終了通知を受けてカメラ録画を自動制御する
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard applicationContext["type"] as? String == "sessionStatus",
              let sessionId = applicationContext["sessionId"] as? String,
              let status = applicationContext["status"] as? String
        else { return }

        Task { @MainActor in
            switch status {
            case "started":
                print("[PhoneSession] session started: \(sessionId)")
                self.recorder.startRecording(sessionId: sessionId)
            case "ended":
                print("[PhoneSession] session ended: \(sessionId)")
                self.recorder.stopRecording()
                self.scheduleSourceCleanup(sessionId: sessionId)
            default:
                break
            }
        }
    }

    /// セッション終了から猶予時間後に、残っているスイングのクリップ化を試みてから
    /// 継続録画（中間データ）を削除する
    @MainActor
    private func scheduleSourceCleanup(sessionId: String) {
        Task {
            try? await Task.sleep(nanoseconds: Self.sourceCleanupDelaySeconds * 1_000_000_000)
            let pendingRecords = self.store.records.filter { $0.sessionId == sessionId }
            for record in pendingRecords {
                await self.videoStore.extractClipIfNeeded(
                    sessionId: record.sessionId, sequence: record.sequence, detectedAt: record.detectedAt
                )
            }
            self.videoStore.deleteSource(sessionId: sessionId)
        }
    }
}
