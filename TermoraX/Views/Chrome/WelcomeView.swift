//
//  WelcomeView.swift
//  TermoraX
//

import AppKit
import SwiftUI

struct WelcomeView: View {
    var workspace: WorkspaceController

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("TermoraX")
                .font(.largeTitle.weight(.semibold))
            Text("会话管理器、快速命令、选项卡和文件管理器，用来管理远程主机。用工具栏按钮显示或隐藏各个面板。")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 640)
            HStack(spacing: 16) {
                feature("会话管理器", "左侧树形结构，支持自定义分组", "sidebar.left")
                feature("选项卡 / 快速命令", "多会话并行，一键发送常用命令", "rectangle.stack")
                feature("SFTP / rz sz", "图形化文件管理，终端内 ZMODEM 传输", "arrow.up.arrow.down.circle")
            }
            .padding(.top, 8)
            HStack(spacing: 12) {
                Button("新建会话") { workspace.pendingEdit = .newSession(parent: nil) }
                Button("打开本地终端") { workspace.openLocal() }
                    .keyboardShortcut("t", modifiers: [.command])
            }
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func feature(_ title: String, _ detail: String, _ image: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: image)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: 220, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ZModemBanner: View {
    let progress: ZModemProgress
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: progress.direction == .receive ? "arrow.down.doc" : "arrow.up.doc")
            VStack(alignment: .leading, spacing: 4) {
                Text(progress.message)
                    .font(.callout.weight(.medium))
                if progress.total > 0 && !progress.isFinished {
                    ProgressView(value: Double(progress.transferred), total: Double(max(progress.total, 1)))
                }
            }
            Spacer()
            if progress.isFinished, !progress.isError, let path = progress.savedPath {
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            } else if !progress.isFinished {
                Button("取消", action: onCancel)
            }
        }
        .padding(10)
        .background(.bar, in: RoundedRectangle(cornerRadius: 10))
        .padding(12)
    }
}
