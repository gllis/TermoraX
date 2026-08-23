//
//  SFTPClient.swift
//  TermoraX
//
//  通过 `ssh -s sftp` 走 SFTP 子系统，自己解析 packet，不依赖 libssh。
//

import Foundation

struct SFTPEntry: Identifiable, Hashable {
    var id: String { path }
    var name: String
    var path: String
    var isDirectory: Bool
    var isSymlink: Bool
    var size: UInt64
    var modified: Date?
    var permissions: String

    var systemImage: String {
        if isDirectory { return "folder.fill" }
        if isSymlink { return "link" }
        return "doc"
    }
}

enum SFTPError: LocalizedError {
    case notConnected
    case protocolFailure(String)
    case status(UInt32, String)
    case processExited(Int32)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "尚未连接到 SFTP"
        case .protocolFailure(let message):
            return message
        case .status(let code, let message):
            return message.isEmpty ? "SFTP 错误 \(code)" : message
        case .processExited(let code):
            return "SSH 进程已退出（\(code)）"
        }
    }
}

final class SFTPClient: @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    private var requestID: UInt32 = 0
    private var secret: URL?
    private var closed = false

    static func connect(to target: SSHTarget) throws -> SFTPClient {
        let client = SFTPClient()
        try client.start(target)
        try client.initialize()
        return client
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        process.terminate()
        if let secret {
            try? FileManager.default.removeItem(at: secret)
        }
    }

    deinit {
        process.terminate()
        if let secret {
            try? FileManager.default.removeItem(at: secret)
        }
    }

    func realpath(_ path: String) throws -> String {
        var writer = ByteWriter()
        writer.string(path)
        let packet = try transact(type: 16, payload: writer.payload)
        guard packet.type == 104 else {
            throw try statusError(packet)
        }
        var reader = ByteReader(packet.payload)
        _ = try reader.u32()
        return try reader.string()
    }

    func list(path: String) throws -> [SFTPEntry] {
        let resolved = try realpath(path)
        var openWriter = ByteWriter()
        openWriter.string(resolved)
        let handlePacket = try transact(type: 11, payload: openWriter.payload)
        guard handlePacket.type == 102 else { throw try statusError(handlePacket) }
        var handleReader = ByteReader(handlePacket.payload)
        let handle = try handleReader.blob()

        var entries: [SFTPEntry] = []
        while true {
            var readWriter = ByteWriter()
            readWriter.blob(handle)
            let names = try transact(type: 12, payload: readWriter.payload)
            if names.type == 101 {
                var status = ByteReader(names.payload)
                let code = try status.u32()
                if code == 1 { break }
                throw SFTPError.status(code, (try? status.string()) ?? "")
            }
            guard names.type == 104 else { throw SFTPError.protocolFailure("无法列出目录") }
            var reader = ByteReader(names.payload)
            let count = try reader.u32()
            for _ in 0..<count {
                let name = try reader.string()
                let longname = try reader.string()
                let attrs = try reader.attrs()
                if name == "." || name == ".." { continue }
                let kind = Self.entryKind(attrs: attrs, longname: longname)
                let joined = resolved.hasSuffix("/") ? resolved + name : resolved + "/" + name
                entries.append(
                    SFTPEntry(
                        name: name,
                        path: joined,
                        isDirectory: kind.isDirectory,
                        isSymlink: kind.isSymlink,
                        size: attrs.size,
                        modified: attrs.modified,
                        permissions: attrs.permissionText
                    )
                )
            }
        }

        var closeWriter = ByteWriter()
        closeWriter.blob(handle)
        _ = try transact(type: 4, payload: closeWriter.payload)
        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func mkdir(_ path: String) throws {
        var writer = ByteWriter()
        writer.string(path)
        writer.u32(0)
        try expectOK(transact(type: 14, payload: writer.payload))
    }

    func mkdirIfNeeded(_ path: String) throws {
        do {
            try mkdir(path)
        } catch let error as SFTPError {
            if case .status(let code, _) = error, code == 11 {
                return
            }
            if case .status = error, (try? stat(path))?.isDirectory == true {
                return
            }
            throw error
        }
    }

    func remove(path: String, isDirectory: Bool) throws {
        var writer = ByteWriter()
        writer.string(path)
        try expectOK(transact(type: isDirectory ? 15 : 13, payload: writer.payload))
    }

    func rename(from: String, to: String) throws {
        var writer = ByteWriter()
        writer.string(from)
        writer.string(to)
        try expectOK(transact(type: 18, payload: writer.payload))
    }

    func download(
        remote: String,
        local: URL,
        progress: ((Int64, Int64) -> Void)? = nil
    ) throws {
        let attrs = try stat(remote)
        let isDirectory = attrs.isDirectory
        let total = isDirectory ? (try remoteTreeSize(remote)) : Int64(attrs.size)
        var transferred: Int64 = 0
        try downloadItem(remote: remote, local: local, isDirectory: isDirectory) { delta in
            transferred += delta
            progress?(transferred, max(total, transferred))
        }
    }

    func upload(
        local: URL,
        remote: String,
        progress: ((Int64, Int64) -> Void)? = nil
    ) throws {
        let total = Self.localTreeSize(local)
        var transferred: Int64 = 0
        try uploadItem(local: local, remote: remote) { delta in
            transferred += delta
            progress?(transferred, max(total, transferred))
        }
    }

    private func uploadItem(local: URL, remote: String, onBytes: (Int64) -> Void) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: local.path, isDirectory: &isDirectory) else {
            throw SFTPError.protocolFailure("本地文件不存在")
        }
        if isDirectory.boolValue {
            try mkdirIfNeeded(remote)
            let items = try FileManager.default.contentsOfDirectory(
                at: local,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            for item in items.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                try uploadItem(local: item, remote: join(remote, item.lastPathComponent), onBytes: onBytes)
            }
            return
        }
        try uploadFile(local: local, remote: remote, onBytes: onBytes)
    }

    private func uploadFile(local: URL, remote: String, onBytes: (Int64) -> Void) throws {
        let handle = try open(path: remote, flags: 0x0002 | 0x0008 | 0x0010)
        defer { try? closeHandle(handle) }
        let file = try FileHandle(forReadingFrom: local)
        defer { try? file.close() }
        var offset: UInt64 = 0
        while true {
            let chunk = try file.read(upToCount: 32 * 1024) ?? Data()
            if chunk.isEmpty { break }
            var writer = ByteWriter()
            writer.blob(handle)
            writer.u64(offset)
            writer.blob(chunk)
            try expectOK(transact(type: 6, payload: writer.payload))
            offset += UInt64(chunk.count)
            onBytes(Int64(chunk.count))
        }
    }

    private func downloadItem(remote: String, local: URL, isDirectory: Bool, onBytes: (Int64) -> Void) throws {
        if isDirectory {
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            for item in try list(path: remote) {
                try downloadItem(
                    remote: item.path,
                    local: local.appendingPathComponent(item.name),
                    isDirectory: item.isDirectory,
                    onBytes: onBytes
                )
            }
            return
        }
        try downloadFile(remote: remote, local: local, onBytes: onBytes)
    }

    private func downloadFile(remote: String, local: URL, onBytes: (Int64) -> Void) throws {
        let handle = try open(path: remote, flags: 0x0001)
        defer { try? closeHandle(handle) }
        FileManager.default.createFile(atPath: local.path, contents: nil)
        let out = try FileHandle(forWritingTo: local)
        defer { try? out.close() }
        var offset: UInt64 = 0
        while true {
            var writer = ByteWriter()
            writer.blob(handle)
            writer.u64(offset)
            writer.u32(32 * 1024)
            let packet = try transact(type: 5, payload: writer.payload)
            if packet.type == 101 {
                var reader = ByteReader(packet.payload)
                let code = try reader.u32()
                if code == 1 { break }
                throw SFTPError.status(code, (try? reader.string()) ?? "")
            }
            guard packet.type == 103 else { throw SFTPError.protocolFailure("读取文件失败") }
            var reader = ByteReader(packet.payload)
            let chunk = try reader.blob()
            if chunk.isEmpty { break }
            try out.write(contentsOf: chunk)
            offset += UInt64(chunk.count)
            onBytes(Int64(chunk.count))
        }
    }

    private func remoteTreeSize(_ path: String) throws -> Int64 {
        let attrs = try stat(path)
        if !attrs.isDirectory {
            return Int64(attrs.size)
        }
        return try list(path: path).reduce(Int64(0)) { total, item in
            total + (item.isDirectory ? (try remoteTreeSize(item.path)) : Int64(item.size))
        }
    }

    private static func localTreeSize(_ url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return items.reduce(0) { $0 + localTreeSize($1) }
    }

    private func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    /// 部分服务器的 READDIR 不带权限位；退回解析 longname 第一列（`drwx…` / `lrwx…`）。
    private static func entryKind(attrs: SFTPAttributes, longname: String) -> (isDirectory: Bool, isSymlink: Bool) {
        if attrs.permissions != 0 {
            return (attrs.isDirectory, attrs.isSymlink)
        }
        switch longname.first {
        case "d": return (true, false)
        case "l": return (false, true)
        default: return (false, false)
        }
    }

    func stat(_ path: String) throws -> SFTPAttributes {
        var writer = ByteWriter()
        writer.string(path)
        let packet = try transact(type: 17, payload: writer.payload)
        guard packet.type == 105 else { throw try statusError(packet) }
        var reader = ByteReader(packet.payload)
        return try reader.attrs()
    }

    private func start(_ target: SSHTarget) throws {
        let password = target.authMethod == "key" ? nil : SecretStore.password(for: target.id)
        let ask = SSHCommand.askpassEnvironment(password: password)
        secret = ask.secret

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        ask.env.forEach { env[$0.key] = $0.value }

        process.executableURL = URL(fileURLWithPath: SSHCommand.executable)
        process.arguments = SSHCommand.sftpArguments(for: target)
        process.environment = env
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
    }

    private func initialize() throws {
        var writer = ByteWriter()
        writer.u32(3)
        try writePacket(type: 1, payload: writer.payload, includeID: false)
        let response = try readPacket()
        guard response.type == 2 else {
            throw SFTPError.protocolFailure("SFTP 握手失败，请确认主机可连接且已登录")
        }
    }

    private func open(path: String, flags: UInt32) throws -> Data {
        var writer = ByteWriter()
        writer.string(path)
        writer.u32(flags)
        writer.u32(0)
        let packet = try transact(type: 3, payload: writer.payload)
        guard packet.type == 102 else { throw try statusError(packet) }
        var reader = ByteReader(packet.payload)
        return try reader.blob()
    }

    private func closeHandle(_ handle: Data) throws {
        var writer = ByteWriter()
        writer.blob(handle)
        _ = try transact(type: 4, payload: writer.payload)
    }

    private func transact(type: UInt8, payload: Data) throws -> Packet {
        lock.lock()
        defer { lock.unlock() }
        try writePacket(type: type, payload: payload, includeID: true)
        return try readPacket()
    }

    private func writePacket(type: UInt8, payload: Data, includeID: Bool) throws {
        var body = Data([type])
        if includeID {
            requestID += 1
            var id = requestID.bigEndian
            body.append(Data(bytes: &id, count: 4))
        }
        body.append(payload)
        var length = UInt32(body.count).bigEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(body)
        try stdin.fileHandleForWriting.write(contentsOf: packet)
    }

    private func readPacket() throws -> Packet {
        let lengthData = try readExact(4)
        let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard length > 0, length < 8 * 1024 * 1024 else {
            throw SFTPError.protocolFailure("SFTP 数据包异常")
        }
        let body = try readExact(Int(length))
        guard let type = body.first else { throw SFTPError.protocolFailure("空数据包") }
        var payload = body.dropFirst()
        if type != 1 && type != 2 && payload.count >= 4 {
            payload = payload.dropFirst(4)
        }
        return Packet(type: type, payload: Data(payload))
    }

    private func readExact(_ count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            if !process.isRunning && data.isEmpty {
                throw SFTPError.processExited(process.terminationStatus)
            }
            let chunk = stdout.fileHandleForReading.readData(ofLength: count - data.count)
            if chunk.isEmpty {
                throw SFTPError.protocolFailure("SFTP 连接已断开")
            }
            data.append(chunk)
        }
        return data
    }

    private func expectOK(_ packet: Packet) throws {
        guard packet.type == 101 else { throw SFTPError.protocolFailure("意外的 SFTP 响应") }
        var reader = ByteReader(packet.payload)
        let code = try reader.u32()
        if code != 0 {
            throw SFTPError.status(code, (try? reader.string()) ?? "")
        }
    }

    private func statusError(_ packet: Packet) throws -> SFTPError {
        var reader = ByteReader(packet.payload)
        let code = (try? reader.u32()) ?? 0
        let message = (try? reader.string()) ?? "SFTP 失败"
        return SFTPError.status(code, message)
    }

    private struct Packet {
        var type: UInt8
        var payload: Data
    }
}

