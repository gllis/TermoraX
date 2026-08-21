import Foundation

// Drives ZModemEngine against real lrzsz binaries over a pty, in both
// directions, and verifies the transferred bytes.

let szPath = "/opt/homebrew/bin/sz"
let rzPath = "/opt/homebrew/bin/rz"

let root = URL(fileURLWithPath: "/tmp/zmodem-workdir", isDirectory: true)
try? FileManager.default.removeItem(at: root)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

func makePayload(_ bytes: Int) -> Data {
    var data = Data(capacity: bytes)
    var value: UInt8 = 0
    for i in 0..<bytes {
        // Include the bytes ZMODEM must escape: 0x18, 0x10, 0x11, 0x13, 0xff, 0x0d, 0x0a
        switch i % 16 {
        case 0: data.append(0x18)
        case 1: data.append(0x10)
        case 2: data.append(0x11)
        case 3: data.append(0x13)
        case 4: data.append(0xFF)
        case 5: data.append(0x0D)
        case 6: data.append(0x0A)
        case 7: data.append(0x8A)
        default:
            data.append(value)
            value = value &+ 37
        }
    }
    return data
}

final class PtyChild {
    let master: Int32
    let process: Process
    private let source: DispatchSourceRead
    private var stderrData = Data()

    init(executable: String, args: [String], cwd: URL, onOutput: @escaping ([UInt8]) -> Void) throws {
        var m: Int32 = 0
        var s: Int32 = 0
        guard openpty(&m, &s, nil, nil, nil) == 0 else {
            throw NSError(domain: "pty", code: 1)
        }
        master = m

        var raw = termios()
        tcgetattr(s, &raw)
        cfmakeraw(&raw)
        tcsetattr(s, TCSANOW, &raw)

        let slaveHandle = FileHandle(fileDescriptor: s, closeOnDealloc: true)
        let errPipe = Pipe()
        process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = cwd
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = errPipe
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        process.environment = env

        source = DispatchSource.makeReadSource(fileDescriptor: m, queue: .main)
        source.setEventHandler {
            var buf = [UInt8](repeating: 0, count: 8192)
            let n = read(m, &buf, buf.count)
            if n > 0 {
                onOutput(Array(buf[0..<n]))
            }
        }
        source.resume()

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty { self?.stderrData.append(data) }
        }

        try process.run()
        close(s)
    }

    func write(_ bytes: ArraySlice<UInt8>) {
        var array = Array(bytes)
        var offset = 0
        while offset < array.count {
            let written = array[offset...].withUnsafeBufferPointer { ptr in
                Darwin.write(master, ptr.baseAddress!, ptr.count)
            }
            if written <= 0 {
                if errno == EAGAIN { usleep(2000); continue }
                FileHandle.standardError.write("pty write failed errno=\(errno)\n".data(using: .utf8)!)
                return
            }
            offset += written
        }
    }

    var stderrText: String { String(data: stderrData, encoding: .utf8) ?? "" }

    func stop() {
        source.cancel()
        if process.isRunning { process.terminate() }
        close(master)
    }
}

func pump(until deadline: Date, done: () -> Bool) -> Bool {
    while Date() < deadline {
        if done() { return true }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return done()
}

var failures = 0

func runDownloadTest(size: Int) {
    let name = "down_\(size).bin"
    let remoteDir = root.appendingPathComponent("remote_\(size)", isDirectory: true)
    let localDir = root.appendingPathComponent("local_\(size)", isDirectory: true)
    try? FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
    let payload = makePayload(size)
    let src = remoteDir.appendingPathComponent(name)
    try? payload.write(to: src)

    let engine = ZModemEngine()
    engine.receiveDirectory = localDir
    var finished = false
    var result = ""
    var isError = false
    engine.onProgress = { progress in
        if progress.isFinished {
            finished = true
            result = progress.message
            isError = progress.isError
        }
    }

    var child: PtyChild?
    do {
        child = try PtyChild(executable: szPath, args: [name], cwd: remoteDir) { bytes in
            _ = engine.ingest(bytes[...])
        }
    } catch {
        print("FAIL download(\(size)): cannot start sz: \(error)")
        failures += 1
        return
    }
    engine.sendToHost = { bytes in child?.write(bytes) }

    let ok = pump(until: Date().addingTimeInterval(25)) { finished }
    child?.stop()

    let dest = localDir.appendingPathComponent(name)
    let got = (try? Data(contentsOf: dest)) ?? Data()
    if !ok {
        print("FAIL download(\(size)): timed out, got \(got.count)/\(size) bytes. stderr=\(child?.stderrText ?? "")")
        failures += 1
    } else if isError {
        print("FAIL download(\(size)): \(result)")
        failures += 1
    } else if got != payload {
        print("FAIL download(\(size)): content mismatch, got \(got.count)/\(size) bytes")
        failures += 1
    } else {
        print("ok   download(\(size)): \(result)")
    }
}

func runUploadTest(size: Int) {
    let name = "up_\(size).bin"
    let remoteDir = root.appendingPathComponent("rremote_\(size)", isDirectory: true)
    let localDir = root.appendingPathComponent("rlocal_\(size)", isDirectory: true)
    try? FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
    let payload = makePayload(size)
    let src = localDir.appendingPathComponent(name)
    try? payload.write(to: src)

    let engine = ZModemEngine()
    engine.receiveDirectory = localDir
    engine.filePicker = { completion in completion([src]) }
    var finished = false
    var result = ""
    var isError = false
    engine.onProgress = { progress in
        if progress.isFinished {
            finished = true
            result = progress.message
            isError = progress.isError
        }
    }

    var child: PtyChild?
    do {
        child = try PtyChild(executable: rzPath, args: [], cwd: remoteDir) { bytes in
            _ = engine.ingest(bytes[...])
        }
    } catch {
        print("FAIL upload(\(size)): cannot start rz: \(error)")
        failures += 1
        return
    }
    engine.sendToHost = { bytes in child?.write(bytes) }

    let ok = pump(until: Date().addingTimeInterval(30)) { finished }
    _ = pump(until: Date().addingTimeInterval(1.5)) { false }
    child?.stop()

    let dest = remoteDir.appendingPathComponent(name)
    let got = (try? Data(contentsOf: dest)) ?? Data()
    if !ok {
        print("FAIL upload(\(size)): timed out, remote has \(got.count)/\(size) bytes. stderr=\(child?.stderrText ?? "")")
        failures += 1
    } else if isError {
        print("FAIL upload(\(size)): \(result). remote has \(got.count)/\(size) bytes")
        failures += 1
    } else if got != payload {
        print("FAIL upload(\(size)): content mismatch, remote has \(got.count)/\(size) bytes")
        failures += 1
    } else {
        print("ok   upload(\(size)): \(result)")
    }
}

let sizes = CommandLine.arguments.dropFirst().compactMap { Int($0) }
let plan = sizes.isEmpty ? [64, 4096, 200_000] : sizes
for size in plan {
    runDownloadTest(size: size)
}
for size in plan {
    runUploadTest(size: size)
}

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
