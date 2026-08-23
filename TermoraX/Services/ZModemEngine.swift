//
//  ZModemEngine.swift
//  TermoraX
//
//  终端内嵌 ZMODEM：远端 `sz` 下载到本机，本机 `rz` 上传。
//  帧头十六进制必须小写；CRC 后不要多写两个 0 字节。
//  发送按窗口分批并等 ZACK，中止时先丢排队数据。详见 Tools/ZModemCheck。
//

import AppKit
import Foundation

/// 从 PTY 字节流里识别 ZMODEM 会话，与普通终端输出分流。
final class ZModemEngine {
    private enum Mode {
        case idle
        case receiving
        case pickingFiles
        case offeringFile
        case transferring
        case finishingSend
    }

    private let zpad: UInt8 = 0x2A
    private let zdle: UInt8 = 0x18
    private let zhex: UInt8 = 0x42
    private let zbin: UInt8 = 0x41
    private let zbin32: UInt8 = 0x43

    private let zrqinit: UInt8 = 0
    private let zrinit: UInt8 = 1
    private let zack: UInt8 = 3
    private let zfile: UInt8 = 4
    private let zskip: UInt8 = 5
    private let znak: UInt8 = 6
    private let zfin: UInt8 = 8
    private let zrpos: UInt8 = 9
    private let zdata: UInt8 = 10
    private let zeof: UInt8 = 11

    private let zcrce: UInt8 = 0x68
    private let zcrcg: UInt8 = 0x69
    private let zcrcq: UInt8 = 0x6A
    private let zcrcw: UInt8 = 0x6B

    private let canfdx: UInt8 = 0x01
    private let canovio: UInt8 = 0x02
    private let escctl: UInt8 = 0x40

    private var mode: Mode = .idle
    private var awaitingFileInfo = false
    private var awaitingReceiveFolder = false
    private var pendingReceiveInfo: (name: String, size: Int64)?
    private var buffer: [UInt8] = []
    private var receiveCRC32 = false
    private var receivingData = false
    private var escapeControls = false
    private var fileHandle: FileHandle?
    private var fileURL: URL?
    private var fileName = ""
    private var fileSize: Int64 = 0
    private var transferred: Int64 = 0
    private var sendFiles: [URL] = []
    private var sendIndex = 0
    private var sendOffset: UInt64 = 0
    private var sendHandle: FileHandle?
    private var remoteBufferSize = 0
    var receiveDirectory = AppPaths.zmodemReceiveFolder

    /// One subpacket. lrzsz's `rz` reads 1024-byte subpackets by default; larger
    /// ones overflow its buffer and turn into a retransmit loop.
    private let sendSubpacketSize = 1024
    /// Bytes sent before waiting for a ZACK. ZMODEM allows pure streaming, but
    /// then a stalled or dead `rz` leaves the rest of the file queued, and the
    /// remote shell executes it as commands.
    private let sendWindowSize = 256 * 1024

    var onProgress: ((ZModemProgress) -> Void)?
    var sendToHost: ((ArraySlice<UInt8>) -> Void)?
    var onPassthrough: (([UInt8]) -> Void)?
    /// Drops bytes handed to `sendToHost` that have not reached the pty yet.
    var discardPendingSends: (() -> Void)?
    /// Asks for the files to upload. Replaced by tests to run without AppKit.
    var filePicker: ((@escaping ([URL]?) -> Void) -> Void)?

    var isActive: Bool { mode != .idle }

    private var finishWork: DispatchWorkItem?
    private var offerWatch: DispatchWorkItem?
    private var ackWatch: DispatchWorkItem?
    private var lastRemoteZRInit = Date.distantPast

    func cancel() {
        failTransfer("已取消")
    }

    private func abortRemote() {
        // Drop queued frames first. Once `rz` is gone the remote shell reads
        // whatever is still in flight, and file data full of `>` bytes turns
        // into junk files with binary names.
        discardPendingSends?()
        let can = [UInt8](repeating: zdle, count: 8) + [UInt8](repeating: 0x08, count: 10)
        sendToHost?(can[...])
    }

    private func failTransfer(_ message: String) {
        abortRemote()
        finish(message: message, error: true)
    }

