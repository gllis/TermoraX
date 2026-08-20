//
//  DockablePanel.swift
//  TermoraX
//

import AppKit
import SwiftUI

struct DockablePanel<Content: View>: View {
    let title: String
    let systemImage: String
    @Binding var pinned: Bool
    @Binding var expanded: Bool
    var width: CGFloat? = nil
    var height: CGFloat? = nil
    var edge: Edge = .leading
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Spacer()
                Button {
                    pinned.toggle()
                    expanded = pinned
                } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                .help(pinned ? "取消固定" : "固定面板")
                Button {
                    pinned = false
                    expanded = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("隐藏面板")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            content()
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .background(.ultraThinMaterial)
    }
}

struct AutoHideStrip: View {
    let title: String
    let systemImage: String
    let axis: Axis
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if axis == .vertical {
                    VStack(spacing: 8) {
                        Image(systemName: systemImage)
                        Text(title)
                            .font(.caption2)
                            .rotationEffect(.degrees(-90))
                            .fixedSize()
                            .frame(width: 14, height: 72)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: systemImage)
                        Text(title)
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .foregroundStyle(.secondary)
            .frame(
                width: axis == .vertical ? AppTheme.autoHideStrip : nil,
                height: axis == .horizontal ? AppTheme.autoHideStrip : nil
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(title)（自动隐藏，点击展开，可在工具栏中固定）")
    }
}

struct PanelResizeHandle: View {
    var vertical: Bool = true
    var inverted: Bool = false
    let current: CGFloat
    let range: ClosedRange<CGFloat>
    var onChange: (CGFloat) -> Void
    @State private var origin: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(width: vertical ? 5 : nil, height: vertical ? nil : 5)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if origin == nil { origin = current }
                        let delta = vertical ? value.translation.width : value.translation.height
                        let next = (origin ?? current) + (inverted ? -delta : delta)
                        onChange(min(max(next, range.lowerBound), range.upperBound))
                    }
                    .onEnded { _ in
                        origin = nil
                    }
            )
    }
}
