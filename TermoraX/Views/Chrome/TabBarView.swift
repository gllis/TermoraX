//
//  TabBarView.swift
//  TermoraX
//
//  标签栏。ScrollView 必须 `minWidth: 0`，否则会按内容撑出窗口导致右侧标签被裁切。
//

import SwiftUI

struct TabBarView: View {
    @Bindable var workspace: WorkspaceController

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(workspace.tabs) { tab in
                            tabChip(tab)
                                .id(tab.id)
                        }
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 8)
                    .padding(.vertical, 5)
                }
                .frame(minWidth: 0, maxWidth: .infinity)
                .clipped()
                .onChange(of: workspace.selectedTabID) { _, id in
                    scroll(proxy, to: id, anchor: .center)
                }
                .onChange(of: workspace.tabs.map(\.id)) { _, ids in
                    scroll(proxy, to: workspace.selectedTabID ?? ids.last, anchor: .center)
                }
            }

            if !workspace.tabs.isEmpty {
                Menu {
                    ForEach(workspace.tabs) { tab in
                        Button {
                            workspace.selectTab(tab.id)
                        } label: {
                            HStack {
                                Text(tab.title)
                                if tab.id == workspace.selectedTabID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .frame(width: 22, height: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("所有标签")
                .fixedSize()
            }

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 2)

            Button {
                workspace.openLocal()
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("新建本地终端")
            .fixedSize()
            .padding(.trailing, 6)
        }
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: UUID?, anchor: UnitPoint) {
        guard let id else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.16)) {
                proxy.scrollTo(id, anchor: anchor)
            }
        }
    }

    private func tabChip(_ tab: WorkspaceTab) -> some View {
        let selected = workspace.selectedTabID == tab.id
        return HStack(spacing: 6) {
            Image(systemName: tab.systemImage)
                .font(.caption)
            Text(tab.title)
                .lineLimit(1)
                .truncationMode(.tail)
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
        .frame(maxWidth: 160)
        .background(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.selectTab(tab.id)
        }
        .contextMenu {
            Button("关闭") { workspace.close(tab.id) }
            Button("关闭其他") { workspace.closeOthers(tab.id) }
            Button("关闭全部") { workspace.closeAll() }
        }
        .help(tab.title)
    }
}
