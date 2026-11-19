//
//  EnglishInputSource.swift
//  TermoraX
//
//  把当前键盘输入法切到英文键盘布局（ABC / U.S. 等），而不是中文输入法的英文模式。
//

import AppKit
import Carbon
import Foundation

enum EnglishInputSource {
    /// 设置关闭时不做任何事。调用方不用各自判断开关。
    static func activateIfEnabled() {
        guard AppSettings.shared.autoSwitchEnglishInput else { return }
        selectEnglishKeyboard()
    }

    /// 主窗口重新成为焦点、且当前有标签时调用。正在编辑文本框时不打断。
    static func activateForKeyWindow(_ window: NSWindow) {
        guard AppSettings.shared.autoSwitchEnglishInput else { return }
        guard window.attachedSheet == nil else { return }
        guard AppDelegate.workspace?.selectedTab != nil else { return }
        if let responder = window.firstResponder, isTextEditor(responder) {
            return
        }
        selectEnglishKeyboard()
    }

    private static func selectEnglishKeyboard() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { selectEnglishKeyboard() }
            return
        }
        guard let source = englishKeyboardLayout() else { return }
        if let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           sameSource(current, source) {
            return
        }
        TISSelectInputSource(source)
    }

    /// 优先用系统为 “en” 选定的键盘布局；否则退回最近用过的 ASCII 键盘布局。
    private static func englishKeyboardLayout() -> TISInputSource? {
        if let match = TISCopyInputSourceForLanguage("en" as CFString)?.takeRetainedValue(),
           sourceType(match) == kTISTypeKeyboardLayout as String {
            return match
        }
        return TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
    }

    private static func sameSource(_ lhs: TISInputSource, _ rhs: TISInputSource) -> Bool {
        guard let left = stringProperty(lhs, key: kTISPropertyInputSourceID),
              let right = stringProperty(rhs, key: kTISPropertyInputSourceID) else {
            return false
        }
        return left == right
    }

    private static func sourceType(_ source: TISInputSource) -> String? {
        stringProperty(source, key: kTISPropertyInputSourceType)
    }

    private static func stringProperty(_ source: TISInputSource, key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func isTextEditor(_ responder: NSResponder) -> Bool {
        if responder is NSTextField { return true }
        if let text = responder as? NSTextView {
            return text.isFieldEditor
        }
        return false
    }
}
