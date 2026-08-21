//
//  TransferCenter.swift
//  TermoraX
//
//  SFTP 任务列表与当前 ZMODEM 进度，供横幅和文件管理器底部列表显示。
//

import Foundation
import Observation

struct TransferJob: Identifiable, Hashable {
    enum Kind: Hashable { case upload, download }
    enum Status: Hashable { case running, finished, failed }

    let id: UUID
    var name: String
    var kind: Kind
    var transferred: Int64
    var total: Int64
    var status: Status
    var message: String

    var progress: Double {
        guard total > 0 else { return status == .finished ? 1 : 0 }
        return min(1, Double(transferred) / Double(total))
    }
}

struct ZModemProgress: Equatable {
    enum Direction { case receive, send }
    var direction: Direction
    var fileName: String
    var transferred: Int64
    var total: Int64
    var message: String
    var isFinished: Bool
    var isError: Bool
    var savedPath: String? = nil
}

/// SFTP 与 ZMODEM 共用的进度中心，由主窗口观察。
@Observable
final class TransferCenter {
    var zmodem: ZModemProgress?
    var jobs: [TransferJob] = []

    func upsert(_ job: TransferJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.insert(job, at: 0)
        }
        if jobs.count > 40 {
            jobs = Array(jobs.prefix(40))
        }
    }
}
