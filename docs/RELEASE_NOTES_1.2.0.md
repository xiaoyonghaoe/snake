# Snake 1.2.0

发布日期：2026-10-25 · 构建号：1200

## 更新

- SSH 核心从 libssh2 迁移到 Rust/russh，采用共享 Tokio 运行时。同一配置及认证材料的终端、SFTP 浏览与 MCP 命令复用已认证连接；传输工作连接独立，避免分片挤占交互通道。
- 终端默认使用 Metal GPU 渲染，合并后台输出回调，使用实际布局尺寸创建 PTY，并改善行距、深色对比度与连接初始化回显。Metal 覆盖层不再拦截点击，分屏终端可正常切换输入焦点；可在设置中关闭 GPU 渲染。
- 改进连接建立与断线恢复：地址族交错连接、TCP_NODELAY、短 Keepalive 和有界退避重连；正常远端退出不当作意外断线。重连建立的是新 Shell，不恢复原远端进程。
- 新增设置中的本地 HTTP MCP 服务（默认回环端口 47821）：会话绑定 Token、有效期与吊销、身份验证查看，以及命令审计筛选、删除和滚动保留。
- MCP 提供 `list_sessions` / `run_command`，在已信任主机上非交互执行 `/bin/sh` 命令。每次独立 exec，无 PTY；用 `cwd` 或单条组合命令指定目录。
- 包含 1.1.3 之后的 Ghostty 清晰与独立纯白主题、安全续传分片、取消后重试串行、精确路径原子覆盖、目录自复制防护及旧配置/快捷键恢复修复。
- 同步 russh、AWS-LC 及相关依赖许可，移除 OpenSSL 运行依赖；随包携带本地化和 Metal 资源。

## 安装与安全边界

- Apple Silicon（arm64），macOS 15+；打开 DMG，将 Snake.app 拖到 Applications。更新前退出旧版，复制时选择替换。
- **仅 ad-hoc 签名，未使用 Developer ID，未通过 Apple 公证。** 首次打开可能被系统阻止；按安装说明处理，不关闭 Gatekeeper。
- MCP 默认关闭，只监听 `127.0.0.1`。Token 赋予绑定 SSH 账号的命令权限，不是只读沙箱。命令与输出摘录会写入审计，不要在其中传入秘密；配置示例必须使用占位 Token。
- 配置与凭据沿用现有 SQLite/AES-256-GCM 存储；测试签名升级可能再次要求钥匙串访问批准。安装包不包含用户数据或测试密钥。
- 密码型 SSHFS 挂载、Intel / Universal 2、公证及跨应用重启工作区恢复仍未交付。

## 本次验证

- Rust：32 项单元测试通过；另启用本机隔离 SSH 服务，3 项 SFTP 发布/目录自复制/续传回归通过。
- Swift：226 项，220 通过、5 项外部夹具跳过；既有 `MountOperationsTests.testQuitIsCancelledWhenMountIsBusyOrMountTableCannotBeRead` 仍因 `invalidMapping` 失败，不能宣称全量通过。
- 保留现存 `McpServer.swift` 的 DispatchWorkItem Sendable 警告及 `Workspace.swift` 未使用变量警告；不将它们描述为已修复。
- Release 构建、镜像校验、SHA-256、只读挂载后的签名/资源/版本检查通过；7 个 Metal shader 和 699 条英文字符串资源通过验证。
- GUI、真实 Touch ID、Finder 手势及干净 Mac 安装/升级由用户验收，本轮不替代这些人工测试。

## 附件

- `Snake-1.2.0-macos-arm64.dmg`：10,580,322 字节。
- SHA-256：`bd45e81c11545bb47e286ff920cca283d9a1224e18668d08fb252bb0251f789b`。
- 将 DMG 与 `.dmg.sha256` 放在同一目录，运行 `shasum -a 256 -c Snake-1.2.0-macos-arm64.dmg.sha256`。

## English

Snake 1.2.0 migrates SSH to russh with a shared Tokio runtime and authenticated connection reuse for terminals, SFTP browsing and MCP commands. Transfer workers remain independent. Metal rendering is enabled by default, output callbacks are batched, terminal sizing/spacing and quiet startup improve, and split-pane focus works through a click-through Metal surface. Connection setup and bounded reconnect behavior are improved; reconnect creates a new shell rather than restoring remote processes.

A new loopback-only HTTP MCP server adds profile-bound tokens, expiry/revocation, authenticated reveal and command audit/retention controls. Call `list_sessions`, then `run_command`; calls use remote `/bin/sh`, have no PTY and do not share a working directory. Tokens grant the remote account's execution rights, not a read-only sandbox. Commands and output excerpts are audited, so do not include secrets.

Includes post-1.1.3 terminal themes and transfer/configuration recovery fixes, and updated russh/AWS-LC attribution. Apple Silicon / macOS 15+, build 1200, **ad-hoc signed and not notarized**. Rust: 32 unit tests plus 3 real isolated SFTP regressions passed. Swift: 220 passed, 5 skipped and 1 pre-existing mount `invalidMapping` failure (226 total). Existing compiler warnings remain. GUI, system authentication and clean-Mac installation/upgrade are manual acceptance tasks. DMG and SHA-256 metadata above refer to the same verified artifact.
