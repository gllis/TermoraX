//
//  TerminalRegistry.swift
//  TermoraX
//
//  按标签 ID 持有 TermoraTerminalView，避免 SwiftUI 刷新时拆掉 PTY。
//  字体、复制粘贴、ZMODEM 与 pty 写路径都在 TermoraTerminalView 里。
//

import AppKit
import Darwin
import Foundation
import SwiftTerm

/// 终端视图仓库。关闭标签时必须 `close`，否则 ssh 进程会残留。
final class TerminalRegistry {
    static let shared = TerminalRegistry()

    private var views: [UUID: TermoraTerminalView] = [:]

    func view(for tabID: UUID) -> TermoraTerminalView? {
        views[tabID]
    }

    func store(_ view: TermoraTerminalView, for tabID: UUID) {
        views[tabID] = view
    }

    func send(_ text: String, to tabID: UUID) {
        guard let view = views[tabID], !view.zmodem.isActive else { return }
        view.sendText(text)
    }

    func applyFontSize(_ size: CGFloat) {
        let font = TerminalFont.make(size: size)
        for view in views.values where abs(view.font.pointSize - font.pointSize) > 0.1 {
            view.font = font
        }
    }

    func applyZModemFolder() {
        let folder = AppSettings.shared.zmodemReceiveFolder
        for view in views.values {
            view.zmodem.receiveDirectory = folder
        }
    }

    func close(_ tabID: UUID) {
        if let view = views.removeValue(forKey: tabID) {
            view.terminate()
        }
    }
}

/// 等宽字体 + 中文 cascade，避免 CJK 变成 tofu。
enum TerminalFont {
    static func make(size: CGFloat = 13) -> NSFont {
        let base = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let families = ["PingFang SC", "PingFang TC", "Hiragino Sans GB", "Heiti SC"]
        let cascade = families.map { family in
            NSFontDescriptor(fontAttributes: [
                .family: family,
                .size: size,
            ])
        }
        let descriptor = base.fontDescriptor.addingAttributes([
            .cascadeList: cascade
        ])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    static func cjk(size: CGFloat) -> NSFont {
        NSFont(name: "PingFangSC-Regular", size: size)
            ?? NSFont(name: "HiraginoSansGB-W3", size: size)
            ?? NSFont(name: "PingFang SC", size: size)
            ?? NSFont.systemFont(ofSize: size)
    }
}

/// 排队中的 pty 写入的世代号。中止 ZMODEM 时递增，让还没落地的数据帧作废。
final class PtyWriteEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func bump() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

/// SwiftTerm 终端 + 本地/SSH 子进程。ZMODEM 帧走串行 pty 写，避免和键盘输入乱序。
final class TermoraTerminalView: TerminalView, TerminalViewDelegate, LocalProcessDelegate {
    let zmodem = ZModemEngine()
    private(set) var process: LocalProcess!
    var onZModem: ((ZModemProgress) -> Void)?
    var onTitle: ((String) -> Void)?
    private var started = false
    private var launch: (() -> Void)?
    private var syncingTerminalSize = false
    private var sizeNotifyWork: DispatchWorkItem?
    /// ZMODEM frames must reach the pty in order, so they bypass the concurrent
    /// DispatchIO writes used for keyboard input.
    private let ptyWriteQueue = DispatchQueue(label: "com.gllis.TermoraX.pty-write")
    private let ptyWriteEpoch = PtyWriteEpoch()

