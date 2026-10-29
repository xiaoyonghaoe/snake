# Snake 1.3.0

发布日期：2026-10-29 · 构建号：1300

## 更新

- 支持密码会话的 SSHFS 磁盘挂载。密码（以及私钥会话已保存的口令）经受管 SSH_ASKPASS 通道交给 ssh：App 在私有临时目录开一次性 Unix socket，只回答本用户、可执行文件为 SnakeMountHelper 且处于本次挂载进程组内的 askpass 进程；不经 argv、环境变量或文件传密，挂载结束即清零。
- 挂载只尝试一次密码（`NumberOfPasswordPrompts=1`），避免反复失败触发服务器封禁；挂载失败、超时或进程退出时清理整个进程组，不再残留被 sshfs 双重 fork 出去的 ssh 与 `mount_macfuse`。
- MCP 服务移出设置窗口，成为右上角「磁盘映射」旁的独立入口，和终端、SFTP 一样以整窗标签显示：服务状态卡加分列 Token 表；命令审计改为顶部筛选、表格与右侧详情面板、底部滚动删除设置。
- 磁盘映射页按同一样式重构，去掉固定宽度的横向滚动，映射行新增编辑按钮；列表与详情卡的状态颜色保持一致。
- Token 新建/编辑、Token 查看与磁盘映射新增/编辑统一使用同一套分组表单弹窗。
- 设置窗口改为模态：打开期间不能操作其他 Snake 窗口，关闭后才能继续；设置窗口不可最小化，Command-W 可直接关闭。

## 安装与安全边界

- Apple Silicon（arm64），macOS 15+；打开 DMG，将 Snake.app 拖到 Applications。更新前退出旧版，复制时选择替换。
- **仅 ad-hoc 签名，未使用 Developer ID，未通过 Apple 公证。** 首次打开可能被系统阻止；按安装说明处理，不关闭 Gatekeeper。
- 密码型挂载要求主机密钥已在 Snake 中信任过（`StrictHostKeyChecking=yes`）。macFUSE / sshfs 仍需自行安装。
- MCP 默认关闭，只监听 `127.0.0.1`。Token 赋予绑定 SSH 账号的命令权限，不是只读沙箱；命令与输出摘录会写入审计，不要在其中传入秘密。
- Intel / Universal 2、公证及跨应用重启工作区恢复仍未交付。

## 本次验证

- Swift：233 项，227 通过、5 项外部夹具跳过；既有 `MountOperationsTests.testQuitIsCancelledWhenMountIsBusyOrMountTableCannotBeRead` 仍因 `invalidMapping` 失败，不能宣称全量通过。新增 SSHFS 密码通道测试 7 项全部通过，覆盖受信交付、非凭据提示、非后代与非 Helper 进程拒绝、双重 fork 后的进程组交付及失败后进程组清理。
- Rust：32 项单元测试通过；3 项 SFTP 回归需要一次性本机 sshd，本轮未运行（Rust 代码自 1.2.0 未改动）。
- 用真实 sshfs 对不可达地址实测：ssh 与 `mount_macfuse` 归属 launchd 但保留挂载进程组，按组清理后无残留。开发包对一台真实密码服务器挂载成功。
- Release 构建、镜像校验、SHA-256、只读挂载后的签名/架构/资源/版本检查通过；7 个 Metal shader 和 700 条英文字符串资源通过验证。
- GUI、真实 Touch ID、Finder 手势及干净 Mac 安装/升级由用户验收，本轮不替代这些人工测试。

## 附件

- `Snake-1.3.0-macos-arm64.dmg`：10,455,647 字节。
- SHA-256：`10a9a0c80e2ab92db634612f2c586a349d9cad7927a359e27e1bc146dcb54de3`。
- 将 DMG 与 `.dmg.sha256` 放在同一目录，运行 `shasum -a 256 -c Snake-1.3.0-macos-arm64.dmg.sha256`。

## English

Snake 1.3.0 adds SSHFS mounts for password sessions. The password (or a private key's saved passphrase) reaches ssh through a managed SSH_ASKPASS channel: the app opens a one-off Unix socket in a private temporary folder and answers only an askpass process owned by the user, running SnakeMountHelper, and inside that mount's process group. Secrets never go through argv, environment variables or files, and are wiped when the mount ends. Mounts try the password once to avoid server lockouts, and a failed mount now cleans up its whole process group, including the ssh and `mount_macfuse` that sshfs double-forks away.

The MCP service moves out of Settings into its own full-window tab beside Disk Mappings, with a service status card, a column-based token table, and an audit view with filters, a table, an inline detail panel and retention controls. The Disk Mappings page is rebuilt in the same style, and token and mapping add/edit/view sheets now share one sectioned form design. The Settings window is modal: other Snake windows are unavailable until it is closed.

Apple Silicon / macOS 15+, build 1300, **ad-hoc signed and not notarized**. Swift: 227 passed, 5 skipped and 1 pre-existing mount `invalidMapping` failure (233 total), including 7 new askpass channel tests. Rust: 32 unit tests passed; the 3 isolated SFTP regressions were not run this time (Rust code is unchanged since 1.2.0). GUI, system authentication and clean-Mac installation/upgrade are manual acceptance tasks. DMG and SHA-256 metadata above refer to the same verified artifact.
