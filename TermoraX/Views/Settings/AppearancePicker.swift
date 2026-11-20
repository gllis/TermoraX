//
//  AppearancePicker.swift
//  TermoraX
//
//  设置里的外观选择，样式对齐系统设置：浅色、深色、自动。
//

import AppKit
import SwiftUI

extension AppAppearance {
    func apply() {
        switch self {
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system:
            NSApp.appearance = nil
        }
    }
}

struct AppearancePicker: View {
    @Binding var selection: AppAppearance

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(AppAppearance.allCases) { appearance in
                Button {
                    selection = appearance
                } label: {
                    AppearanceChoice(appearance: appearance, isSelected: selection == appearance)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(appearance.title)
                .accessibilityAddTraits(selection == appearance ? .isSelected : [])
            }
        }
    }
}

private struct AppearanceChoice: View {
    let appearance: AppAppearance
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            AppearancePreview(appearance: appearance)
                .frame(width: 84, height: 60)
                .padding(3)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.5)
                }
            Text(appearance.title)
                .font(.callout)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(.primary)
        }
        .contentShape(Rectangle())
    }
}

/// 缩略图：桌面壁纸上的一扇窗口。自动模式左右各半。
private struct AppearancePreview: View {
    let appearance: AppAppearance

    var body: some View {
        ZStack {
            desktop
            window
                .padding(.horizontal, 7)
                .padding(.top, 9)
                .padding(.bottom, 6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var desktop: some View {
        switch appearance {
        case .light:
            lightWallpaper
        case .dark:
            darkWallpaper
        case .system:
            HStack(spacing: 0) {
                lightWallpaper
                darkWallpaper
            }
        }
    }

    private var lightWallpaper: some View {
        LinearGradient(
            colors: [
                Color(red: 0.55, green: 0.78, blue: 0.98),
                Color(red: 0.24, green: 0.50, blue: 0.92)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var darkWallpaper: some View {
        LinearGradient(
            colors: [
                Color(red: 0.28, green: 0.18, blue: 0.52),
                Color(red: 0.08, green: 0.10, blue: 0.28)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var window: some View {
        VStack(spacing: 0) {
            titleBar
            content
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 1.2, y: 0.6)
    }

    private var titleBar: some View {
        ZStack(alignment: .leading) {
            Color(red: 0.18, green: 0.47, blue: 0.96)
            Circle()
                .fill(.white.opacity(0.92))
                .frame(width: 5, height: 5)
                .padding(.leading, 5)
        }
        .frame(height: 13)
    }

    @ViewBuilder
    private var content: some View {
        ZStack(alignment: .bottom) {
            switch appearance {
            case .light:
                Color(white: 0.97)
            case .dark:
                Color(white: 0.11)
            case .system:
                HStack(spacing: 0) {
                    Color(white: 0.97)
                    Color(white: 0.11)
                }
            }
            trafficLights
                .padding(.bottom, 4)
        }
    }

    private var trafficLights: some View {
        HStack(spacing: 3) {
            Circle().fill(Color(red: 0.93, green: 0.33, blue: 0.31))
            Circle().fill(Color(red: 0.98, green: 0.76, blue: 0.22))
            Circle().fill(Color(red: 0.40, green: 0.78, blue: 0.32))
        }
        .frame(width: 22, height: 5)
    }
}
