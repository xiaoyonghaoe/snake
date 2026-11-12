# Snake 1.4.2

发布日期：2026-11-12 · 构建号：1420

## 新增

- **退出时提醒运行中的 SSH 隧道**：退出 Snake 时，如还有正在连接或已连接的隧道，会和未卸载的目录在同一个确认框里列出（本地端口 → 远端、备注、会话与状态）。只有隧道时按钮为「断开并退出」；取消则一切保持原样。
- **密码自动填充开关**：设置新增「隐私与安全」页，可关闭「点击密码输入框时显示系统密码自动填充」。关闭后，Snake 的密码与私钥口令输入框不再弹出 macOS「密码」的自动填充建议；默认开启，不改动系统设置。
- **编辑密钥窗口**：双击密钥（或右键「编辑密钥」）打开，可改名，并显示完整公钥（可复制）、算法、口令状态、指纹、使用它的会话以及创建/修改时间。

## 改进

- 磁盘映射页与 SSH 隧道页使用同一套列表：左侧名称与路径，右侧状态和「自动挂载/自动连接」徽标，最右是挂载/打开或连接/断开、编辑和删除按钮；「随启动」不再是行内开关，避免和启动按钮混淆。顶部合成一行（分段切换、数量摘要、环境就绪标签、刷新与新增），只在缺少 macFUSE/SSHFS 时显示提示。
- 映射编辑页的「访问路径」改为竖向三步：远程目录 → 实际挂载点（含 Finder 磁盘名）→ Finder 入口，每条路径整行显示并可复制，不再挤成三列被截断。
- 映射、隧道、密码、密钥和 MCP Token 列表：单击立即高亮选中（不再等双击间隔），双击打开编辑。
- 磁盘映射与 SSH 隧道的入口图标改为接入网络的磁盘。

## 修复

- MCP 审计页修改「保留天数/保留条数」时，逐字输入会立即生效并清理记录（例如输入 1000 途经 1 时只剩最新一条）。现在按回车或离开输入框才生效，修改本身不删除记录；超出部分在启动、每新增 100 条、每小时或点「立即清理」时删除。

## 安装与安全边界

- Apple Silicon（arm64），macOS 15+；打开 DMG，将 Snake.app 拖到 Applications。更新前退出旧版，复制时选择替换。
- **仅 ad-hoc 签名，未使用 Developer ID，未通过 Apple 公证。** 首次打开可能被系统阻止；按安装说明处理，不关闭 Gatekeeper。
- 数据库结构与 1.4.1 相同（schema v6），无需迁移。
- MCP 默认关闭，只监听 `127.0.0.1`；Token 赋予绑定 SSH 账号的命令权限，不是只读沙箱。
- Intel / Universal 2、公证及跨应用重启工作区恢复仍未交付。

## 本次验证

- Swift：281 项，274 通过、6 项外部夹具跳过；既有 `MountOperationsTests.testQuitIsCancelledWhenMountIsBusyOrMountTableCannotBeRead` 仍因 `invalidMapping` 失败，不能宣称全量通过。新增测试覆盖退出提醒内容、运行中隧道判定、自动填充开关对应的输入框类型，以及修改保留条数不删除记录。
- Rust：40 项单元测试通过；本版未改动 Rust 核心，本机 sshd 上的 SFTP 与隧道回归未重新运行。
- Release 构建、镜像校验、SHA-256、只读挂载后的签名/架构/资源/版本检查通过；应用、Helper 与 Rust dylib 均为 arm64，7 个 Metal shader 和 889 条英文字符串资源通过验证。
- 自动填充开关的效果按本机探针确认：显式的密码类型会弹出自动填充，自定义类型不会；在真实 Snake 窗口里点击密码框的效果、退出确认框、GUI 与干净 Mac 安装/升级由用户验收。

## 附件

- `Snake-1.4.2-macos-arm64.dmg`：11,685,212 字节。
- SHA-256：`a8dc630b8de9c56363478fae472f0a87aec78569444ee069fdb4c9d72bbd483e`。
- 将 DMG 与 `.dmg.sha256` 放在同一目录，运行 `shasum -a 256 -c Snake-1.4.2-macos-arm64.dmg.sha256`。

## English

Snake 1.4.2 warns about SSH tunnels when quitting: tunnels that are connecting or connected are listed in the same confirmation as directories still mounted (local port → remote, note, session and state). With only tunnels the button reads Disconnect and Quit, and cancelling leaves everything running. Settings gains a Privacy & Security page with a switch for macOS Passwords AutoFill; when off, Snake's password and key passphrase fields stop offering AutoFill suggestions (on by default; no system setting changes). Double-clicking a key opens a new key editor that renames it and shows its full public key with a copy button, algorithm, passphrase state, fingerprint, the sessions using it, and created/modified times.

Disk mappings and SSH tunnels now share one list style: name and path on the left, status and an Auto-mount/Auto-connect badge on the right, then Mount/Open or Connect/Disconnect, edit and delete buttons; "starts with Snake" is a badge rather than a switch beside the start button. The header is one row, and the macFUSE/SSHFS notice appears only when something is missing. The mapping editor lists its access paths top to bottom (remote folder → mount point with the Finder disk name → Finder entry), each on a full line with a copy button. Mapping, tunnel, password, key and MCP token rows highlight on the first click and open their editor on a double-click. The entry icon for mappings and tunnels is now a networked drive.

Fixed: editing the MCP audit retention limits applied every keystroke and pruned at once (typing 1000 passed through 1 and left a single record). Limits now apply on Return or when the field loses focus, changing them never deletes anything by itself, and older records are removed at launch, every 100 new records, hourly, or with Clean Up Now.

Apple Silicon / macOS 15+, build 1420, **ad-hoc signed and not notarized**; the database schema is unchanged (v6). Swift: 274 passed, 6 skipped and 1 pre-existing mount `invalidMapping` failure (281 total). Rust: 40 unit tests passed; the Rust core is unchanged, so loopback-sshd regressions were not rerun. The AutoFill switch was checked with a local probe (an explicit password type shows AutoFill, a custom type does not); clicking password fields in the real Snake window, the quit confirmation, GUI and clean-Mac installation/upgrade are manual acceptance tasks. DMG and SHA-256 metadata above refer to the same verified artifact.
