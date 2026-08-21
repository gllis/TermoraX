//
//  AppSettings.swift
//  TermoraX
//

import Foundation
import Observation

enum CloseBehavior: String, CaseIterable, Identifiable {
    case hideToDock
    case quit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hideToDock: return "隐藏到 Dock"
        case .quit: return "退出程序"
        }
    }
}

struct WorkspaceSnapshot: Codable, Equatable {
    var tabs: [PersistedTab]
    var selectedTabID: UUID?
}

struct PersistedTab: Codable, Equatable {
    enum Kind: String, Codable {
        case terminal
        case sftp
        case local
    }

    var id: UUID
    var kind: Kind
    var sessionID: UUID?
    var title: String
}

@Observable
final class AppSettings {
    static let shared = AppSettings()

    static let minFontSize = 10.0
    static let maxFontSize = 24.0
    static let defaultFontSize = 13.0
    static let defaultActivityInterval = 60

    var terminalFontSize: Double {
        didSet {
            let clamped = min(max(terminalFontSize, Self.minFontSize), Self.maxFontSize)
            if clamped != terminalFontSize {
                terminalFontSize = clamped
                return
            }
            persist(terminalFontSize, key: Key.fontSize)
        }
    }

    var quickCopyPaste: Bool {
        didSet { persist(quickCopyPaste, key: Key.quickCopyPaste) }
    }

    var closeBehavior: CloseBehavior {
        didSet { persist(closeBehavior.rawValue, key: Key.closeBehavior) }
    }

    var zmodemReceivePath: String {
        didSet { persist(zmodemReceivePath, key: Key.zmodemPath) }
    }

    /// Seconds. Used to snapshot open tabs and as SSH `ServerAliveInterval`. `0` disables both.
    var activitySaveInterval: Int {
        didSet {
            let clamped = min(max(activitySaveInterval, 0), 3600)
            if clamped != activitySaveInterval {
                activitySaveInterval = clamped
                return
            }
            persist(activitySaveInterval, key: Key.activityInterval)
        }
    }

    var zmodemReceiveFolder: URL {
        get {
            let path = zmodemReceivePath
            if !path.isEmpty {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    return URL(fileURLWithPath: path, isDirectory: true)
                }
            }
            return AppPaths.userDownloads
        }
        set {
            zmodemReceivePath = newValue.path
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        let storedSize = defaults.object(forKey: Key.fontSize) as? Double ?? Self.defaultFontSize
        terminalFontSize = min(max(storedSize, Self.minFontSize), Self.maxFontSize)
        quickCopyPaste = defaults.bool(forKey: Key.quickCopyPaste)
        closeBehavior = CloseBehavior(rawValue: defaults.string(forKey: Key.closeBehavior) ?? "") ?? .hideToDock
        zmodemReceivePath = defaults.string(forKey: Key.zmodemPath) ?? AppPaths.userDownloads.path
        let storedInterval = defaults.object(forKey: Key.activityInterval) as? Int
        activitySaveInterval = storedInterval ?? Self.defaultActivityInterval
    }

    func loadSnapshot() -> WorkspaceSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: Key.workspaceSnapshot) else { return nil }
        return try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
    }

    func saveSnapshot(_ snapshot: WorkspaceSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Key.workspaceSnapshot)
        }
    }

    private func persist(_ value: Any, key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private enum Key {
        static let fontSize = "settings.terminalFontSize"
        static let quickCopyPaste = "settings.quickCopyPaste"
        static let closeBehavior = "settings.closeBehavior"
        static let zmodemPath = "zmodemReceiveFolder"
        static let activityInterval = "settings.activitySaveInterval"
        static let workspaceSnapshot = "settings.workspaceSnapshot"
    }
}