struct SFTPAttributes {
    var size: UInt64 = 0
    var permissions: UInt32 = 0
    var modified: Date?
    var isDirectory: Bool { (permissions & 0o170000) == 0o040000 }
    var isSymlink: Bool { (permissions & 0o170000) == 0o120000 }
    var permissionText: String {
        let mode = permissions & 0o777
        func bit(_ mask: UInt32, _ char: Character) -> Character {
            (mode & mask) != 0 ? char : "-"
        }
        let kind: Character = isDirectory ? "d" : (isSymlink ? "l" : "-")
        return String([
            kind,
            bit(0o400, "r"), bit(0o200, "w"), bit(0o100, "x"),
            bit(0o040, "r"), bit(0o020, "w"), bit(0o010, "x"),
            bit(0o004, "r"), bit(0o002, "w"), bit(0o001, "x"),
        ])
    }
}

private struct ByteWriter {
    var buffer = Data()
    var payload: Data { buffer }

    mutating func u32(_ value: UInt32) {
        var be = value.bigEndian
        buffer.append(Data(bytes: &be, count: 4))
    }

    mutating func u64(_ value: UInt64) {
        var be = value.bigEndian
        buffer.append(Data(bytes: &be, count: 8))
    }

    mutating func string(_ value: String) {
        blob(Data(value.utf8))
    }