    private func writeToPty(_ bytes: ArraySlice<UInt8>) {
        guard let process, process.running else { return }
        let fd = process.childfd
        let payload = Array(bytes)
        let epoch = ptyWriteEpoch.current
        let epochBox = ptyWriteEpoch
        ptyWriteQueue.async {
            var offset = 0
            while offset < payload.count {
                guard epochBox.current == epoch else { return }
                let written = payload[offset...].withUnsafeBufferPointer { buffer in
                    write(fd, buffer.baseAddress!, buffer.count)
                }
                if written > 0 {
                    offset += written
                } else if errno == EAGAIN || errno == EINTR {
                    usleep(1000)
                } else {
                    return
                }
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        terminalDelegate = self
        process = LocalProcess(delegate: self)
        font = TerminalFont.make(size: AppSettings.shared.terminalFontSize)
        nativeForegroundColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        nativeBackgroundColor = NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1)
        caretColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        caretTextColor = NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1)
        zmodem.sendToHost = { [weak self] bytes in
            self?.writeToPty(bytes)
        }
        zmodem.discardPendingSends = { [weak self] in
            self?.ptyWriteEpoch.bump()
        }
        zmodem.onProgress = { [weak self] progress in
            DispatchQueue.main.async {
                self?.onZModem?(progress)
            }
        }
        zmodem.onPassthrough = { [weak self] bytes in
            guard let self, !bytes.isEmpty else { return }
            self.feed(byteArray: bytes[...])
        }
    }

    func prepareLaunch(_ work: @escaping () -> Void) {
        launch = work
        tryStart()
    }

    func start(
        executable: String,
        args: [String],
        environment: [String]?,
        currentDirectory: String?
    ) {
        process.startProcess(
            executable: executable,
            args: args,
            environment: environment,
            execName: nil,
            currentDirectory: currentDirectory
        )
        notifyPtySize()
    }

    func sendText(_ text: String) {
        writeToPty(Array(text.utf8)[...])
    }

    func terminate() {
        process.terminate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tryStart()
    }

