//
//  SettingsView.swift
//  TermoraX
//
//  系统「设置」窗口（⌘,）。绑定 AppSettings.shared，改动立即生效。
//

import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("终端") {
                HStack {
                    Text("字体大小")
                    Slider(value: $settings.terminalFontSize, in: AppSettings.minFontSize...AppSettings.maxFontSize, step: 1)
                    Text("\(Int(settings.terminalFontSize.rounded())) pt")
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
            }

            Section("复制与粘贴") {
                Toggle("快速复制粘贴", isOn: $settings.quickCopyPaste)
                Text("选中文本后自动复制；右键粘贴到终端。按住 Shift 再右键可打开菜单。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("窗口") {
                Picker("点击关闭", selection: $settings.closeBehavior) {
                    ForEach(CloseBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("文件传输") {
                LabeledContent("sz 默认保存路径") {
                    HStack(spacing: 8) {
                        Text(displayPath(settings.zmodemReceiveFolder))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(settings.zmodemReceiveFolder.path)
                        Button("选择…") { pickReceiveFolder() }
                        Button("恢复默认") {
                            settings.zmodemReceiveFolder = AppPaths.userDownloads
                        }
                    }
                }
                Text("远程 `sz` 收到的文件会保存到此目录，默认为用户下载文件夹。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("状态") {
                HStack {
                    Text("保存活动状态")
                    Spacer()
                    TextField("", value: $settings.activitySaveInterval, format: IntegerFormatStyle<Int>().grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                    Text("秒")
                        .foregroundStyle(.secondary)
                }
                Text("每隔指定秒数保存已打开的标签，下次启动时恢复；同时作为 SSH 保活间隔。0 表示关闭定时保存和保活。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .padding(.bottom, 8)
    }

    private func pickReceiveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.directoryURL = settings.zmodemReceiveFolder
        if panel.runModal() == .OK, let url = panel.url {
            settings.zmodemReceiveFolder = url
        }
    }

    private func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if url.path == home { return "~" }
        if url.path.hasPrefix(home + "/") {
            return "~" + String(url.path.dropFirst(home.count))
        }
        return url.path
    }
}
