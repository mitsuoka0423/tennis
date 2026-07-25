//
//  PhoneSessionManager.swift
//  TennisAnalyser (iOS)
//
//  Infrastructure — WCSession による Watch からのファイル受信（F-I1）+
//  セッション開始/終了通知の受信によるカメラ自動録画トリガー（F-I6）

import Foundation
import WatchConnectivity
import os

/// Watch からのスイングファイル受信・セッション状態通知を扱うセッションマネージャ
///
/// - スイングファイルは `SwingStore` に取り込み、永続保管する（F-I1）
/// - セッション開始/終了の `applicationContext` を受けて `PracticeVideoRecorder` を自動制御する（F-I6）
/// - delegate コールバックは WCSession 内部スレッドから呼ばれるため actor 隔離しない。
final class PhoneSessionManager: NSObject {

    private let store: SwingStore
    private let videoStore: VideoStore
    private let recorder: PracticeVideoRecorder
    private let diagnostics: DiagnosticsStore

    /// セッション終了通知からこの秒数だけ待ってから、未生成クリップの生成を試みる。
    /// Watch→iPhone のスイング転送は F-W5 で「10秒以内」を目安としているため、
    /// 遅延到着分の処理猶予として十分な余裕を持たせる。
    private static let clipRetryDelaySeconds: UInt64 = 60

    init(
        store: SwingStore,
        videoStore: VideoStore,
        recorder: PracticeVideoRecorder,
        diagnostics: DiagnosticsStore
    ) {
        self.store = store
        self.videoStore = videoStore
        self.recorder = recorder
        self.diagnostics = diagnostics
        super.init()
    }

    /// 受信セッションを有効化する（アプリ起動時に1回）
    func activate() {
        guard WCSession.isSupported() else {
            AppLog.transfer.error("WCSession not supported on this device")
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
            AppLog.transfer.error("activation failed: \(error.localizedDescription, privacy: .public)")
        } else {
            AppLog.transfer.info("activated: state=\(activationState.rawValue, privacy: .public)")
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        AppLog.transfer.info("session became inactive")
    }

    func sessionDidDeactivate(_ session: WCSession) {
        // Watch の切り替え等でセッションが無効化された場合は再有効化する
        session.activate()
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // 注意: file.fileURL は本メソッドの return 後に無効になるため同期的に取り込む
        AppLog.transfer.info("received \(file.fileURL.lastPathComponent, privacy: .public)")
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
                AppLog.session.info("session started: \(sessionId, privacy: .public)")
                let startedAt = Date()
                self.diagnostics.record(.sessionStarted(at: startedAt), for: sessionId)
                self.videoStore.registerSessionStart(sessionId: sessionId, startedAt: startedAt)
                self.recorder.beginSession(sessionId: sessionId)
            case "ended":
                AppLog.session.info("session ended: \(sessionId, privacy: .public)")
                let endedAt = Date()
                self.diagnostics.record(.sessionEnded(at: endedAt), for: sessionId)
                self.recorder.endSession()
                self.videoStore.registerSessionEnd(sessionId: sessionId, endedAt: endedAt)
                self.scheduleRemainingClips(sessionId: sessionId)
            default:
                break
            }
        }
    }

    /// セッション終了から猶予時間後に、残っているスイングのクリップ化を試みる
    ///
    /// Why not 生成後にセグメントを削除する（2026-07-25 まではそうしていた）:
    /// セグメントは一次データであり、クリップは何度でも再生成できる派生データにすぎない
    /// （F-I7-4）。旧実装はセッション終了60秒後にセグメントを無条件削除しており、
    /// 2026-07-21 はクリップ生成に失敗した時点で素材ごと失われ、原因を追えなくなった。
    @MainActor
    private func scheduleRemainingClips(sessionId: String) {
        Task {
            try? await Task.sleep(nanoseconds: Self.clipRetryDelaySeconds * 1_000_000_000)
            let pendingRecords = self.store.records.filter { $0.sessionId == sessionId }
            for record in pendingRecords {
                await self.videoStore.extractClipIfNeeded(
                    sessionId: record.sessionId, sequence: record.sequence, detectedAt: record.detectedAt
                )
            }
        }
    }
}