    /// 1.19 already recomputes cols/rows in `setFrameSize`; keep the SwiftUI
    /// frame sync so `tryStart` sees a real size.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !syncingTerminalSize {
            syncingTerminalSize = true
            frame = CGRect(origin: frame.origin, size: newSize)
            syncingTerminalSize = false
        }
        tryStart()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        syncSizeFromBounds()
        notifyPtySize()
    }

    override func rightMouseDown(with event: NSEvent) {
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        let mouseTakesOver = allowMouseReporting && terminal.mouseMode != .off
        if AppSettings.shared.quickCopyPaste, !event.modifierFlags.contains(.shift), !mouseTakesOver {
            paste(nil)
            return
        }
        let menu = NSMenu()
        let copyItem = menu.addItem(withTitle: "复制", action: #selector(copy(_:)), keyEquivalent: "c")
        copyItem.target = self
        copyItem.isEnabled = selectionActive
        let pasteItem = menu.addItem(withTitle: "粘贴", action: #selector(paste(_:)), keyEquivalent: "v")
        pasteItem.target = self
        let selectItem = menu.addItem(withTitle: "全选", action: #selector(selectAll(_:)), keyEquivalent: "a")
        selectItem.target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard AppSettings.shared.quickCopyPaste, selectionActive else { return }
        let text = getSelection() ?? ""
        guard !text.isEmpty else { return }
        copy(nil)
    }

    @objc override func copy(_ sender: Any?) {
        let str = getSelection() ?? ""
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(str, forType: .string)
    }

    override func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard selectionActive, let text = getSelection() else { return nil }
        actualRange?.pointee = selectedRange()
        return NSAttributedString(string: text)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AppKit sends this to every view in the window. Only handle Cmd-C/V/A
        // when the terminal actually has focus, otherwise path fields and other
        // text views cannot paste.
        guard isInResponderChain(window?.firstResponder) else { return false }
        let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        guard command, !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.option) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "c", "C":
            copy(nil)
            return true
        case "v", "V":
            paste(nil)
            return true
        case "a", "A":
            selectAll(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    private func isInResponderChain(_ responder: NSResponder?) -> Bool {
        var current = responder
        while let node = current {
            if node === self { return true }
            current = node.nextResponder
        }
        return false
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(paste(_:)), #selector(selectAll(_:)):
            return true
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    private func syncSizeFromBounds() {
        guard !syncingTerminalSize else { return }
        syncingTerminalSize = true
        frame = frame
        syncingTerminalSize = false
    }

    private func tryStart() {
        guard !started, window != nil, let launch else { return }
        guard bounds.width >= 320, bounds.height >= 140 else { return }
        syncSizeFromBounds()
        if let terminal, terminal.cols < 20 || terminal.rows < 5 { return }
        started = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            launch()
            self.notifyPtySize()
            self.window?.makeFirstResponder(self)
        }
    }

    private func notifyPtySize() {
        sizeNotifyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.process.running else { return }
            var size = self.getWindowSize()
            _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: self.process.childfd, windowSize: &size)
        }
        sizeNotifyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        guard let remaining = zmodem.ingest(slice), !remaining.isEmpty else { return }
        feed(byteArray: remaining[...])
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        let display: String
        if let exitCode {
            let code = exitCode > 255 ? (exitCode >> 8) & 0xFF : exitCode
            display = "\(code)"
        } else {
            display = "?"
        }
        feed(text: "\r\n\u{1b}[90m会话已结束，退出码 \(display)。\u{1b}[0m\r\n")
    }

    func getWindowSize() -> winsize {
        // Must match SwiftTerm's cols/rows. A second, independently estimated
        // size made `ls` think the screen was wider than the emulator.
        let cols = max(2, terminal?.cols ?? columnsFromBounds())
        let rows = max(1, terminal?.rows ?? rowsFromBounds())
        return winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(cols),
            ws_xpixel: UInt16(max(bounds.width, 1)),
            ws_ypixel: UInt16(max(bounds.height, 1))
        )
    }

    private func columnsFromBounds() -> Int {
        let cell = estimatedCellSize()
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        return max(2, Int((bounds.width - scroller) / cell.width))
    }

    private func rowsFromBounds() -> Int {
        let cell = estimatedCellSize()
        return max(1, Int(bounds.height / cell.height))
    }

    private func estimatedCellSize() -> NSSize {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let size = ("W" as NSString).size(withAttributes: attributes)
        return NSSize(width: max(size.width, 7), height: max(size.height, 14))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        notifyPtySize()
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        onTitle?(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if let interrupt = interruptByte(in: data) {
            if zmodem.isActive {
                zmodem.cancel()
            }
            process.sendControlAndDropOutput(interrupt)
            return
        }
        if zmodem.isActive {
            return
        }
        writeToPty(data)
    }

    /// Only a lone control byte counts. Scanning pasted text would turn a stray
    /// 0x03 into an interrupt.
    private func interruptByte(in data: ArraySlice<UInt8>) -> UInt8? {
        guard data.count == 1, let byte = data.first else { return nil }
        switch byte {
        case 0x03, 0x1a, 0x1c: return byte
        default: return nil
        }
    }

    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), deliverInterruptKey(event) { return }
        super.keyDown(with: event)
    }

    /// Only SIGINT / SIGTSTP / SIGQUIT. Other Ctrl+letter keys must reach the IME.
    @discardableResult
    private func deliverInterruptKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.control), !mods.contains(.command) else { return false }
        let byte: UInt8
        switch event.keyCode {
        case 0x08: byte = 0x03 // C
        case 0x06: byte = 0x1A // Z
        case 0x2A: byte = 0x1C // \
        default: return false
        }
        send(source: self, data: [byte][...])
        return true
    }

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }

    func bell(source: TerminalView) {
        NSSound.beep()
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// SwiftUI 宿主：把同一个 `TermoraTerminalView` 重新挂到新的 NSView 树上，PTY 不断。
final class TerminalHostView: NSView {
    let terminal: TermoraTerminalView

    init(terminal: TermoraTerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1).cgColor
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = true
        terminal.autoresizingMask = []
        addSubview(terminal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        applyTerminalFrame()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyTerminalFrame()
    }

    private func applyTerminalFrame() {
        let next = bounds.integral
        guard next.width >= 80, next.height >= 40 else { return }
        if terminal.frame != next {
            terminal.frame = next
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(terminal) ?? false
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        var current = window?.firstResponder
        while let node = current {
            if node === self || node === terminal {
                return terminal.performKeyEquivalent(with: event)
            }
            current = node.nextResponder
        }
        return false
    }
}
