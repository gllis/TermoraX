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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
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
            .padding(.top, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(commands.sorted(by: { $0.sortIndex < $1.sortIndex }), id: \.id) { command in
                        Button {
                            workspace.sendCommand(command.command, allNodes: nodes)
                        } label: {
                            QuickCommandTile(
                                name: command.name,
                                command: command.command,
                                symbolName: command.symbolName.isEmpty
                                    ? QuickCommandIcon.suggestedSymbol(for: command.command)
                                    : command.symbolName,
                                tintIndex: command.tintIndex
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("编辑") { workspace.pendingCommandEdit = command }
                            Button("删除", role: .destructive) { modelContext.delete(command) }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
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
    @State private var symbolName = "terminal.fill"
    @State private var tintIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                QuickCommandTile(
                    name: name.isEmpty ? "预览" : name,
                    command: value,
                    symbolName: symbolName,
                    tintIndex: tintIndex
                )
                VStack(spacing: 10) {
                    TextField("名称", text: $name)
                    TextField("命令", text: $value)
                        .font(.body.monospaced())
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("颜色")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(Array(QuickCommandIcon.palette.indices), id: \.self) { index in
                        Button {
                            tintIndex = index
                        } label: {
                            Circle()
                                .fill(QuickCommandIcon.color(at: index))
                                .frame(width: 18, height: 18)
                                .overlay {
                                    if tintIndex == index {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("图标")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 6), count: 10), spacing: 6) {
                    ForEach(QuickCommandIcon.symbols, id: \.self) { symbol in
                        Button {
                            symbolName = symbol
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 28, height: 28)
                                .foregroundStyle(symbolName == symbol ? .white : .primary)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(symbolName == symbol
                                              ? QuickCommandIcon.color(at: tintIndex)
                                              : Color.primary.opacity(0.06))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let command {
                        command.name = trimmedName
                        command.command = value
                        command.symbolName = symbolName
                        command.tintIndex = tintIndex
                    } else {
                        modelContext.insert(
                            QuickCommand(
                                name: trimmedName,
                                command: value,
                                symbolName: symbolName,
                                tintIndex: tintIndex
                            )
                        )
                    }
                    try? modelContext.save()
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || value.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            name = command?.name ?? ""
            value = command?.command ?? ""
            symbolName = {
                if let command, !command.symbolName.isEmpty { return command.symbolName }
                return QuickCommandIcon.suggestedSymbol(for: command?.command ?? "")
            }()
            tintIndex = command?.tintIndex ?? QuickCommandIcon.tintIndex(for: name)
        }
        .onChange(of: value) { _, newValue in
            if command == nil {
                symbolName = QuickCommandIcon.suggestedSymbol(for: newValue)
            }
        }
    }
}
