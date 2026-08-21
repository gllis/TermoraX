//
//  QuickCommandIcon.swift
//  TermoraX
//

import SwiftUI

enum QuickCommandIcon {
    static let tileSize: CGFloat = 52
    static let cornerRadius: CGFloat = 10

    static let symbols: [String] = [
        "terminal.fill",
        "folder.fill",
        "internaldrive.fill",
        "cpu",
        "memorychip",
        "network",
        "globe",
        "bolt.fill",
        "play.fill",
        "arrow.clockwise",
        "gearshape.fill",
        "hammer.fill",
        "shippingbox.fill",
        "doc.text.fill",
        "list.bullet",
        "checkmark.circle.fill",
        "lock.fill",
        "cloud.fill",
        "antenna.radiowaves.left.and.right",
        "chevron.left.forwardslash.chevron.right",
        "square.stack.3d.up.fill",
    ]

    static let palette: [Color] = [
        Color(red: 0.18, green: 0.50, blue: 0.97),
        Color(red: 0.13, green: 0.72, blue: 0.38),
        Color(red: 0.98, green: 0.58, blue: 0.12),
        Color(red: 0.89, green: 0.27, blue: 0.29),
        Color(red: 0.64, green: 0.36, blue: 0.90),
        Color(red: 0.15, green: 0.68, blue: 0.72),
        Color(red: 0.96, green: 0.35, blue: 0.55),
        Color(red: 0.35, green: 0.42, blue: 0.75),
        Color(red: 0.22, green: 0.62, blue: 0.55),
        Color(red: 0.90, green: 0.45, blue: 0.18),
    ]

    static func color(at index: Int) -> Color {
        palette[abs(index) % palette.count]
    }

    static func tintIndex(for name: String) -> Int {
        let hash = name.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        return abs(hash) % palette.count
    }

    static func suggestedSymbol(for command: String) -> String {
        let lower = command.lowercased()
        if lower.contains("ls") || lower.contains("find") || lower.contains("cd ") { return "folder.fill" }
        if lower.contains("df") || lower.contains("disk") { return "internaldrive.fill" }
        if lower.contains("top") || lower.contains("ps ") || lower.contains("cpu") { return "cpu" }
        if lower.contains("free") || lower.contains("vm_stat") || lower.contains("mem") { return "memorychip" }
        if lower.contains("git") { return "chevron.left.forwardslash.chevron.right" }
        if lower.contains("docker") || lower.contains("podman") { return "shippingbox.fill" }
        if lower.contains("systemctl") || lower.contains("service") { return "gearshape.fill" }
        if lower.contains("curl") || lower.contains("wget") || lower.contains("ping") { return "network" }
        if lower.contains("ssh") { return "network" }
        return "terminal.fill"
    }
}

struct QuickCommandTile: View {
    let name: String
    let command: String
    let symbolName: String
    let tintIndex: Int

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: QuickCommandIcon.cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                QuickCommandIcon.color(at: tintIndex).opacity(0.95),
                                QuickCommandIcon.color(at: tintIndex).opacity(0.72),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                Image(systemName: symbolName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 0, y: 0.5)
            }
            .frame(width: QuickCommandIcon.tileSize, height: QuickCommandIcon.tileSize)

            Text(name)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: QuickCommandIcon.tileSize + 12)
        }
        .help(command)
    }
}
