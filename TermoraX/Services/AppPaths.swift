//
//  AppPaths.swift
//  TermoraX
//

import Foundation

enum AppPaths {
    static var support: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TermoraX", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Must not contain spaces: OpenSSH parses `-o ControlPath=...` as a config line
    /// and splits on whitespace (`Application Support` would become "extra arguments").
    static var muxDirectory: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TermoraX", isDirectory: true)
            .appendingPathComponent("mux", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// User's Downloads folder (the default `sz` destination).
    static var userDownloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    /// Legacy fallback used before settings existed.
    static var downloads: URL { userDownloads }

    static var zmodemReceiveFolder: URL {
        get { AppSettings.shared.zmodemReceiveFolder }
        set { AppSettings.shared.zmodemReceiveFolder = newValue }
    }

    static func uniqueFileURL(in directory: URL, name: String) -> URL {
        let safe = name.isEmpty ? "zmodem.bin" : name
        var url = directory.appendingPathComponent(safe)
        if !FileManager.default.fileExists(atPath: url.path) { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 1
        repeat {
            let candidate = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            url = directory.appendingPathComponent(candidate)
            index += 1
        } while FileManager.default.fileExists(atPath: url.path)
        return url
    }

    /// `%C` is a short hash of the connection, keeping the UNIX socket path under macOS' ~104 byte limit.
    static var controlPathTemplate: String {
        muxDirectory.appendingPathComponent("%C").path
    }

    static func controlSocket(user: String, host: String, port: Int) -> URL {
        muxDirectory.appendingPathComponent("\(user)@\(host):\(port)")
    }

    static func expandHome(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == "~" { return home }
        if path.hasPrefix("~/") {
            return home + String(path.dropFirst(1))
        }
        return path
    }

    static func ensureAskpass() -> String {
        let url = muxDirectory.deletingLastPathComponent().appendingPathComponent("askpass.sh")
        let script = """
        #!/bin/sh
        if [ -n "$TERMORAX_ASKPASS_FILE" ] && [ -f "$TERMORAX_ASKPASS_FILE" ]; then
          cat "$TERMORAX_ASKPASS_FILE"
          exit 0
        fi
        exit 1
        """
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    static func writeAskpassSecret(_ password: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("termorax-askpass-\(UUID().uuidString)")
        try? password.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}
