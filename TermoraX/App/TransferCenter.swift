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
    enum Status: Hashable { case running, finished, failed, cancelled }

    let id: UUID
    var name: String
    var kind: Kind
    var transferred: Int64
    var total: Int64
    var bytesPerSecond: Double = 0
    var status: Status
    var message: String

    var progress: Double {
        guard total > 0 else { return status == .finished ? 1 : 0 }
        return min(1, Double(transferred) / Double(total))
    }

    var percentText: String {
        guard total > 0 else { return status == .running ? "…" : "" }
        return "\(Int((progress * 100).rounded()))%"
    }

    var speedText: String {
        guard status == .running, bytesPerSecond > 0 else { return "" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(bytesPerSecond.rounded())) + "/s"
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
    @ObservationIgnored private let cancelLock = NSLock()
    @ObservationIgnored private var cancelledIDs: Set<UUID> = []

    func upsert(_ job: TransferJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            if jobs[index].status == .cancelled, job.status == .running {
                return
            }
            jobs[index] = job
        } else {
            jobs.insert(job, at: 0)
        }
        if jobs.count > 40 {
            jobs = Array(jobs.prefix(40))
        }
    }

    func cancel(_ id: UUID) {
        cancelLock.lock()
        cancelledIDs.insert(id)
        cancelLock.unlock()
        if let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].status == .running {
            jobs[index].status = .cancelled
            jobs[index].message = "已取消"
            jobs[index].bytesPerSecond = 0
        }
    }

    func isCancelled(_ id: UUID) -> Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelledIDs.contains(id)
    }

    func clearHistory() {
        let running = jobs.filter { $0.status == .running }
        cancelLock.lock()
        let keep = Set(running.map(\.id))
        cancelledIDs = cancelledIDs.intersection(keep)
        cancelLock.unlock()
        jobs = running
    }
}
