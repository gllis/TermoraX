//
//  FileManagerView.swift
//  TermoraX
//
//  双栏文件管理：本机目录 + 远程 SFTP。双击进目录，可上传/下载文件或文件夹。
//

import AppKit
import SwiftUI

struct FileManagerView: View {
    let session: SessionNode?
    let transfers: TransferCenter
    var embeddedInTab: Bool = false
    var tabID: UUID? = nil
    var reconnectNonce: Int = 0

    @State private var sidebarModel = FileBrowserModel()

    private var browser: FileBrowserModel {
        if let tabID {
            return FileBrowserRegistry.shared.model(for: tabID)
        }
        return sidebarModel
    }

    var body: some View {
        @Bindable var model = browser
        return VStack(spacing: 0) {
            if !embeddedInTab {
                EmptyView()
            }
            HStack(spacing: 0) {
                pane(
                    title: "本机",
                    path: $model.localPath,
                    entries: model.localEntries,
                    selected: $model.selectedLocal,
                    isRemote: false
                )
                Divider()
                pane(
                    title: session.map { "远程 · \($0.name)" } ?? "远程",
                    path: $model.remotePath,
                    entries: model.remoteEntries,
                    selected: $model.selectedRemote,
                    isRemote: true
                )
            }
            if !transfers.jobs.isEmpty {
                Divider()
                transferList
            }
            if let error = model.errorMessage {
                Divider()
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            model.transfers = transfers
            model.loadLocal()
            if let session, session.isSSH {
                model.connect(session)
            }
        }
        .onChange(of: session?.id) { _, _ in
            if let session, session.isSSH {
                model.connect(session)
            }
        }
        .onChange(of: reconnectNonce) { _, _ in
            if let session, session.isSSH {
                model.forceReconnect(session)
            }
        }
    }

    private func pane(
        title: String,
        path: Binding<String>,
        entries: [FileEntry],
        selected: Binding<FileEntry.ID?>,
        isRemote: Bool
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                TextField("路径", text: path)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 0)
                    .onSubmit {
                        if isRemote { browser.refreshRemote() } else { browser.loadLocal() }
                    }
                Button {
                    if isRemote { browser.goUpRemote() } else { browser.goUpLocal() }
                } label: {
                    Image(systemName: "arrow.up")
                }
                .help("上级目录")
                Button {
                    if isRemote { browser.refreshRemote() } else { browser.loadLocal() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                if isRemote {
                    Button {
                        browser.uploadSelected()
                    } label: {
                        Image(systemName: "arrow.up.to.line")
                    }
                    .help("上传选中的本机文件或文件夹")
                    Button {
                        browser.downloadSelected()
                    } label: {
                        Image(systemName: "arrow.down.to.line")
                    }
                    .help("下载选中的远程文件或文件夹")
                    Button {
                        browser.mkdirRemote()
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .help("新建远程目录")
                }
            }
            .buttonStyle(.borderless)
            .padding(8)

            fileList(entries: entries, selected: selected, isRemote: isRemote)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .overlay {
            if isRemote && browser.isConnecting {
                ProgressView("正在连接 SFTP…")
            }
        }
    }

    private func fileList(
        entries: [FileEntry],
        selected: Binding<FileEntry.ID?>,
        isRemote: Bool
    ) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(entries) { entry in
                    fileRow(entry, selected: selected, isRemote: isRemote)
                }
            }
            .padding(.vertical, 2)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onKeyPress(.return) {
            if isRemote {
                browser.openRemoteSelection()
            } else {
                browser.openLocalSelection()
            }
            return .handled
        }
    }

