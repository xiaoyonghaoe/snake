**简体中文** · [English](README.en.md)

# Snake

Snake 是面向 macOS 15+ 的原生 SSH 工作台：会话管理、终端、SFTP 文件传输和 SSHFS 磁盘映射共用一个多窗口工作区。

## 1.1.0 安装

当前安装包为 **Apple Silicon（M 系列）版**，要求 **macOS 15 或更高版本**，不包含 Intel / Universal 2 版本。

1. 打开 `Snake-1.1.0-macos-arm64.dmg`。
2. 将 **Snake.app 拖到 Applications（应用程序）**，等待复制完成。
3. 推出磁盘映像，从“应用程序”启动 Snake。更新旧版前先退出应用，复制时选择替换。

目前已生成本地安装包，上传 GitHub Releases。构建产物在 `release/`，不随源码提交；发布附件为 DMG 和同名 `.dmg.sha256` 校验文件。

**当前包仅使用 ad-hoc 临时签名，未经过 Developer ID 签名与 Apple 公证，首次打开可能被系统拦截。** 签名完整性检查通过不代表 Gatekeeper 放行；安装与安全提示见 [安装说明](docs/INSTALL.md)。安装包不包含用户会话、密码或测试配置，磁盘映射所需的 macFUSE / sshfs 也不自动安装。

将 DMG 与校验文件放在同一目录，在该目录执行：

```sh
shasum -a 256 -c Snake-1.1.0-macos-arm64.dmg.sha256
```

本次更新见 [1.1.0 版本说明](docs/RELEASE_NOTES_1.1.0.md)，构建、签名与公证步骤见 [发布流程](docs/RELEASING.md)。

## 界面预览

<img width="1120" height="840" alt="image" src="https://github.com/user-attachments/assets/d9f0fd93-cc37-468d-8256-0020b76ac4f5" />
<img width="1120" height="840" alt="image" src="https://github.com/user-attachments/assets/711f9420-4b34-4621-baab-fb8f64d4e9a0" />
<img width="1120" height="840" alt="image" src="https://github.com/user-attachments/assets/5a3191e4-2f8f-467c-803d-fc2be2273275" />
<img width="1120" height="840" alt="image" src="https://github.com/user-attachments/assets/d6e4ae1c-2fa5-47a8-8071-b5d571061f6e" />
<img width="1120" height="840" alt="image" src="https://github.com/user-attachments/assets/b8586934-23b7-4b10-be21-ea05357c86f5" />
<img width="1120" height="840" alt="image" src="https://github.com/user-attachments/assets/68f66f07-2eb6-400a-83da-158eeabf8b4e" />
<img width="1120" height="840" alt="image" src="https://github.com/user-attachments/assets/c11929f1-a08b-4af1-aee9-9fd6472b8ccc" />
<img width="1120" height="840" alt="image" src="https://github.com/user-attachments/assets/2f150786-87b7-4950-a307-9670158da30c" />

完整产品与安全约束见 [开发计划](docs/SNAKE_DEVELOPMENT_PLAN.md)。公开源码不包含内部交互设计原型。

## 当前功能

### 会话与多窗口工作区

- 原生 AppKit/SwiftUI 界面、统一顶部栏和浅色/深色外观；SSH 会话采用卡片标签页，不再使用侧栏或分组。磁盘映射从右上角入口打开独立标签。
- 启动默认打开 SSH 会话页，不注入示例服务器、示例映射或伪终端输出。双击标签栏尾部空白可在该分栏新增会话页；`Command-K` 聚焦会话搜索，必要时先新建会话页。
- 支持会话编辑、空格分隔标签、多选标签筛选和自定义照片图标裁剪。卡片按钮、双击及右键连接操作将当前管理标签原位转换为终端或 SFTP，不追加标签。
- Bonsplit 支持标签排序、左右/上下分屏、拖出独立窗口及跨窗口合并。会话卡片拖入工作区会新建连接，按住 Option 创建 SFTP；移动已有连接标签不重连。
- 主工作窗口中 `Command-W` 只关闭当前标签或多余空分栏，最后一个空分栏保持窗口打开。红色按钮只关闭窗口，Dock 重新打开恢复当前进程中的工作区；不恢复跨应用重启的标签布局。

### SSH 终端与配色

