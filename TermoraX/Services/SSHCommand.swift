//
//  SSHCommand.swift
//  TermoraX
//

import Foundation

enum SSHCommand {
    static let executable = "/usr/bin/ssh"

    static func user(for node: SessionNode) -> String {
        user(username: node.username)
    }

    static func user(username: String) -> String {
        username.isEmpty ? NSUserName() : username
    }

    private static func effectiveAuthMethod(for node: SessionNode) -> String {
        if node.authMethod == "key" { return "key" }
        if node.authMethod == "password" { return "password" }
        if SecretStore.password(for: node.id) != nil { return "password" }
        return node.authMethod
    }

    static func target(from node: SessionNode) -> SSHTarget {
        SSHTarget(
            id: node.id,
            host: node.host,
            port: node.port,
            username: node.username,
            authMethod: effectiveAuthMethod(for: node),
            privateKeyPath: node.privateKeyPath,
            sftpDefaultPath: node.sftpDefaultPath
        )
    }

    static func baseOptions(for node: SessionNode) -> [String] {
        baseOptions(for: target(from: node))
    }

    static func baseOptions(for target: SSHTarget) -> [String] {
        var args = [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UpdateHostKeys=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "ControlMaster=auto",
            "-o", option("ControlPath", AppPaths.controlPathTemplate),
            "-o", "ControlPersist=120",
            "-p", "\(target.port)",
        ]
        if target.authMethod == "key" {
            let key = AppPaths.expandHome(target.privateKeyPath)
            if !key.isEmpty {
                args += ["-i", key, "-o", "IdentitiesOnly=yes"]
            }
        }
        if target.authMethod == "password" {
            args += [
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "PubkeyAuthentication=no",
                "-o", "PasswordAuthentication=yes",
                "-o", "NumberOfPasswordPrompts=1",
                "-o", "KbdInteractiveAuthentication=yes",
            ]
        }
        return args
    }

    /// OpenSSH treats each `-o` value as a config-file line and splits on unquoted spaces.
    private static func option(_ key: String, _ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\(key)=\"\(escaped)\""
    }

    static func terminalArguments(for node: SessionNode) -> [String] {
        terminalArguments(for: target(from: node))
    }

    static func terminalArguments(for target: SSHTarget) -> [String] {
        baseOptions(for: target) + ["-tt", "\(user(username: target.username))@\(target.host)"]
    }

    static func sftpArguments(for node: SessionNode) -> [String] {
        sftpArguments(for: target(from: node))
    }

    static func sftpArguments(for target: SSHTarget) -> [String] {
        baseOptions(for: target) + ["\(user(username: target.username))@\(target.host)", "-s", "sftp"]
    }

    static func processEnvironment(extra: [String: String] = [:]) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = utf8Lang(env["LANG"])
        env["LC_CTYPE"] = env["LANG"]
        extra.forEach { env[$0.key] = $0.value }
        return env.map { "\($0.key)=\($0.value)" }
    }

    private static func utf8Lang(_ current: String?) -> String {
        if let current, current.contains("UTF-8") || current.contains("utf8") {
            return current
        }
        let pref = Locale.preferredLanguages.first ?? ""
        if pref.hasPrefix("zh-Hant") || pref.hasPrefix("zh-TW") || pref.hasPrefix("zh-HK") {
            return "zh_TW.UTF-8"
        }
        if pref.hasPrefix("zh") {
            return "zh_CN.UTF-8"
        }
        return "en_US.UTF-8"
    }

    static func askpassEnvironment(password: String?) -> (env: [String: String], secret: URL?) {
        guard let password, !password.isEmpty else { return ([:], nil) }
        let secret = AppPaths.writeAskpassSecret(password)
        return ([
            "SSH_ASKPASS": AppPaths.ensureAskpass(),
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": ProcessInfo.processInfo.environment["DISPLAY"] ?? ":0",
            "TERMORAX_ASKPASS_FILE": secret.path,
        ], secret)
    }

    static func terminalLaunch(for session: SessionNode) -> (args: [String], env: [String], secret: URL?) {
        let stored = session.authMethod == "key" ? nil : SecretStore.password(for: session.id)
        let ask = askpassEnvironment(password: stored)
        return (terminalArguments(for: session), processEnvironment(extra: ask.env), ask.secret)
    }
}

struct SSHTarget: Sendable {
    let id: UUID
    let host: String
    let port: Int
    let username: String
    let authMethod: String
    let privateKeyPath: String
    let sftpDefaultPath: String
}
