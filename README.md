# TermoraX

macOS 上的 SSH / 本地终端客户端：会话树、多标签终端、SFTP、ZMODEM（`sz` / `rz`）和快速命令。

界面为中文。终端仿真使用 vendored 的 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)，远程连接走系统 `/usr/bin/ssh`，不内嵌 libssh。

## 功能

- **会话管理**：分组树、SSH / 本地终端、双击连接、展开状态会记住
- **多标签**：SSH、SFTP、本地 shell；标签过多时可横滑，右侧菜单列出全部标签
- **终端**：等宽字体 + 中文 cascade、选区复制、可选「选中即复制 / 右键粘贴」
- **SFTP**：本机 / 远程双栏，上传下载
- **ZMODEM**：远端 `sz` 下载到本机指定目录，本机选择文件后走 `rz` 协议上传
- **快速命令**：底部方块，发送到当前标签或全部终端
- **密码**：AES-GCM 保险库，不把明文写进 SwiftData
- **设置**：字体大小、快速复制粘贴、关闭窗口行为、`sz` 保存路径、活动状态间隔

## 环境

| 项 | 要求 |
| --- | --- |
| 系统 | macOS 26.5+ |
| Xcode | 能编译该部署目标的版本 |
| 远程 | OpenSSH 服务端；ZMODEM 需远端有 `sz` / `rz`（lrzsz） |

## 构建

用 Xcode 打开 `TermoraX.xcodeproj`，选择 scheme **TermoraX**，目标 **My Mac**，Run。

命令行：

```bash
xcodebuild -scheme TermoraX -destination 'platform=macOS,arch=arm64' build
```

SwiftTerm 在 `Vendor/SwiftTerm`，以本地 Swift Package 链进工程，改终端行为请改这份源码，不要再拉一份 SPM 依赖。

## 使用

1. 左侧新建分组和会话（主机、端口、用户、认证方式）。
2. 密码认证会写入 `~/Library/Application Support/TermoraX/credentials.vault`。已打开的标签需关掉后重连才会用上新密码。
3. 双击会话打开终端；右键可开 SFTP。
4. 远端执行 `sz 文件` 会把文件存到设置里的目录（默认「下载」）。
5. **TermoraX → 设置**（`⌘,`）或工具栏齿轮打开全局设置。

### 设置说明

| 项 | 默认 | 说明 |
| --- | --- | --- |
| 字体大小 | 13 pt | 立即应用到已打开终端 |
| 快速复制粘贴 | 关 | 选中即复制；右键粘贴。Shift+右键仍出菜单 |
| 点击关闭 | 隐藏到 Dock | 红灯隐藏应用、会话不断；可选「退出程序」 |
| sz 默认保存路径 | 用户下载文件夹 | `sz` 收到的文件落点 |
| 保存活动状态 | 60 秒 | 定时保存已打开标签，下次启动恢复；同时作为 SSH `ServerAliveInterval`。`0` 关闭定时保存和保活 |

## 项目结构

```
TermoraX/                 应用源码（Xcode 同步根目录）
  TermoraXApp.swift       入口、SwiftData、设置 Scene
  ContentView.swift       三栏主界面
  App/                    设置、工作区、主题、种子数据
  Models/                 SessionNode、QuickCommand
  Services/               SSH、SFTP、ZMODEM、密码库、路径
  Views/                  会话树、终端、文件、命令、设置、窗口铬
Vendor/SwiftTerm/         终端仿真（本地包）
Tools/ZModemCheck/        ZMODEM 协议自测
```

### 运行时关系

```
ContentView
  ├─ SessionManagerView     → SessionNode (SwiftData)
  ├─ TabBarView / 终端标签
  │     TerminalSessionView → TerminalRegistry → TermoraTerminalView
  │                              ├─ LocalProcess (`ssh` 或本机 shell)
  │                              └─ ZModemEngine
  ├─ FileManagerView        → SFTPClient (`ssh -s sftp`)
  └─ QuickCommandView       → TerminalRegistry.send
```

`WorkspaceController` 只管打开的标签和选中项；真正的 PTY 在 `TerminalRegistry` 里按 `tab.id` 持有，SwiftUI 刷新不会拆掉连接。

## 数据位置

| 内容 | 位置 |
| --- | --- |
| 会话树、快速命令 | SwiftData（Application Support 下的 TermoraX 存储） |
| 全局设置、标签快照 | `UserDefaults` |
| 会话密码 | `~/Library/Application Support/TermoraX/credentials.vault` |
| SSH ControlMaster socket | `~/Library/Caches/TermoraX/mux/`（路径不能有空格） |

保险库用 AES-GCM。密钥由编译期 pepper、本机 `IOPlatformUUID` 和登录用户名经 PBKDF2 派生，旧 Keychain 条目会在首次读取时迁过去。

## SSH

`SSHCommand` 生成 `/usr/bin/ssh` 参数：

- `StrictHostKeyChecking=accept-new`、`ControlMaster=auto`
- 密码登录：`SSH_ASKPASS` + 临时口令文件（约 60 秒后删除）
- 私钥登录：`-i` + `IdentitiesOnly=yes`
- 保活：`ServerAliveInterval` 等于设置里的活动间隔

## ZMODEM 注意

- 十六进制帧头必须 **小写**（lrzsz 的 `zgeth1` 拒大写）
- CRC 后不要再刷两个 0 字节
- `0xFF` 不要转义
- 协议数据必须 **串行写入 pty**，不能和键盘输入抢 `DispatchIO`

更细的约定见 `Tools/ZModemCheck`。

## 开发备忘

- 部署目标与 Bundle ID：`MACOSX_DEPLOYMENT_TARGET = 26.5`，`com.gllis.TermoraX`
- 宽字符占位格必须继承正文字符属性，不要用 `Attribute.empty`（默认反色背景会在汉字后画出白块）
- SwiftTerm 1.5.1 的 `getSelectedText()` 曾把选区起止算成同一点，vendored 副本里已改成直接调用 `Terminal.getText`
- 标签栏横滑：外层 `HStack` 里的 `ScrollView` 需要 `.frame(minWidth: 0)`，否则会按内容宽度撑破窗口

## 许可

应用源码以本仓库为准。`Vendor/SwiftTerm` 遵循其上游许可证。
