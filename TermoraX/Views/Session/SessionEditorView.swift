//
//  SessionEditorView.swift
//  TermoraX
//

import SwiftData
import SwiftUI

struct SessionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let token: SessionEditorToken

    @State private var name = ""
    @State private var isGroup = false
    @State private var sessionProtocol = "ssh"
    @State private var host = ""
    @State private var port = 22
    @State private var username = ""
    @State private var authMethod = "default"
    @State private var password = ""
    @State private var privateKeyPath = ""
    @State private var sftpDefaultPath = ""
    @State private var note = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("名称", text: $name)
                if !isGroup {
                    Picker("类型", selection: $sessionProtocol) {
                        Text("SSH").tag("ssh")
                        Text("本地终端").tag("local")
                    }
                    if sessionProtocol == "ssh" {
                        TextField("主机", text: $host)
                        TextField("端口", value: $port, format: IntegerFormatStyle<Int>().grouping(.never))
                        TextField("用户名", text: $username)
                        Picker("认证", selection: $authMethod) {
                            Text("系统默认（密钥 / ssh-agent）").tag("default")
                            Text("密码").tag("password")
                            Text("私钥文件").tag("key")
                        }
                        .help("要自动登录，请选择「密码」并保存。已打开的标签页需要关掉后重新连接。")
                        if authMethod == "password" {
                            SecureField("密码", text: $password)
                        }
                        if authMethod == "key" {
                            TextField("私钥路径", text: $privateKeyPath)
                                .help("例如 ~/.ssh/id_ed25519")
                        }
                        TextField("SFTP 默认目录", text: $sftpDefaultPath)
                    }
                    TextField("备注", text: $note, axis: .vertical)
                        .lineLimit(1...3)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .padding(.top, 4)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: load)
    }

    private func load() {
        switch token {
        case .newGroup:
            isGroup = true
            name = "新建分组"
        case .newSession:
            isGroup = false
            name = "新建会话"
            username = NSUserName()
            authMethod = "password"
        case .edit(let node):
            isGroup = node.isGroup
            name = node.name
            sessionProtocol = node.sessionProtocol.isEmpty ? "ssh" : node.sessionProtocol
            host = node.host
            port = node.port
            username = node.username
            authMethod = node.authMethod
            privateKeyPath = node.privateKeyPath
            sftpDefaultPath = node.sftpDefaultPath
            note = node.note
            password = SecretStore.password(for: node.id) ?? ""
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let node: SessionNode
        switch token {
        case .newGroup(let parent):
            node = SessionNode(name: trimmed, isGroup: true, parent: parent, sortIndex: nextIndex(parent))
            modelContext.insert(node)
        case .newSession(let parent):
            node = SessionNode(name: trimmed, isGroup: false, parent: parent, sortIndex: nextIndex(parent))
            modelContext.insert(node)
        case .edit(let existing):
            node = existing
            node.name = trimmed
        }
        if !node.isGroup {
            node.sessionProtocol = sessionProtocol
            node.host = host.trimmingCharacters(in: .whitespaces)
            node.port = min(max(port, 1), 65535)
            node.username = username.trimmingCharacters(in: .whitespaces)
            node.authMethod = authMethod
            node.privateKeyPath = privateKeyPath
            node.sftpDefaultPath = sftpDefaultPath
            node.note = note
            if authMethod == "password" {
                SecretStore.setPassword(password, for: node.id)
            } else {
                SecretStore.deletePassword(for: node.id)
            }
        }
        try? modelContext.save()
        dismiss()
    }

    private func nextIndex(_ parent: SessionNode?) -> Int {
        let siblings = parent?.children ?? ((try? modelContext.fetch(FetchDescriptor<SessionNode>())) ?? []).filter { $0.parent == nil }
        return (siblings.map(\.sortIndex).max() ?? -1) + 1
    }
}