    mutating func blob(_ value: Data) {
        u32(UInt32(value.count))
        buffer.append(value)
    }
}

private struct ByteReader {
    let bytes: Data
    var offset = 0

    init(_ bytes: Data) {
        self.bytes = bytes
    }

    mutating func u32() throws -> UInt32 {
        let slice = try take(4)
        return slice.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }

    mutating func u64() throws -> UInt64 {
        let slice = try take(8)
        return slice.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
    }

    mutating func string() throws -> String {
        String(data: try blob(), encoding: .utf8) ?? ""
    }

    mutating func blob() throws -> Data {
        let length = Int(try u32())
        return try take(length)
    }

    mutating func attrs() throws -> SFTPAttributes {
        let flags = try u32()
        var attrs = SFTPAttributes()
        if flags & 0x00000001 != 0 {
            attrs.size = try u64()
        }
        if flags & 0x00000002 != 0 {
            _ = try u32()
            _ = try u32()
        }
        if flags & 0x00000004 != 0 {
            attrs.permissions = try u32()
        }
        if flags & 0x00000008 != 0 {
            _ = try u32()
            let mtime = try u32()
            attrs.modified = Date(timeIntervalSince1970: TimeInterval(mtime))
        }
        if flags & 0x80000000 != 0 {
            let count = try u32()
            for _ in 0..<count {
                _ = try string()
                _ = try string()
            }
        }
        return attrs
    }

    private mutating func take(_ count: Int) throws -> Data {
        guard offset + count <= bytes.count else { throw SFTPError.protocolFailure("数据包截断") }
        let slice = bytes.subdata(in: offset..<(offset + count))
        offset += count
        return slice
    }
}
