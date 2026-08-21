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
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 8)
                Button {
                    pinned = false
                    expanded = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .layoutPriority(1)
                .help("隐藏面板")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(width: width, height: height)
        .clipped()
        .background(Color(nsColor: .windowBackgroundColor))
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
        .help("\(title)（点击展开）")
    }
}

struct PanelResizeHandle: View {
    var vertical: Bool = true
    var inverted: Bool = false
    let current: CGFloat
    let range: ClosedRange<CGFloat>
    var onChange: (CGFloat) -> Void
    var onEnd: (() -> Void)? = nil

    @State private var startValue: CGFloat?
    @State private var startPosition: CGFloat?

    var body: some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
        }
        .frame(width: vertical ? 8 : nil, height: vertical ? nil : 8)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if startValue == nil {
                        startValue = current
                        startPosition = vertical ? value.startLocation.x : value.startLocation.y
                    }
                    guard let startValue, let startPosition else { return }
                    let position = vertical ? value.location.x : value.location.y
                    let delta = position - startPosition
                    let next = startValue + (inverted ? -delta : delta)
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        onChange(min(max(next, range.lowerBound), range.upperBound))
                    }
                }
                .onEnded { _ in
                    startValue = nil
                    startPosition = nil
                    onEnd?()
                }
        )
    }
}