    private func fileRow(
        _ entry: FileEntry,
        selected: Binding<FileEntry.ID?>,
        isRemote: Bool
    ) -> some View {
        let isSelected = selected.wrappedValue == entry.id
        return HStack(spacing: 8) {
            Image(systemName: entry.systemImage)
                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 14)
            Text(entry.name)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(entry.sizeText)
                .foregroundStyle(.secondary)
                .font(.caption)
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
            Text(entry.dateText)
                .foregroundStyle(.secondary)
                .font(.caption)
                .monospacedDigit()
                .frame(width: 148, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        }
        .contentShape(Rectangle())
        .highPriorityGesture(
            TapGesture(count: 2).onEnded {
                selected.wrappedValue = entry.id
                if isRemote {
                    browser.openRemote(entry)
                } else {
                    browser.openLocal(entry)
                }
            }
        )
        .onTapGesture {
            selected.wrappedValue = entry.id
        }
        .contextMenu {
            Button("打开") {
                selected.wrappedValue = entry.id
                if isRemote {
                    browser.openRemote(entry)
                } else {
                    browser.openLocal(entry)
                }
            }
            if isRemote {
                Button("下载") {
                    selected.wrappedValue = entry.id
                    browser.downloadSelected()
                }
                Button("删除", role: .destructive) {
                    selected.wrappedValue = entry.id
                    browser.deleteRemote()
                }
            } else {
                Button("上传") {
                    selected.wrappedValue = entry.id
                    browser.uploadSelected()
                }
                Button("在 Finder 中显示") {
                    selected.wrappedValue = entry.id
                    browser.revealLocal()
                }
            }
        }
    }

    private var transferList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("传输")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if transfers.jobs.contains(where: { $0.status != .running }) {
                    Button("清空记录") {
                        transfers.clearHistory()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("清除已完成、失败和已取消的记录")
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(transfers.jobs.prefix(8)) { job in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Image(systemName: job.kind == .download ? "arrow.down.circle" : "arrow.up.circle")
                                Text(job.name)
                                    .lineLimit(1)
                                Spacer()
                                if job.status == .running {
                                    if !job.speedText.isEmpty {
                                        Text(job.speedText)
                                            .monospacedDigit()
                                    }
                                    Text(job.percentText)
                                        .monospacedDigit()
                                        .frame(minWidth: 36, alignment: .trailing)
                                    Button {
                                        transfers.cancel(job.id)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("取消")
                                } else {
                                    Text(job.message)
                                        .foregroundStyle(job.status == .failed ? .red : .secondary)
                                }
                            }
                            if job.status == .running {
                                ProgressView(value: job.progress)
                            }
                        }
                        .font(.caption)
                    }
                }
            }
            .frame(maxHeight: 132)
        }
        .padding(8)
    }
}

struct FileEntry: Identifiable, Hashable {
    var id: String { path }
    var name: String
    var path: String
    var isDirectory: Bool
    var isSymlink: Bool = false
    var size: UInt64
    var modified: Date? = nil
    var systemImage: String

    var sizeText: String {
        if isDirectory { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }

    var dateText: String {
        guard let modified else { return "—" }
        return Self.dateFormatter.string(from: modified)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter
    }()
}

@Observable
final class FileBrowserModel {
    var localPath = FileManager.default.homeDirectoryForCurrentUser.path
    var remotePath = "."
    var localEntries: [FileEntry] = []
    var remoteEntries: [FileEntry] = []
    var selectedLocal: FileEntry.ID?
    var selectedRemote: FileEntry.ID?
    var isConnecting = false
    var errorMessage: String?
    weak var transfers: TransferCenter?

    private var client: SFTPClient?
    private var target: SSHTarget?
    private var connectGeneration = 0
    private var didResolveRemote = false

    func shutdown() {
        connectGeneration += 1
        client?.close()
        client = nil
        isConnecting = false
    }

