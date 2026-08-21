//
//  TermoraXApp.swift
//  TermoraX
//

import SwiftData
import SwiftUI

@main
struct TermoraXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            SessionNode.self,
            QuickCommand.self,
        ])
        let modelConfiguration = ModelConfiguration(
            "TermoraX",
            isStoredInMemoryOnly: false
        )
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 1400, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建会话") {
                    NotificationCenter.default.post(name: .termoraNewSession, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])
                Button("新建分组") {
                    NotificationCenter.default.post(name: .termoraNewGroup, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .navigationTitle("设置")
        }
        .windowResizability(.contentSize)
    }
}

extension Notification.Name {
    static let termoraNewSession = Notification.Name("termora.newSession")
    static let termoraNewGroup = Notification.Name("termora.newGroup")
}

#Preview {
    ContentView()
        .modelContainer(for: [SessionNode.self, QuickCommand.self], inMemory: true)
}
