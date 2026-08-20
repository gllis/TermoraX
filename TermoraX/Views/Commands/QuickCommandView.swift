//
//  QuickCommandView.swift
//  TermoraX
//

import SwiftData
import SwiftUI

struct QuickCommandView: View {
    var commands: [QuickCommand]
    @Bindable var workspace: WorkspaceController
    var nodes: [SessionNode]
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("发送到全部选项卡", isOn: $workspace.sendQuickCommandToAll)
                    .toggleStyle(.checkbox)
                Spacer()
                Button {
                    workspace.showNewCommand = true
                } label: {
                    Label("新建", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(commands.sorted(by: { $0.sortIndex < $1.sortIndex }), id: \.id) { command in
                        Button {
                            workspace.sendCommand(command.command, allNodes: nodes)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(command.name)
                                    .font(.caption.weight(.semibold))
                                Text(command.command)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("编辑") { workspace.pendingCommandEdit = command }
                            Button("删除", role: .destructive) { modelContext.delete(command) }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
    }
}

struct QuickCommandEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    var command: QuickCommand?

    @State private var name = ""
    @State private var value = ""

    var body: some View {
        VStack(spacing: 16) {
            TextField("名称", text: $name)
            TextField("命令", text: $value)
                .font(.body.monospaced())
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let command {
                        command.name = trimmedName
                        command.command = value
                    } else {
                        modelContext.insert(QuickCommand(name: trimmedName, command: value))
                    }
                    try? modelContext.save()
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || value.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            name = command?.name ?? ""
            value = command?.command ?? ""
        }
    }
}
