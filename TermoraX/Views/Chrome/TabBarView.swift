//
//  TabBarView.swift
//  TermoraX
//

import SwiftUI

struct TabBarView: View {
    @Bindable var workspace: WorkspaceController

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(workspace.tabs) { tab in
                        tabChip(tab)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            Divider()
                .frame(height: 18)
            Button {
                workspace.openLocal()
            } label: {
                Image(systemName: "plus")
                    .padding(.horizontal, 10)
                    .frame(maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .help("新建本地终端")
        }
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .clipped()
        .background(.bar)
    }

    private func tabChip(_ tab: WorkspaceTab) -> some View {
        let selected = workspace.selectedTabID == tab.id
        return HStack(spacing: 6) {
            Image(systemName: tab.systemImage)
                .font(.caption)
            Text(tab.title)
                .lineLimit(1)
            Button {
                workspace.close(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.clear)
        )
        .onTapGesture {
            workspace.selectedTabID = tab.id
        }
        .contextMenu {
            Button("关闭") { workspace.close(tab.id) }
            Button("关闭其他") { workspace.closeOthers(tab.id) }
            Button("关闭全部") { workspace.closeAll() }
        }
    }
}
