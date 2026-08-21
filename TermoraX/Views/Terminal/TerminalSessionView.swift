//
//  TerminalSessionView.swift
//  TermoraX
//

import SwiftTerm
import SwiftUI

struct TerminalSessionView: NSViewRepresentable {
    let tab: WorkspaceTab
    let session: SessionNode?
    let transfers: TransferCenter
    var onTitle: (String) -> Void
    var fontSize: CGFloat

    func makeNSView(context: Context) -> TerminalHostView {
        if let existing = TerminalRegistry.shared.view(for: tab.id) {
            return TerminalHostView(terminal: existing)
        }

        let terminal = TermoraTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        terminal.onTitle = onTitle
        terminal.onZModem = { progress in
            transfers.zmodem = progress
            if progress.isFinished {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                    if transfers.zmodem?.isFinished == true {
                        transfers.zmodem = nil
                    }
                }
            }
        }
        TerminalRegistry.shared.store(terminal, for: tab.id)
        terminal.prepareLaunch { [weak terminal] in
            guard let terminal else { return }
            launch(terminal)
        }
        return TerminalHostView(terminal: terminal)
    }

    func updateNSView(_ nsView: TerminalHostView, context: Context) {
        nsView.terminal.onTitle = onTitle
        nsView.terminal.onZModem = { progress in
            transfers.zmodem = progress
            if progress.isFinished {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                    if transfers.zmodem?.isFinished == true {
                        transfers.zmodem = nil
                    }
                }
            }
        }
        let font = TerminalFont.make(size: fontSize)
        if abs(nsView.terminal.font.pointSize - font.pointSize) > 0.1 {
            nsView.terminal.font = font
        }
        nsView.terminal.zmodem.receiveDirectory = AppSettings.shared.zmodemReceiveFolder
    }

    private func launch(_ terminal: TermoraTerminalView) {
        let environment = SSHCommand.processEnvironment()
        switch tab.kind {
        case .local:
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            terminal.start(
                executable: shell,
                args: ["-l"],
                environment: environment,
                currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path
            )
        case .terminal:
            guard let session, session.isSSH, !session.host.isEmpty else {
                terminal.feed(text: "\r\n该会话尚未配置主机地址。请在会话管理器中编辑后再连接。\r\n")
                return
            }
            let launch = SSHCommand.terminalLaunch(for: session)
            if let secret = launch.secret {
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                    try? FileManager.default.removeItem(at: secret)
                }
            }
            terminal.start(
                executable: SSHCommand.executable,
                args: launch.args,
                environment: launch.env,
                currentDirectory: nil
            )
        case .sftp:
            break
        }
    }
}
