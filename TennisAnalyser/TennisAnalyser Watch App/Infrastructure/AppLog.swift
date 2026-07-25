//
//  AppLog.swift
//  TennisAnalyser Watch App
//
//  Infrastructure — 構造化ログの入口（F-I7-6）
//
//  Why not print: `print` の出力は Xcode をアタッチしている間しか stdout に現れない。
//  2026-07-21 の実機検証（テニス実練習57分）ではログが1行も残らず、
//  不具合の原因をファイル配置からの逆算でしか追えなかった。
//  `os.Logger` なら未接続でも記録され、後から Console.app・sysdiagnose で追跡できる。
//
//  Why not iOS 側と同一ファイルを共有: 本プロジェクトは Xcode の同期グループ
//  （PBXFileSystemSynchronizedRootGroup）で構成されており、ターゲットごとに
//  フォルダが対応する。共有フォルダを追加すると project.pbxproj の手編集が
//  必要になるためリスクが見合わない。カテゴリは Watch 側で必要なものだけを持つ。

import os

/// Watch App の構造化ログ
///
/// サブシステムは iOS 側と揃える。Console.app では
/// `subsystem:com.spleeing.TennisAnalyser` で iPhone/Watch を横断して追える。
enum AppLog {

    private static let subsystem = "com.spleeing.TennisAnalyser"

    /// センサーストリームの取得状況
    static let motion = Logger(subsystem: subsystem, category: "motion")
    /// スイング検知・切り出し・永続化
    static let swing = Logger(subsystem: subsystem, category: "swing")
    /// iPhone へのファイル転送・セッション通知
    static let transfer = Logger(subsystem: subsystem, category: "transfer")
}
