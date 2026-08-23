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

    @State private var model = FileBrowserModel()

    var body: some View {
        VStack(spacing: 0) {
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
                        if isRemote { model.refreshRemote() } else { model.loadLocal() }
                    }
                Button {
                    if isRemote { model.goUpRemote() } else { model.goUpLocal() }
                } label: {
                    Image(systemName: "arrow.up")
                }
                .help("上级目录")
                Button {
                    if isRemote { model.refreshRemote() } else { model.loadLocal() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                if isRemote {
                    Button {
                        model.uploadSelected()
                    } label: {
                        Image(systemName: "arrow.up.to.line")
                    }
                    .help("上传选中的本机文件或文件夹")
                    Button {
                        model.downloadSelected()
                    } label: {
                        Image(systemName: "arrow.down.to.line")
                    }
                    .help("下载选中的远程文件或文件夹")
                    Button {
                        model.mkdirRemote()
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .help("新建远程目录")
                }
            }
            .buttonStyle(.borderless)
            .padding(8)

            Table(entries, selection: selected) {
                TableColumn("名称") { entry in
                    Label(entry.name, systemImage: entry.systemImage)
                        .lineLimit(1)
                }
                TableColumn("大小") { entry in
                    Text(entry.sizeText)
                        .foregroundStyle(.secondary)
                }
                .width(70)
            }
            .background {
                TableDoubleClickMonitor { row in
                    guard entries.indices.contains(row) else { return }
                    let entry = entries[row]
                    if isRemote {
                        model.openRemote(entry)
                    } else {
                        model.openLocal(entry)
                    }
                }
            }
            .onKeyPress(.return) {
                if isRemote {
                    model.openRemoteSelection()
                } else {
                    model.openLocalSelection()
                }
                return .handled
            }
            .contextMenu {
                Button("打开") {
                    if isRemote {
                        model.openRemoteSelection()
                    } else {
                        model.openLocalSelection()
                    }
                }
                if isRemote {
                    Button("下载") { model.downloadSelected() }
                    Button("删除", role: .destructive) { model.deleteRemote() }
                } else {
                    Button("上传") { model.uploadSelected() }
                    Button("在 Finder 中显示") { model.revealLocal() }
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .overlay {
            if isRemote && model.isConnecting {
                ProgressView("正在连接 SFTP…")
            }
        }
    }

    private var transferList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("传输")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(transfers.jobs.prefix(4)) { job in
                HStack {
                    Image(systemName: job.kind == .download ? "arrow.down.circle" : "arrow.up.circle")
                    Text(job.name)
                        .lineLimit(1)
                    Spacer()
                    if job.status == .running {
                        ProgressView(value: job.progress)
                            .frame(width: 80)
                    } else {
                        Text(job.message)
                            .font(.caption)
                            .foregroundStyle(job.status == .failed ? .red : .secondary)
                    }
                }
                .font(.caption)
            }
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
    var systemImage: String
    var sizeText: String {
        if isDirectory { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
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

    func loadLocal() {
        let url = URL(fileURLWithPath: AppPaths.expandHome(localPath))
        localPath = url.path
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        localEntries = items.map { item in
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
            let isDir = values?.isDirectory ?? false
            let isLink = values?.isSymbolicLink ?? false
            let size = UInt64(values?.fileSize ?? 0)
            return FileEntry(
                name: item.lastPathComponent,
                path: item.path,
                isDirectory: isDir,
                isSymlink: isLink,
                size: size,
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
        self.target = target
        errorMessage = nil
        isConnecting = true
        let defaultPath = target.sftpDefaultPath.isEmpty ? "." : target.sftpDefaultPath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let client = try SFTPClient.connect(to: target)
                let resolved = try client.realpath(defaultPath)
                let listing = try client.list(path: resolved)
                DispatchQueue.main.async {
                    self?.client?.close()
                    self?.client = client
                    self?.remotePath = resolved
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
            try self.client?.upload(local: URL(fileURLWithPath: selected.path), remote: remote, progress: report)
            DispatchQueue.main.async { self.refreshRemote() }
            _ = job
        }
    }

    func downloadSelected() {
        guard let selected = remoteEntries.first(where: { $0.id == selectedRemote }) else { return }
        let local = URL(fileURLWithPath: localPath).appendingPathComponent(selected.name)
        transfer(name: selected.name, kind: .download) { job, report in
            try self.client?.download(remote: selected.path, local: local, progress: report)
            DispatchQueue.main.async { self.loadLocal() }
            _ = job
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
            do {
                try work(id) { transferred, total in
                    DispatchQueue.main.async {
                        job.transferred = transferred
                        job.total = total
                        self?.transfers?.upsert(job)
                    }
                }
                DispatchQueue.main.async {
                    job.status = .finished
                    job.message = "完成"
                    job.transferred = max(job.transferred, job.total)
                    self?.transfers?.upsert(job)
                }
            } catch {
                DispatchQueue.main.async {
                    job.status = .failed
                    job.message = error.localizedDescription
                    self?.transfers?.upsert(job)
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
            systemImage: item.systemImage
        )
    }
}

/// SwiftUI `Table` 会吃掉 `onTapGesture`，改挂底层 `NSTableView` 的双击。
private struct TableDoubleClickMonitor: NSViewRepresentable {
    var action: (Int) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.action = action
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.action = action
    }

    final class MonitorView: NSView {
        var action: ((Int) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else {
                installMonitor()
            }
        }

        deinit {
            removeMonitor()
        }

        private func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                guard let self, event.clickCount == 2, event.window === self.window else {
                    return event
                }
                guard let table = self.ownedTable() else { return event }
                let point = table.convert(event.locationInWindow, from: nil)
                let row = table.row(at: point)
                if row >= 0 {
                    DispatchQueue.main.async { self.action?(row) }
                }
                return event
            }
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func ownedTable() -> NSTableView? {
            var current: NSView? = self
            while let view = current {
                let tables = Self.tables(in: view)
                if tables.count == 1 { return tables[0] }
                if tables.count > 1 { return nil }
                current = view.superview
            }
            return nil
        }

        private static func tables(in view: NSView) -> [NSTableView] {
            if let table = view as? NSTableView { return [table] }
            return view.subviews.flatMap { tables(in: $0) }
        }
    }
}