    /// Returns terminal bytes that must be displayed. `nil` means ZMODEM consumed the data.
    func ingest(_ slice: ArraySlice<UInt8>) -> [UInt8]? {
        if mode != .idle {
            buffer.append(contentsOf: slice)
            pump()
            return nil
        }

        buffer.append(contentsOf: slice)
        if let headerAt = indexOfHeader(in: buffer) {
            let prefix = Array(buffer[..<headerAt])
            buffer.removeFirst(headerAt)
            pump()
            return prefix
        }

        // Signature is 4 bytes (`**\x18B`). Only hold a possible partial match so the
        // shell prompt is not delayed or replayed.
        let keep = partialSignatureLength(in: buffer)
        if keep == buffer.count {
            return []
        }
        let prefix = Array(buffer[..<(buffer.count - keep)])
        buffer.removeFirst(buffer.count - keep)
        return prefix
    }

    private func partialSignatureLength(in bytes: [UInt8]) -> Int {
        let maxKeep = min(3, bytes.count)
        for keep in stride(from: maxKeep, through: 1, by: -1) {
            let tail = bytes.suffix(keep)
            if isPartialSignature(tail) { return keep }
        }
        return 0
    }

    private func isPartialSignature<S: Sequence>(_ bytes: S) -> Bool where S.Element == UInt8 {
        let part = Array(bytes)
        let signatures: [[UInt8]] = [
            [zpad, zpad, zdle, zhex],
            [zpad, zpad, zdle, zbin],
            [zpad, zpad, zdle, zbin32],
        ]
        return signatures.contains { signature in
            part.count < signature.count && signature.starts(with: part)
        }
    }

    func beginSending(_ files: [URL]) {
        guard !files.isEmpty else {
            failTransfer("未选择文件")
            return
        }
        // If rz already timed out, ZFILE would be read by bash and create junk files.
        if Date().timeIntervalSince(lastRemoteZRInit) > 15 {
            failTransfer("远程 rz 已超时，请重新运行 rz 后再选择文件")
            return
        }
        sendFiles = files
        sendIndex = 0
        mode = .offeringFile
        sendNextFile()
    }

    private func pump() {
        if awaitingFileInfo {
            if let info = parseFileInfo() {
                awaitingFileInfo = false
                startReceive(info)
            } else {
                return
            }
        }

        while true {
            if receivingData {
                guard consumeDataFrames() else { return }
                continue
            }
            guard let header = parseHeader() else { return }
            handle(header)
            if awaitingFileInfo { return }
        }
    }

    private func handle(_ header: Header) {
        switch header.type {
        case zrqinit:
            if mode == .idle || mode == .receiving {
                mode = .receiving
                sendZRInit()
                publish(direction: .receive, message: "正在接收文件…保存到 \(displayPath(receiveDirectory))")
            }
        case zrinit:
            lastRemoteZRInit = Date()
            applyRemoteCapabilities(header)
            handleZRInit()
        case zfile:
            guard mode == .idle || mode == .receiving else { return }
            mode = .receiving
            receiveCRC32 = header.crc32
            if let info = parseFileInfo() {
                startReceive(info)
            } else {
                awaitingFileInfo = true
            }
        case zdata:
            guard mode == .receiving else { return }
            if header.position != UInt64(transferred) {
                sendHex(type: zrpos, flags: positionBytes(UInt32(clamping: transferred)))
                return
            }
            receiveCRC32 = header.crc32
            receivingData = true
        case zeof:
            guard mode == .receiving else { return }
            if header.position != UInt64(transferred) {
                sendHex(type: zrpos, flags: positionBytes(UInt32(clamping: transferred)))
                return
            }
            try? fileHandle?.close()
            fileHandle = nil
            let path = fileURL?.path
            publish(
                direction: .receive,
                fileName: fileName,
                transferred: transferred,
                total: fileSize,
                message: "已保存 \(fileName) → \(displayPath(fileURL))",
                finished: false,
                savedPath: path
            )
            sendZRInit()
            // Keep the session active: sz may send another ZFILE, then closes with ZFIN.
        case zfin:
            guard mode != .idle else { return }
            finishWork?.cancel()
            ackWatch?.cancel()
            if mode == .finishingSend || mode == .offeringFile || mode == .transferring {
                sendToHost?([0x4F, 0x4F][...])
                finish(message: "发送完成", error: false)
            } else {
                // Receiver acknowledges ZFIN; remote sz answers with "OO".
                sendHex(type: zfin, flags: [0, 0, 0, 0])
                scheduleFinish(
                    message: fileURL == nil ? "接收完成" : "已保存到 \(displayPath(fileURL))",
                    error: false,
                    savedPath: fileURL?.path,
                    delay: 5
                )
            }
        case zrpos:
            if mode == .offeringFile || mode == .transferring {
                offerWatch?.cancel()
                ackWatch?.cancel()
                mode = .transferring
                sendWindow(from: header.position)
            }
        case zack:
            if mode == .transferring {
                ackWatch?.cancel()
                sendWindow(from: header.position)
            }
        case zskip:
            if mode == .offeringFile || mode == .transferring {
                ackWatch?.cancel()
                sendIndex += 1
                mode = .offeringFile
                sendNextFile()
            }
        case znak:
            if mode == .offeringFile || mode == .transferring {
                ackWatch?.cancel()
                mode = .offeringFile
                sendNextFile()
            }
        default:
            break
        }
    }