- Rust/libssh2 `TerminalHandle` 提供真实 SSH PTY，SwiftTerm 负责渲染与输入。支持密码/私钥认证、主机密钥校验、真实协商算法详情、UTF-8 输入输出、PTY resize、远端退出和 30 秒 Keepalive；瞬时连接错误自动重试一次，并显示具体失败阶段。
- 设置支持终端字体、字号及“经典”“鲜明”“Tokyo Night”主题。默认 Tokyo Night，浅色终端背景为纯白；主题切换保留连接与输出缓冲。
- 日志关键词和权限、时间、路径、地址等输出字段可本地高亮，不改写终端数据；尊重远端 ANSI / True Color，备用屏幕停用本地高亮。
- 可在 bash/zsh/fish 当前会话中启用彩色 `ls/ll`，不修改远端 Shell 配置文件。开关下次连接生效，保留用户复杂别名及非空 `NO_COLOR`。详见 [终端配色说明](docs/TOKYO_NIGHT_COLORS.md)。

### SFTP 与文件传输

- 支持路径输入、前进/后退/上一级、文件检索、软链接、新建文件/文件夹、重命名、可视化权限与递归权限修改、Command/Shift 多选删除，以及远程文件下载到缓存后打开。
- 文件夹和空白区域右键提供新建与上传入口，目标均为当前浏览目录。文件/文件夹可下载到用户选择的本地目录；文件夹传输保留目录层级及空文件夹。
- Finder 文件/文件夹可拖到 SSH 终端或 SFTP 内容区上传，与标签拖动隔离。SSH 使用最近报告的 Shell 目录，未知时先确认；SFTP 使用当前目录。详见 [Finder 上传说明](docs/FINDER_UPLOAD.md)。
- 上传与下载支持配置化并行传输，默认超过 50 MB 使用 4 个连接分片。上传支持分片续传与隐藏暂存文件安全覆盖；SFTP-only 兼容路径失败重试重新上传。SFTP 分栏/窗口之间保留远程文件拖拽互传。
- 优先使用远端 SHA-256，无法使用时尝试 MD5；不可用或探测失败时标记“未校验”，不阻止正常上传/下载，不回读远端文件。已获得的双方摘要不一致仍视为失败，不覆盖旧文件。详见 [下载与完整性校验](docs/SFTP_DOWNLOAD_INTEGRITY.md)。
- SSH 连接带和 SFTP 底部按需显示紧凑进度入口，点击查看当前标签的文件级记录、耗时、结果与校验状态，并可暂停、继续、取消或重试。记录不写入 SQLite，关闭标签或退出应用后清空。
- SFTP 默认快捷键：`Command-F` 检索、`Command-Delete（⌫）` 删除、`Command-U` 上传文件；可在设置中修改。

### 磁盘映射与数据

- 支持 macFUSE/sshfs 依赖检测、映射编辑、私钥 SSHFS 挂载、Finder 打开与安全卸载，使用受约束的 `SnakeMountHelper`。
- Finder 磁盘名称显示“映射名称 · SSH 会话名称”；以系统实际挂载表为准。退出前等待挂载操作并安全卸载受管映射，卸载失败取消退出。仅关闭窗口或映射标签不卸载磁盘。
- Rust `snake_core` 提供 SQLite 数据存储、会话/映射/传输记录接口及 UniFFI Swift 绑定；凭据单独加密保存，不写入数据库。

## 本地开发

```bash
scripts/generate-core-bindings.sh
swift test --disable-sandbox
swift run Snake
scripts/package-debug-app.sh

cd Rust/snake_core
cargo test
# 密码由标准输入提供，不写入参数或源码
cargo run --example terminal_smoke -- <host> <port> <username> <known-hosts-path>
cargo run --example sftp_smoke -- <host> <port> <username> <known-hosts-path>
```

系统要求：Xcode 16.4、Swift 6.1、Rust 1.87+。SwiftTerm 固定到 `v1.13.0`，原因是当前工作站的 Swift 6.1 不兼容其主分支的 Swift 6.2 manifest。

`scripts/package-debug-app.sh` 会在 `.build/debug-app/Snake.app` 创建内嵌 Rust 动态库与 Mount Helper、ad-hoc 签名的开发应用，供本机界面测试使用。

### 构建 DMG

