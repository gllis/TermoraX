//
//  AppDelegate.swift
//  TermoraX
//
//  处理 Dock 点击恢复、最后一扇窗口是否退出，以及关闭按钮「隐藏到 Dock」。
//

import AppKit

/// 桥接 AppKit 生命周期。SwiftUI `WindowGroup` 本身拦不到红灯关闭。
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var workspace: WorkspaceController?

    private let windowProxy = WindowCloseProxy()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Broken SSH/SFTP pipes otherwise deliver SIGPIPE and abort the app.
        signal(SIGPIPE, SIG_IGN)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        AppSettings.shared.closeBehavior == .quit
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.unhide(nil)
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.workspace?.persistActivity()
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        guard window.identifier?.rawValue == "TermoraX.main" else { return }
        windowProxy.attach(to: window)
    }
}

/// 接到主窗口 `delegate` 上，转发 SwiftUI 原有代理，只改写 `windowShouldClose`。
final class WindowCloseProxy: NSObject, NSWindowDelegate {
    private weak var window: NSWindow?
    private weak var previous: NSWindowDelegate?

    func attach(to window: NSWindow) {
        if self.window === window, window.delegate === self { return }
        if let current = self.window, current !== window, current.delegate === self {
            current.delegate = previous
        }
        self.window = window
        if window.delegate !== self {
            previous = window.delegate
            window.delegate = self
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if AppSettings.shared.closeBehavior == .hideToDock {
            NSApp.hide(nil)
            return false
        }
        AppDelegate.workspace?.persistActivity()
        return previous?.windowShouldClose?(sender) ?? true
    }

    override func responds(to aSelector: Selector) -> Bool {
        if super.responds(to: aSelector) { return true }
        return (previous as? NSObject)?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector) -> Any? {
        previous
    }
}