    private func handleZRInit() {
        ackWatch?.cancel()
        switch mode {
        case .pickingFiles:
            // Remote rz retries ZRINIT while the open panel is up — do not send ZFIN.
            return
        case .offeringFile:
            // rz did not accept the previous ZFILE — offer the same file again.
            sendNextFile()
        case .transferring:
            sendIndex += 1
            mode = .offeringFile
            sendNextFile()
        case .finishingSend:
            return
        case .receiving:
            break
        case .idle:
            mode = .pickingFiles
            DispatchQueue.main.async { [weak self] in
                self?.pickFilesToSend()
            }
        }
    }

    private func applyRemoteCapabilities(_ header: Header) {
        guard header.flags.count >= 4 else { return }
        escapeControls = header.flags[3] & escctl != 0
        // ZRINIT carries the receiver's buffer size in ZP0/ZP1; 0 means unlimited.
        remoteBufferSize = Int(header.flags[0]) | Int(header.flags[1]) << 8
    }

    private func sendZRInit() {
        sendHex(type: zrinit, flags: [0, 0, 0, canfdx | canovio])
    }

    private func startReceive(_ info: (name: String, size: Int64)) {
        fileName = info.name
        fileSize = info.size
        transferred = 0
        let dest = AppPaths.uniqueFileURL(
            in: receiveDirectory,
            name: info.name.isEmpty ? "zmodem.bin" : info.name
        )
        try? FileManager.default.createDirectory(at: receiveDirectory, withIntermediateDirectories: true)
        fileURL = dest
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: dest)
        sendHex(type: zrpos, flags: [0, 0, 0, 0])
        publish(
            direction: .receive,
            fileName: info.name,
            total: info.size,
            message: "正在接收 \(info.name) → \(displayPath(dest))"
        )
    }

    private func parseFileInfo() -> (name: String, size: Int64)? {
        guard let frame = readDataSubframe() else { return nil }
        let parts = String(bytes: frame.data, encoding: .utf8)?
            .split(separator: "\0", omittingEmptySubsequences: false) ?? []
        guard let rawName = parts.first else { return nil }
        let name = URL(fileURLWithPath: String(rawName)).lastPathComponent
        var size: Int64 = 0
        if parts.count > 1 {
            let meta = parts[1].split(separator: " ")
            size = Int64(meta.first ?? "0") ?? 0
        }
        return (name, size)
    }

    /// Returns true when the current ZDATA stream ended and a header may follow.
    private func consumeDataFrames() -> Bool {
        while let frame = readDataSubframe() {
            try? fileHandle?.write(contentsOf: Data(frame.data))
            transferred += Int64(frame.data.count)
            publish(
                direction: .receive,
                fileName: fileName,
                transferred: transferred,
                total: fileSize,
                message: "正在接收 \(fileName)"
            )
            switch frame.end {
            case zcrcq:
                sendHex(type: zack, flags: positionBytes(UInt32(clamping: transferred)))
            case zcrcw:
                sendHex(type: zack, flags: positionBytes(UInt32(clamping: transferred)))
                receivingData = false
                return true
            case zcrce:
                receivingData = false
                return true
            default:
                break
            }
        }
        return false
    }

    private func pickFilesToSend() {
        if let filePicker {
            filePicker { [weak self] urls in
                guard let self else { return }
                if let urls, !urls.isEmpty {
                    self.beginSending(urls)
                } else {
                    self.failTransfer("已取消发送")
                }
            }
            return
        }
        let panel = NSOpenPanel()
        panel.title = "选择要发送到远程主机的文件（rz）"
        panel.message = "这些文件会通过 ZMODEM 发送到远程 rz。"
        panel.prompt = "发送"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        present(panel) { [weak self] response in
            guard let self else { return }
            if response == .OK {
                self.beginSending(panel.urls)
            } else {
                self.failTransfer("已取消发送")
            }
        }
    }

    private func present(_ panel: NSOpenPanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func sendNextFile() {
        closeSendHandle()
        ackWatch?.cancel()
        if sendIndex >= sendFiles.count {
            mode = .finishingSend
            sendHex(type: zfin, flags: [0, 0, 0, 0])
            finishWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.mode == .finishingSend else { return }
                self.failTransfer("远程 rz 未确认结束，已中止")
            }
            finishWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
            return
        }
        let url = sendFiles[sendIndex]
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        // ZMODEM positions are 32-bit, so 4 GiB is the hard ceiling.
        guard size < Int64(UInt32.max) else {
            failTransfer("\(url.lastPathComponent) 超过 4 GiB，ZMODEM 无法传输")
            return
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            failTransfer("无法读取 \(url.lastPathComponent)")
            return
        }
        sendHandle = handle
        sendOffset = 0
        fileName = url.lastPathComponent
        fileSize = size
        transferred = 0
        let remaining = sendFiles.count - sendIndex
        let info = Array("\(fileName)\0\(size) 0 100644 0 1 \(remaining)\0".utf8)
        // lrzsz sends ZFILE as a binary header. Keep CRC16 for compatibility.
        sendBin16(type: zfile, flags: [0, 0, 0, 0])
        sendSubframe(info, end: zcrcw)
        mode = .offeringFile
        publish(direction: .send, fileName: fileName, transferred: 0, total: fileSize, message: "正在发送 \(fileName)")
        armOfferWatch()
    }

    private func closeSendHandle() {
        try? sendHandle?.close()
        sendHandle = nil
    }

    private func armOfferWatch() {
        offerWatch?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mode == .offeringFile else { return }
            self.failTransfer("远程 rz 未确认文件，已中止。请重新运行 rz 后再试")
        }
        offerWatch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: work)
    }

    private func armAckWatch() {
        ackWatch?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mode == .transferring else { return }
            self.failTransfer("远程 rz 长时间无响应，已中止")
        }
        ackWatch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    /// Sends one window starting at `position`, then waits for the receiver.
    ///
    /// Queueing the whole file at once means a ZRPOS (retransmit) interleaves
    /// with megabytes of stale data that `rz` has to chew through before it
    /// finds a header, which times it out — and everything still queued then
    /// lands in the remote shell.
    private func sendWindow(from position: UInt64) {
        guard let handle = sendHandle else { return }
        if position != sendOffset {
            // Retransmit: stale queued data would interleave with the new one.
            discardPendingSends?()
        }
        sendOffset = position
        transferred = Int64(position)
        do {
            try handle.seek(toOffset: position)
        } catch {
            failTransfer("读取 \(fileName) 失败")
            return
        }
        if position >= UInt64(fileSize) {
            sendDataHeader(type: zeof, flags: positionBytes(UInt32(clamping: fileSize)))
            armAckWatch()
            return
        }

        sendDataHeader(type: zdata, flags: positionBytes(UInt32(clamping: position)))
        var budget = remoteBufferSize > 0 ? min(sendWindowSize, remoteBufferSize) : sendWindowSize
        var reachedEOF = false
        while budget > 0 {
            let chunk = (try? handle.read(upToCount: min(sendSubpacketSize, budget))) ?? Data()
            if chunk.isEmpty {
                reachedEOF = true
                break
            }
            budget -= chunk.count
            sendOffset += UInt64(chunk.count)
            transferred = Int64(sendOffset)
            reachedEOF = sendOffset >= UInt64(fileSize)
            sendSubframe([UInt8](chunk), end: reachedEOF ? zcrce : (budget <= 0 ? zcrcw : zcrcg))
            publish(
                direction: .send,
                fileName: fileName,
                transferred: transferred,
                total: fileSize,
                message: "正在发送 \(fileName)"
            )
            if reachedEOF { break }
        }
        if reachedEOF {
            sendDataHeader(type: zeof, flags: positionBytes(UInt32(clamping: sendOffset)))
        }
        armAckWatch()
    }

    private func scheduleFinish(message: String, error: Bool, savedPath: String? = nil, delay: TimeInterval = 0.9) {
        finishWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.finish(message: message, error: error, savedPath: savedPath)
        }
        finishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func finish(message: String, error: Bool, savedPath: String? = nil) {
        finishWork?.cancel()
        finishWork = nil
        offerWatch?.cancel()
        offerWatch = nil
        ackWatch?.cancel()
        ackWatch = nil
        try? fileHandle?.close()
        fileHandle = nil
        closeSendHandle()
        let leftover = buffer
        buffer.removeAll()
        awaitingFileInfo = false
        awaitingReceiveFolder = false
        pendingReceiveInfo = nil
        receivingData = false
        receiveCRC32 = false
        sendFiles = []
        sendIndex = 0
        sendOffset = 0
        // Both come from the peer's ZRINIT and must not leak into the next session.
        remoteBufferSize = 0
        escapeControls = false
        let direction: ZModemProgress.Direction = (mode == .offeringFile || mode == .transferring || mode == .pickingFiles || mode == .finishingSend)
            ? .send
            : .receive
        mode = .idle
        onProgress?(
            ZModemProgress(
                direction: direction,
                fileName: fileName,
                transferred: transferred,
                total: fileSize,
                message: message,
                isFinished: true,
                isError: error,
                savedPath: savedPath ?? fileURL?.path
            )
        )
        fileURL = nil
        let looksLikeZModem = leftover.contains(where: { $0 == zdle || $0 == zpad })
        if !leftover.isEmpty && !looksLikeZModem {
            onPassthrough?(leftover)
        }
    }

    private func publish(
        direction: ZModemProgress.Direction,
        fileName: String? = nil,
        transferred: Int64? = nil,
        total: Int64? = nil,
        message: String,
        finished: Bool = false,
        savedPath: String? = nil
    ) {
        onProgress?(
            ZModemProgress(
                direction: direction,
                fileName: fileName ?? self.fileName,
                transferred: transferred ?? self.transferred,
                total: total ?? self.fileSize,
                message: message,
                isFinished: finished,
                isError: false,
                savedPath: savedPath
            )
        )
    }

    private func displayPath(_ url: URL?) -> String {
        guard let url else { return "下载/TermoraX" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if url.path.hasPrefix(home) {
            return "~" + String(url.path.dropFirst(home.count))
        }
        return url.path
    }

    private struct Header {
        var type: UInt8
        var flags: [UInt8]
        var crc32: Bool = false
        var position: UInt64 {
            guard flags.count == 4 else { return 0 }
            return UInt64(flags[0]) | UInt64(flags[1]) << 8 | UInt64(flags[2]) << 16 | UInt64(flags[3]) << 24
        }
    }

    private func indexOfHeader(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4) {
            if bytes[i] == zpad && bytes[i + 1] == zpad && bytes[i + 2] == zdle {
                let kind = bytes[i + 3]
                if kind == zhex || kind == zbin || kind == zbin32 { return i }
            }
        }
        return nil
    }

    private func parseHeader() -> Header? {
        skipNoise()
        guard buffer.count >= 4 else { return nil }
        if buffer[0] == 0x4F, buffer.count >= 2, buffer[1] == 0x4F {
            buffer.removeFirst(2)
            finishWork?.cancel()
            finish(message: fileURL == nil ? "传输完成" : "已保存到 \(displayPath(fileURL))", error: false, savedPath: fileURL?.path)
            return nil
        }
        guard buffer[0] == zpad else { return nil }
        var i = 0
        while i < buffer.count, buffer[i] == zpad { i += 1 }
        guard i < buffer.count, buffer[i] == zdle else { return nil }
        i += 1
        guard i < buffer.count else { return nil }
        let kind = buffer[i]
        i += 1
        switch kind {
        case zhex:
            return parseHexHeader(start: i)
        case zbin, zbin32:
            return parseBinaryHeader(start: i, crc32: kind == zbin32)
        default:
            if !buffer.isEmpty { buffer.removeFirst() }
            return nil
        }
    }

    private func parseHexHeader(start: Int) -> Header? {
        let needed = start + 14
        guard buffer.count >= needed else { return nil }
        let hex = String(bytes: buffer[start..<needed], encoding: .ascii) ?? ""
        guard hex.count == 14, let decoded = hexDecode(hex), decoded.count >= 5 else {
            buffer.removeFirst(min(1, buffer.count))
            return nil
        }
        var consumed = needed
        if consumed < buffer.count, buffer[consumed] == 0x0D { consumed += 1 }
        if consumed < buffer.count,
           buffer[consumed] == 0x0A || buffer[consumed] == 0x8A {
            consumed += 1
        }
        if consumed < buffer.count, buffer[consumed] == 0x11 { consumed += 1 }
        buffer.removeFirst(consumed)
        return Header(type: decoded[0], flags: Array(decoded[1..<5]), crc32: false)
    }

    private func parseBinaryHeader(start: Int, crc32: Bool) -> Header? {
        var cursor = start
        var decoded: [UInt8] = []
        let want = 5 + (crc32 ? 4 : 2)
        while decoded.count < want {
            guard cursor < buffer.count else { return nil }
            let byte = buffer[cursor]
            cursor += 1
            if byte == zdle {
                guard cursor < buffer.count else { return nil }
                let next = buffer[cursor]
                cursor += 1
                decoded.append(unescape(next))
            } else {
                decoded.append(byte)
            }
        }
        buffer.removeFirst(cursor)
        return Header(type: decoded[0], flags: Array(decoded[1..<5]), crc32: crc32)
    }

    private func readDataSubframe() -> (data: [UInt8], end: UInt8)? {
        var i = 0
        var escaped = false
        var out: [UInt8] = []
        while i < buffer.count {
            let byte = buffer[i]
            i += 1
            if escaped {
                if byte == zcrce || byte == zcrcg || byte == zcrcq || byte == zcrcw {
                    let crcLen = receiveCRC32 ? 4 : 2
                    var crcRead = 0
                    while crcRead < crcLen, i < buffer.count {
                        let crcByte = buffer[i]
                        i += 1
                        if crcByte == zdle {
                            guard i < buffer.count else { return nil }
                            i += 1
                        }
                        crcRead += 1
                    }
                    if crcRead < crcLen { return nil }
                    buffer.removeFirst(i)
                    return (out, byte)
                }
                out.append(unescape(byte))
                escaped = false
            } else if byte == zdle {
                escaped = true
            } else {
                out.append(byte)
            }
        }
        return nil
    }

    private func sendHex(type: UInt8, flags: [UInt8]) {
        var bytes: [UInt8] = [zpad, zpad, zdle, zhex]
        let payload = [type] + flags
        var crc: UInt16 = 0
        // lrzsz's zgeth1() only decodes lowercase hex digits.
        for byte in payload {
            crc = crc16(byte, crc)
            bytes.append(contentsOf: Array(String(format: "%02x", byte).utf8))
        }
        bytes.append(contentsOf: Array(String(format: "%02x", crc >> 8).utf8))
        bytes.append(contentsOf: Array(String(format: "%02x", crc & 0xFF).utf8))
        // Match lrzsz: CR followed by LF with the parity bit set.
        bytes.append(contentsOf: [0x0D, 0x8A])
        if type != zack && type != zfin {
            bytes.append(0x11)
        }
        sendToHost?(bytes[...])
    }

    private func sendDataHeader(type: UInt8, flags: [UInt8]) {
        sendBin16(type: type, flags: flags)
    }

    private func sendBin16(type: UInt8, flags: [UInt8]) {
        var encoded: [UInt8] = [zpad, zdle, zbin]
        let payload = [type] + flags
        appendEscaped(payload, into: &encoded)
        var crc: UInt16 = 0
        for byte in payload { crc = crc16(byte, crc) }
        appendEscaped([UInt8(crc >> 8), UInt8(crc & 0xFF)], into: &encoded)
        sendToHost?(encoded[...])
    }

    private func sendBin32(type: UInt8, flags: [UInt8]) {
        var encoded: [UInt8] = [zpad, zdle, zbin32]
        let payload = [type] + flags
        appendEscaped(payload, into: &encoded)
        var crc: UInt32 = 0xFFFFFFFF
        for byte in payload { crc = crc32(byte, crc) }
        crc = ~crc
        let crcBytes = [
            UInt8(crc & 0xFF),
            UInt8((crc >> 8) & 0xFF),
            UInt8((crc >> 16) & 0xFF),
            UInt8((crc >> 24) & 0xFF),
        ]
        appendEscaped(crcBytes, into: &encoded)
        sendToHost?(encoded[...])
    }

    private func sendSubframe(_ data: [UInt8], end: UInt8) {
        var encoded: [UInt8] = []
        appendEscaped(data, into: &encoded)
        encoded.append(zdle)
        encoded.append(end)
        var crc: UInt16 = 0
        for byte in data { crc = crc16(byte, crc) }
        crc = crc16(end, crc)
        appendEscaped([UInt8(crc >> 8), UInt8(crc & 0xFF)], into: &encoded)
        if end == zcrcw {
            // ZMODEM requires XON after a wait-for-ACK subpacket.
            encoded.append(0x11)
        }
        sendToHost?(encoded[...])
    }

    private func appendEscaped(_ bytes: [UInt8], into output: inout [UInt8]) {
        for byte in bytes {
            if needsEscape(byte) {
                output.append(zdle)
                output.append(byte ^ 0x40)
            } else {
                output.append(byte)
            }
        }
    }

    private func needsEscape(_ byte: UInt8) -> Bool {
        // 0xFF must stay literal: ZDLE 0xBF is a protocol error for lrzsz's zdlread.
        if byte == zdle || byte == 0x10 || byte == 0x11 || byte == 0x13 ||
            byte == 0x90 || byte == 0x91 || byte == 0x93 {
            return true
        }
        if escapeControls && (byte & 0x60) == 0 {
            return true
        }
        return false
    }

    private func unescape(_ byte: UInt8) -> UInt8 {
        if byte == 0x6C { return 0x7F }
        if byte == 0x6D { return 0xFF }
        return byte ^ 0x40
    }

    private func skipNoise() {
        while let first = buffer.first, first != zpad && first != 0x4F {
            buffer.removeFirst()
        }
    }

    private func positionBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ]
    }

    private func hexDecode(_ hex: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        var chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        while !chars.isEmpty {
            let pair = String(chars[0...1])
            chars.removeFirst(2)
            guard let value = UInt8(pair, radix: 16) else { return nil }
            bytes.append(value)
        }
        return bytes
    }

    private func crc16(_ byte: UInt8, _ crc: UInt16) -> UInt16 {
        var value = crc ^ (UInt16(byte) << 8)
        for _ in 0..<8 {
            if value & 0x8000 != 0 {
                value = (value << 1) ^ 0x1021
            } else {
                value <<= 1
            }
        }
        return value
    }

    private func crc32(_ byte: UInt8, _ crc: UInt32) -> UInt32 {
        var value = crc ^ UInt32(byte)
        for _ in 0..<8 {
            if value & 1 != 0 {
                value = (value >> 1) ^ 0xEDB88320
            } else {
                value >>= 1
            }
        }
        return value
    }
}