    func loadLocal() {
        let url = URL(fileURLWithPath: AppPaths.expandHome(localPath))
        localPath = url.path
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        localEntries = items.map { item in
            let values = try? item.resourceValues(forKeys: keys)
            let isDir = values?.isDirectory ?? false
            let isLink = values?.isSymbolicLink ?? false
            let size = UInt64(values?.fileSize ?? 0)
            return FileEntry(
                name: item.lastPathComponent,
                path: item.path,
                isDirectory: isDir,
                isSymlink: isLink,
                size: size,
                modified: values?.contentModificationDate,
                systemImage: isDir ? "folder.fill" : (isLink ? "link" : "doc")
            )
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func connect(_ node: SessionNode) {
        let target = SSHCommand.target(from: node)
        if self.target?.id == target.id, (client?.isAlive == true || isConnecting) {
            return
        }
        startConnect(target: target)
    }

    func forceReconnect(_ node: SessionNode) {
        client?.close()
        client = nil
        isConnecting = false
        target = nil
        startConnect(target: SSHCommand.target(from: node))
    }

    private func startConnect(target: SSHTarget) {
        self.target = target
        errorMessage = nil
        isConnecting = true
        connectGeneration += 1
        let generation = connectGeneration
        let listingPath: String
        if didResolveRemote, !remotePath.isEmpty {
            listingPath = remotePath
        } else {
            listingPath = target.sftpDefaultPath.isEmpty ? "." : target.sftpDefaultPath
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let client = try SFTPClient.connect(to: target)
                let resolved = try client.realpath(listingPath)
                let listing = try client.list(path: resolved)
                DispatchQueue.main.async {
                    guard let self, self.connectGeneration == generation else {
                        client.close()
                        return
                    }
                    self.client?.close()
                    self.client = client
                    self.didResolveRemote = true
                    self.remotePath = resolved
                    self.remoteEntries = listing.map(Self.entry(from:))
                    self.isConnecting = false
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.connectGeneration == generation else { return }
                    self.isConnecting = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func refreshRemote() {
        guard let client else {
            if let target {
                errorMessage = nil
                isConnecting = true
                let defaultPath = remotePath.isEmpty ? (target.sftpDefaultPath.isEmpty ? "." : target.sftpDefaultPath) : remotePath
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    do {
                        let client = try SFTPClient.connect(to: target)
                        let listing = try client.list(path: defaultPath)
                        DispatchQueue.main.async {
                            self?.client = client
                            self?.remoteEntries = listing.map(Self.entry(from:))
                            self?.isConnecting = false
                        }
                    } catch {
                        DispatchQueue.main.async {
                            self?.isConnecting = false
                            self?.errorMessage = error.localizedDescription
                        }
                    }
                }
            }
            return
        }
        let path = remotePath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let listing = try client.list(path: path)
                DispatchQueue.main.async {
                    self?.remoteEntries = listing.map(Self.entry(from:))
                    self?.errorMessage = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func goUpLocal() {
        localPath = URL(fileURLWithPath: localPath).deletingLastPathComponent().path
        loadLocal()
    }

    func goUpRemote() {
        let url = URL(fileURLWithPath: remotePath)
        remotePath = url.deletingLastPathComponent().path
        if remotePath.isEmpty { remotePath = "/" }
        refreshRemote()
    }

    func openLocalSelection() {
        guard let selected = localEntries.first(where: { $0.id == selectedLocal }) else { return }
        openLocal(selected)
    }

    func openRemoteSelection() {
        guard let selected = remoteEntries.first(where: { $0.id == selectedRemote }) else { return }
        openRemote(selected)
    }

    func openLocal(_ entry: FileEntry) {
        selectedLocal = entry.id
        guard entry.isDirectory else { return }
        localPath = entry.path
        selectedLocal = nil
        loadLocal()
    }

    func openRemote(_ entry: FileEntry) {
        selectedRemote = entry.id
        if entry.isDirectory {
            enterRemote(entry.path)
            return
        }
        guard entry.isSymlink else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                guard let attrs = try self?.client?.stat(entry.path), attrs.isDirectory else { return }
                DispatchQueue.main.async { self?.enterRemote(entry.path) }
            } catch {
                DispatchQueue.main.async { self?.errorMessage = error.localizedDescription }
            }
        }
    }

    func uploadSelected() {
        guard let selected = localEntries.first(where: { $0.id == selectedLocal }) else { return }
        let remote = (remotePath.hasSuffix("/") ? remotePath : remotePath + "/") + selected.name
        transfer(name: selected.name, kind: .upload) { job, report in
            try self.client?.upload(
                local: URL(fileURLWithPath: selected.path),
                remote: remote,
                progress: report,
                isCancelled: { self.transfers?.isCancelled(job) == true }
            )
            DispatchQueue.main.async { self.refreshRemote() }
        }
    }

    func downloadSelected() {
        guard let selected = remoteEntries.first(where: { $0.id == selectedRemote }) else { return }
        let local = URL(fileURLWithPath: localPath).appendingPathComponent(selected.name)
        transfer(name: selected.name, kind: .download) { job, report in
            try self.client?.download(
                remote: selected.path,
                local: local,
                progress: report,
                isCancelled: { self.transfers?.isCancelled(job) == true }
            )
            DispatchQueue.main.async { self.loadLocal() }
        }
    }

    private func enterRemote(_ path: String) {
        remotePath = path
        selectedRemote = nil
        refreshRemote()
    }

    func mkdirRemote() {
        let alert = NSAlert()
        alert.messageText = "新建远程目录"
        let field = NSTextField(string: "new-folder")
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let path = (remotePath.hasSuffix("/") ? remotePath : remotePath + "/") + name
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try self?.client?.mkdir(path)
                DispatchQueue.main.async { self?.refreshRemote() }
            } catch {
                DispatchQueue.main.async { self?.errorMessage = error.localizedDescription }
            }
        }
    }

    func deleteRemote() {
        guard let selected = remoteEntries.first(where: { $0.id == selectedRemote }) else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try self?.client?.remove(path: selected.path, isDirectory: selected.isDirectory)
                DispatchQueue.main.async { self?.refreshRemote() }
            } catch {
                DispatchQueue.main.async { self?.errorMessage = error.localizedDescription }
            }
        }
    }

