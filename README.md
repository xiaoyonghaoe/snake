# Snake

Snake 是面向 macOS 15+ 的原生 SSH 工作台：会话管理、终端、SFTP 文件传输和 SSHFS 磁盘映射共用一个多窗口工作区。

完整产品与安全约束见 [开发计划](docs/SNAKE_DEVELOPMENT_PLAN.md)。公开源码不包含内部交互设计原型。

## 当前可运行基础

- 原生 AppKit/SwiftUI 工作窗口，按已批准的高保真原型实现统一工具栏、纯会话侧栏、连接带和跟随应用外观的浅色/深色终端；磁盘映射统一从右上角入口进入。
- 本地 vendored Bonsplit，支持标签、横纵分屏、窗内拖动，以及 Snake 协调的标签拖出独立窗口、跨窗口投放和边缘分屏。
- 空分栏提供关闭按钮；`Command-W` 优先关闭当前标签或多余空分栏，仅剩最终空分栏时保持工作窗口。
- 会话分组、会话编辑、开发阶段明文凭据文件、私钥 security-scoped bookmark；凭据访问已封装，后续可替换密码工具适配器。
- 会话双击打开终端、右键打开终端/SFTP/编辑/删除，并可拖动到同级分组。
- 新安装以空工作区启动，不再自动注入示例服务器、示例映射或伪终端输出。
- Rust/libssh2 `TerminalHandle` 提供真实 SSH PTY，SwiftTerm 只负责终端渲染与输入；支持密码/私钥认证、严格主机密钥校验、真实协商算法详情、UTF-8 输入输出、PTY resize、远端退出和 30 秒 Keepalive。瞬时连接错误自动重试一次，并按 TCP、握手、通道、PTY、shell 阶段显示错误。
- Rust/libssh2 SFTP 浏览器，支持严格主机密钥校验、密码/私钥认证、可编辑与复制的路径栏、创建文件/文件夹、重命名、chmod、删除、文件/文件夹上传、远程文件缓存打开，以及 SFTP 分栏/窗口间 1 MiB 内存流式互传。
- Finder 文件/文件夹可拖到 SSH 终端或 SFTP 内容区上传；原生接收层随标签换窗，按实际落点定位分栏，与 Bonsplit 标签拖动隔离。SSH 使用最近报告的 shell 目录，未知时先确认；SFTP 使用当前目录。实现与验收见 [Finder 上传说明](docs/FINDER_UPLOAD.md)。
- 当前 SFTP 标签上传时在项目统计左侧按需显示迷你进度，完成两秒后收为记录图标；点击可查看本次标签内的文件、路径、大小、时间、耗时和结果，并执行暂停、继续、取消或失败重试。本地上传记录不写入 SQLite。
- macFUSE/sshfs 依赖检测、映射编辑器、私钥 SSHFS 挂载、Finder 打开、安全卸载与受约束的 `SnakeMountHelper`。
- Rust `snake_core` 已包含 SQLite v1 schema、会话/映射/传输记录 CRUD、异常任务中断恢复、UniFFI Swift 绑定和双端往返测试。
- 调试 App 内嵌 Rust 动态库与 Mount Helper，使用 `@rpath` 并进行本地 ad-hoc 签名，可脱离工作区动态库路径启动。

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

`scripts/package-debug-app.sh` 会在 `.build/debug-app/Snake.app` 创建自包含、ad-hoc 签名的开发应用，供本机界面测试使用。正式分发仍需按开发计划执行 Universal 2、Developer ID 签名与公证。

旧会话如果仍只有 Keychain 引用，会在首次成功读取后自动迁移到临时明文文件；后续连接不再访问 Keychain。

## 安全边界

- 当前开发阶段按产品决策将密码和私钥口令明文保存到 `~/Library/Application Support/Snake/credentials.json`，文件权限强制为 `0600`，目录权限为 `0700`。
- SQLite 仍只保存 credential reference，不保存密码；后续接入密码工具时只替换 `CredentialStore` 后端。
- 私钥通过 security-scoped bookmark 引用，不复制文件。
- `SnakeMountHelper` 只接受受管挂载目录与允许列表中的 sshfs 可执行路径。
- 终端凭据以字节通过 UniFFI 传给 Rust/libssh2，认证材料在使用后清零；不会启动系统 `ssh`，也不会把密码传递给 argv、环境变量或拖放载荷。
- 当前 SSHFS 仅对私钥会话执行真实挂载；密码型挂载会明确失败，直到受管 SSH_ASKPASS FIFO 完成，绝不降级为不安全的 argv/环境变量传密。

## 尚未完成的能力

- 重名目标当前采用安全失败，不会自动覆盖；“询问/覆盖/跳过/自动重命名并应用到批次”的选择器仍待实现。
- 应用重启后的中断任务不会自动继续；断点续传、每主机并发限制和远程打开缓存 LRU 清理仍待实现。
- 密码型挂载 AskPass、Universal 2、Developer ID 与公证仍在后续阶段。

完整第三方归属见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
