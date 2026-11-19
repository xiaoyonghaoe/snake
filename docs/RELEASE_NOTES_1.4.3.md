# Snake 1.4.3

发布日期：2026-11-19 · 构建号：1430

## 改进

- **SSH 隧道断线后自动重连**：SSH 连接断开时，本地端口不再关闭，而是继续监听，状态显示为橙色的「等待重连」。有程序访问这个端口时，Snake 自动重新建立 SSH 连接（状态「正在重连」），成功后这次访问照常转发，状态回到「已连接」。同时进来的多个访问共用同一次重连。
- **重连失败时发系统通知**：自动重连失败时，触发它的那次访问会被立即关闭（客户端马上就能感知，不会卡住），隧道行显示失败原因，并弹出系统通知「SSH 隧道自动重连失败」，内容含本地地址 → 远端和原因。Snake 在前台时也会显示。同一条隧道 60 秒内最多通知一次；失败后 10 秒内的访问直接拒绝、不再重试，之后有访问时再试。首次通知时系统会请求通知权限。
- 「等待重连」时主按钮为「断开」，右键菜单多了「立即重连」；退出 Snake 时，等待重连的隧道也会列进退出提醒（本地端口仍被占用）。
- 使用私钥的隧道在启动时就把私钥读入内存，断线后重连不再需要访问私钥文件。

## 安装与安全边界

- Apple Silicon（arm64），macOS 15+；打开 DMG，将 Snake.app 拖到 Applications。更新前退出旧版，复制时选择替换。
- **仅 ad-hoc 签名，未使用 Developer ID，未通过 Apple 公证。** 首次打开可能被系统阻止；按安装说明处理，不关闭 Gatekeeper。
- 数据库结构与 1.4.2 相同（schema v6），无需迁移。
- 本地端口仍只监听 `127.0.0.1`。断线期间端口保持打开，访问会触发对服务器的重连；不需要时请手动断开隧道。
- MCP 默认关闭，只监听 `127.0.0.1`；Token 赋予绑定 SSH 账号的命令权限，不是只读沙箱。
- Intel / Universal 2、公证及跨应用重启工作区恢复仍未交付。

## 本次验证

- Swift：282 项，275 通过、6 项外部夹具跳过；既有 `MountOperationsTests.testQuitIsCancelledWhenMountIsBusyOrMountTableCannotBeRead` 仍因 `invalidMapping` 失败，不能宣称全量通过。新增测试覆盖断线后等待重连、轮询不覆盖等待状态、重连失败文案、60 秒通知节流及停止后忽略迟到事件。
- Rust：40 项单元测试通过；在一次性本机 sshd 上运行 4 项隧道回归全部通过，包括「断线后端口保持监听、下次访问自动重连并正常转发」和「sshd 整体停止后访问被立即关闭、失败只上报一次、冷却期内不重试」。
- Release 构建、镜像校验、SHA-256、只读挂载后的签名/架构/资源/版本检查通过；应用、Helper 与 Rust dylib 均为 arm64，7 个 Metal shader 和 896 条英文字符串资源通过验证。
- 开发过程中发现并修复了首次弹出重连失败通知时的闪退（通知权限回调在系统队列执行，触发了主线程隔离断言）。修复后未在打包应用中再次实际触发通知；真实断网下的重连、通知外观、GUI 与干净 Mac 安装/升级由用户验收。

## 附件

- `Snake-1.4.3-macos-arm64.dmg`：11,605,991 字节。
- SHA-256：`7c03d7c833af153e3dfbf078da22edc7ce9f86d936e1677a4a87ddaa2cb1fe98`。
- 将 DMG 与 `.dmg.sha256` 放在同一目录，运行 `shasum -a 256 -c Snake-1.4.3-macos-arm64.dmg.sha256`。

## English

Snake 1.4.3 keeps SSH tunnels usable across dropped connections. When SSH drops, the local port stays open and the tunnel shows Waiting to Reconnect; the next connection to the port reconnects SSH (Reconnecting) and is forwarded normally once it succeeds, with simultaneous connections sharing one attempt. If reconnecting fails, the connection that triggered it is closed at once so the client notices immediately, the tunnel row shows the reason, and a system notification "SSH Tunnel Reconnect Failed" names the local → remote address and the cause, even while Snake is in front. Each tunnel notifies at most once a minute, and for 10 seconds after a failure further connections are refused without retrying. macOS asks for notification permission the first time. A waiting tunnel offers Disconnect and, in its context menu, Reconnect Now, and it is listed in the quit confirmation because its port is still held. Tunnels that use a private key load it into memory at start, so reconnecting never needs the key file again.

Apple Silicon / macOS 15+, build 1430, **ad-hoc signed and not notarized**; the database schema is unchanged (v6). Local ports still listen on 127.0.0.1 only; while waiting, an access to the port triggers a reconnect to the server, so disconnect tunnels you no longer need. Swift: 275 passed, 6 skipped and 1 pre-existing mount `invalidMapping` failure (282 total). Rust: 40 unit tests passed, and 4 tunnel regressions passed against a disposable loopback sshd, including reconnect-on-access after a drop and an immediate close with a single failure report when sshd is gone. A crash when the first reconnect-failure notification was posted was found and fixed during development; the packaged app has not posted a notification again since that fix. Real network drops, notification appearance, GUI and clean-Mac installation/upgrade are manual acceptance tasks. DMG and SHA-256 metadata above refer to the same verified artifact.