    func revealLocal() {
        guard let selected = localEntries.first(where: { $0.id == selectedLocal }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: selected.path)])
    }

    private func transfer(
        name: String,
        kind: TransferJob.Kind,
        work: @escaping (UUID, @escaping (Int64, Int64) -> Void) throws -> Void
    ) {
        let id = UUID()
        var job = TransferJob(id: id, name: name, kind: kind, transferred: 0, total: 0, status: .running, message: "进行中")
        transfers?.upsert(job)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var lastTick = Date()
            var lastBytes: Int64 = 0
            var speed: Double = 0
            do {
                try work(id) { transferred, total in
                    if self?.transfers?.isCancelled(id) == true { return }
                    let now = Date()
                    let elapsed = now.timeIntervalSince(lastTick)
                    if elapsed >= 0.2 || transferred == total {
                        if elapsed > 0 {
                            let instant = Double(transferred - lastBytes) / elapsed
                            speed = speed == 0 ? instant : speed * 0.65 + instant * 0.35
                        }
                        lastTick = now
                        lastBytes = transferred
                        DispatchQueue.main.async {
                            job.transferred = transferred
                            job.total = total
                            job.bytesPerSecond = speed
                            let percent = total > 0 ? Int((Double(transferred) / Double(total) * 100).rounded()) : 0
                            job.message = total > 0 ? "\(percent)%" : "进行中"
                            self?.transfers?.upsert(job)
                        }
                    }
                }
                DispatchQueue.main.async {
                    guard self?.transfers?.isCancelled(id) != true else { return }
                    job.status = .finished
                    job.message = "完成"
                    job.transferred = max(job.transferred, job.total)
                    job.bytesPerSecond = 0
                    self?.transfers?.upsert(job)
                }
            } catch {
                DispatchQueue.main.async {
                    if self?.transfers?.isCancelled(id) == true {
                        job.status = .cancelled
                        job.message = "已取消"
                    } else {
                        job.status = .failed
                        job.message = error.localizedDescription
                    }
                    job.bytesPerSecond = 0
                    self?.transfers?.upsert(job)
                    if kind == .upload {
                        self?.refreshRemote()
                    } else {
                        self?.loadLocal()
                    }
                }
            }
        }
    }

    private static func entry(from item: SFTPEntry) -> FileEntry {
        FileEntry(
            name: item.name,
            path: item.path,
            isDirectory: item.isDirectory,
            isSymlink: item.isSymlink,
            size: item.size,
            modified: item.modified,
            systemImage: item.systemImage
        )
    }
}

/// 按 SFTP 标签保留目录与连接。切走标签时 SwiftUI 会拆掉视图，不走这里就会回到默认路径。
final class FileBrowserRegistry {
    static let shared = FileBrowserRegistry()

    private var models: [UUID: FileBrowserModel] = [:]

    func model(for tabID: UUID) -> FileBrowserModel {
        if let existing = models[tabID] { return existing }
        let created = FileBrowserModel()
        models[tabID] = created
        return created
    }

    func close(_ tabID: UUID) {
        models.removeValue(forKey: tabID)?.shutdown()
    }
}