```sh
zsh scripts/package-release-dmg.sh 1.1.0
```

需要 Python 3；脚本使用 Release 优化构建，仅生成当前宿主架构的安装包。产物位于 `release/`，同名文件存在时拒绝覆盖。应用包含 Rust 动态库、Mount Helper、SwiftTerm Metal 资源及第三方许可证，不依赖工作区中的动态库或渲染资源。

版本号和构建号保存在 `Resources/Info.plist`，当前为 `1.1.0` / `1100`。脚本默认临时签名；Developer ID 签名、公证和重新生成校验文件的步骤见 [发布流程](docs/RELEASING.md)。本地打包不会自动创建 Git 标签或发布 GitHub Release。

应用启动时自动将旧明文凭据迁移为加密文件；旧会话如果仍只有 Keychain 引用，会在首次成功读取后迁入加密存储。具体设计及手工验收见 [凭据加密与查看](docs/CREDENTIAL_SECURITY.md)。

## 安全边界

- 密码和私钥口令使用 AES-256-GCM 加密保存到 `~/Library/Application Support/Snake/credentials.json`，随机 256 位密钥保存在系统钥匙串，文件权限为 `0600`、目录为 `0700`。文件损坏或密钥丢失时不会覆盖原文件或回退明文。
- 连接自动解密；编辑页查看已保存的明文须通过 Touch ID 或 Mac 登录密码等系统身份验证，30 秒后或窗口失焦时隐藏。临时签名更新仍可能触发独立的钥匙串访问授权，不保证开发包无提示。
- SQLite 仍只保存 credential reference，不保存密码；后续接入密码工具时只替换 `CredentialStore` 后端。
- 私钥通过 security-scoped bookmark 引用，不复制文件。
- SSH 终端、SFTP 和远程目录选择器在主机密钥变化时显示原、新指纹，只有明确确认后才更新对应地址和端口的信任记录并重连；取消保留原记录，重连时再次校验实际指纹。
- `SnakeMountHelper` 只接受受管挂载目录与允许列表中的 sshfs 可执行路径。
- 终端凭据以字节通过 UniFFI 传给 Rust/libssh2，认证材料在使用后清零；不会启动系统 `ssh`，也不会把密码传递给 argv、环境变量或拖放载荷。
- 当前 SSHFS 仅对私钥会话执行真实挂载；密码型挂载会明确失败，直到受管 SSH_ASKPASS FIFO 完成，绝不降级为不安全的 argv/环境变量传密。

## 尚未完成的能力

- 不恢复跨应用重启的工作区或自动继续中断传输；下载失败重试从新的源版本重新下载，不承诺下载断点续传。
- 每主机独立并发限制、远程打开缓存 LRU 清理仍待完善；现有并发设置不等同于全局按主机调度。
- 密码型挂载 AskPass、Intel / Universal 2 安装包、Developer ID 签名与公证尚未交付。
- 已知挂载测试 `MountOperationsTests.testQuitIsCancelledWhenMountIsBusyOrMountTableCannotBeRead` 存在 `invalidMapping` 失败，不能将整体测试宣称为全部通过。本次打包相关的快捷键/工作区 24 项测试及安装包完整性检查通过；页面和干净 Mac 安装验收仍需执行。

## 多语言

- 内置 **简体中文（源语言、默认与回退）** 与 **English** 两种界面语言，可在「设置 › 外观 › 语言」中切换；选择立即生效并会被记住。
- 系统权限弹窗、Finder 与 macOS 提供的菜单文案跟随系统语言，不由应用内选择决定。
- 新增一种语言：复制 `Resources/Localization/en.lproj` 为 `<语言>.lproj`，翻译 `Localizable.strings`（key 是简体中文原文，必须保留每个 `%@` 占位符及 `<key>#plural` 复数条目），把语言加入 `Resources/Info.plist` 的 `CFBundleLocalizations` 与 `AppLanguage.supportedIdentifiers`，再运行 `swift test --disable-sandbox --filter LocalizationTests` 校验完整性。
- `swift run Snake` 不是打包后的 `.app`，`Bundle.main` 找不到 `.lproj`，界面会保持简体中文；验证其他语言请使用 `scripts/package-debug-app.sh` 生成的 `Snake.app`。

完整第三方归属见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
