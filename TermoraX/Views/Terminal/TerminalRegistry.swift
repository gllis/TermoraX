//
//  TerminalRegistry.swift
//  TermoraX
//

import AppKit
import Darwin
import Foundation
import SwiftTerm

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

    func close(_ tabID: UUID) {
        if let view = views.removeValue(forKey: tabID) {
            view.terminate()
        }
    }
}

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

final class TermoraTerminalView: TerminalView, TerminalViewDelegate, LocalProcessDelegate {
    let zmodem = ZModemEngine()
    private(set) var process: LocalProcess!
    var onZModem: ((ZModemProgress) -> Void)?
    var onTitle: ((String) -> Void)?
    private var started = false
    private var launch: (() -> Void)?
    private var syncingTerminalSize = false
    private var sizeNotifyWork: DispatchWorkItem?

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
        font = TerminalFont.make()
        nativeForegroundColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        nativeBackgroundColor = NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1)
        caretColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        caretTextColor = NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1)
        zmodem.sendToHost = { [weak self] bytes in
            self?.process.send(data: bytes)
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
        let bytes = Array(text.utf8)
        process.send(data: bytes[...])
    }

    func terminate() {
        process.terminate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tryStart()
    }

    /// SwiftTerm 1.5.1 only updates cols/rows in the `frame` setter, not `setFrameSize`.
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
        let menu = NSMenu()
        menu.addItem(withTitle: "复制", action: #selector(copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "粘贴", action: #selector(paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "全选", action: #selector(selectAll(_:)), keyEquivalent: "a")
        NSMenu.popUpContextMenu(menu, with: event, for: self)
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
        if zmodem.isActive {
            if data.contains(0x03) {
                zmodem.cancel()
            }
            return
        }
        process.send(data: data)
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
}
