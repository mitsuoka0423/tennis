//
//  WCSessionTransferRepository.swift
//  TennisAnalyser Watch App
//
//  Infrastructure — WCSession.transferFile によるスイング逐次転送（F-W5）

import Foundation
import WatchConnectivity
import os

/// `WCSession.transferFile` によるスイングファイル転送の実装
///
/// - スイング保存のたびに `enqueue` で転送キューへ追加（バックグラウンド転送）
/// - 転送完了コールバックでローカル CSV を削除（F-W5 + ストレージ保護）
/// - 未転送分は `retryPending` で再送（アクティベート完了時・ワークアウト終了時）
/// - WCSession の転送キューはプロセス再起動を跨いで永続化されるため、
///   `outstandingFileTransfers` と突き合わせて二重エンキューを防ぐ
///
/// 注意: delegate コールバックは WCSession 内部スレッドから呼ばれる。
/// Phase 1 の教訓に従い actor 隔離はせず、UI 通知のみ main queue へディスパッチする。
final class WCSessionTransferRepository: NSObject, SwingTransferRepository {

    // MARK: - Dependencies

    private let swingRepo: any SwingRepository

    // MARK: - State

    var onStatusChanged: ((_ transferred: Int, _ pending: Int) -> Void)?
    private var transferredCount = 0

    private var session: WCSession { WCSession.default }

    // MARK: - Init

    init(swingRepo: any SwingRepository) {
        self.swingRepo = swingRepo
        super.init()
    }

    // MARK: - SwingTransferRepository

    func activate() {
        guard WCSession.isSupported() else {
            AppLog.transfer.error("WCSession not supported on this device")
            return
        }
        session.delegate = self
        session.activate()
    }

    func enqueue(fileURL: URL, swing: Swing) {
        let metadata: [String: Any] = [
            "swingId": swing.id,
            "sessionId": swing.sessionId,
            "sequence": swing.sequence,
            "detectedAt": ISO8601DateFormatter().string(from: swing.detectedAt),
            "peakAcceleration": swing.peakAcceleration,
        ]
        session.transferFile(fileURL, metadata: metadata)
        AppLog.transfer.info("enqueued swing #\(swing.sequence, privacy: .public) (\(fileURL.lastPathComponent, privacy: .public))")
        notifyStatus()
    }

    func retryPending() {
        guard session.activationState == .activated else { return }
        // WCSession キューに載っていないローカル残存ファイルを再エンキュー
        let outstanding = Set(session.outstandingFileTransfers.map { $0.file.fileURL.path })
        let localFiles = (try? swingRepo.listFiles()) ?? []
        for url in localFiles where !outstanding.contains(url.path) {
            // メタデータはパスから復元（CSV ヘッダーにも全メタ情報あり = 冗長設計）
            let metadata: [String: Any] = [
                "sessionId": url.deletingLastPathComponent().lastPathComponent,
                "sequence": Int(url.deletingPathExtension().lastPathComponent) ?? 0,
            ]
            session.transferFile(url, metadata: metadata)
            AppLog.transfer.info("re-enqueued \(url.lastPathComponent, privacy: .public)")
        }
        notifyStatus()
    }

    /// F-I6: セッション開始を iPhone へ通知する（applicationContext は「最新状態のみ」を
    /// 保持し、iPhone がバックグラウンドでも到達するため、この用途に適している）
    func notifySessionStarted(sessionId: String) {
        sendSessionStatus(sessionId: sessionId, status: "started")
    }

    func notifySessionEnded(sessionId: String) {
        sendSessionStatus(sessionId: sessionId, status: "ended")
    }

    // MARK: - Private

    private func sendSessionStatus(sessionId: String, status: String) {
        guard session.activationState == .activated else { return }
        do {
            try session.updateApplicationContext([
                "type": "sessionStatus",
                "sessionId": sessionId,
                "status": status,
                "timestamp": ISO8601DateFormatter().string(from: Date()),
            ])
            AppLog.transfer.info("session \(status, privacy: .public): \(sessionId, privacy: .public)")
        } catch {
            AppLog.transfer.error("updateApplicationContext failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 転送状態を通知する
    /// - Parameter finished: 完了直後の転送。`didFinish` 時点では
    ///   `outstandingFileTransfers` にまだ含まれていることがあるため除外する（W-2）
    private func notifyStatus(excluding finished: WCSessionFileTransfer? = nil) {
        var outstanding = session.outstandingFileTransfers
        if let finished {
            outstanding.removeAll { $0 === finished }
        }
        let pending = outstanding.count
        let transferred = transferredCount
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChanged?(transferred, pending)
        }
    }
}

// MARK: - WCSessionDelegate

extension WCSessionTransferRepository: WCSessionDelegate {

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            AppLog.transfer.error("activation failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        AppLog.transfer.info("activated: state=\(activationState.rawValue, privacy: .public)")
        // アクティベート完了時に未転送分を再送（前回セッションの残り）
        retryPending()
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let url = fileTransfer.file.fileURL
        if let error {
            // 失敗分はローカルに残し、次回 retryPending で再送する
            AppLog.transfer.error("transfer failed \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        } else {
            transferredCount += 1
            AppLog.transfer.info("transfer finished \(url.lastPathComponent, privacy: .public)")
            // 転送完了後にローカルキャッシュを削除（F-W5 / ストレージ保護）
            do {
                try swingRepo.deleteFile(at: url)
            } catch {
                AppLog.transfer.error("cleanup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        notifyStatus(excluding: fileTransfer)
    }
}
