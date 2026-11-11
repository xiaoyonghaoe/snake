# Snake 1.4.1

发布日期：2026-11-11 · 构建号：1410

## 新增

- **密钥管理**：密码管理新增「密钥」页，可导入 OpenSSH / PEM / PuTTY 私钥或在 Snake 里生成 Ed25519 密钥，并一键复制 `authorized_keys` 公钥。私钥统一转存为 OpenSSH 格式（口令不变），以仅本人可读的 0600 文件保存在 Snake 数据目录，口令加密保存；仍被会话使用的密钥不能删除。
- **SSH 隧道（本地转发，等同 `ssh -L`）**：在磁盘映射页切换到「SSH 隧道」，选会话、填本地端口与远端主机端口即可。本地只监听 127.0.0.1，每条隧道独立连接，显示活动连接数，断线后停在「已断开」由用户重连，可设随 Snake 启动。
- **连接日志**：终端与 SFTP 连接时可「查看日志」，记录每次尝试的地址、认证类型、用时、协商算法、失败阶段码与自动重试，不含密码或口令，可复制。
- **连接失败卡片**：连接失败时动画卡片保留，中间链路显示为断开，给出原因、「重新连接」和「查看日志」。
- **右键菜单**：终端新增右键菜单（复制、粘贴、粘贴所选内容、全选、清屏、上传文件到当前目录、在 SFTP 中打开当前目录、复制 SSH 命令、重新连接、查看连接日志）；SSH 会话页空白处右键可新建会话或文件夹。所有右键菜单统一风格：带图标、分组小标题、删除置底标红、不可用项置灰、无省略号。
- **服务器间互传**：在两个 SFTP 标签之间拖动文件时经本机中转目录（设置 › 传输 › 服务器互传可改），先下载再上传，结束后立即删除中转文件。

## 改进

- 会话编辑页：「密码类型」下拉切换密码与密钥，两种模式弹窗高度一致；密钥可从密钥管理下拉选用；查看密码改为输入框内的眼睛图标；显示创建与最近更新时间。
- 查看已保存的密码或口令验证一次后，30 秒内不再重复验证。
- 密码与密钥列表显示创建和修改时间；密码管理移到右上角整窗标签，行高与操作按钮重新排版。
- SSH 会话页：卡片只显示图标、名称与地址，双击打开终端，SFTP 在右键菜单；顶部位置、搜索与新建按钮合成一行；新开的会话标签打开上次浏览的文件夹。
- 设置改为带侧栏的大窗口（外观、传输、快捷键、终端）。
- 连接更快：目录列表流水线读取，shell 探测与 PTY 申请并行；Keepalive 5 秒、握手超时 10 秒，连接中可取消。
- 断线重连：重连提示接在已有输出下方，不再跳回首行；重连后不重复显示登录横幅。
- SFTP 标签断网后自动发现连接已断开，按 0.5/2/5 秒重连并回到原目录，不再停在「SSH 握手失败：Disconnected」。

## 安装与安全边界

- Apple Silicon（arm64），macOS 15+；打开 DMG，将 Snake.app 拖到 Applications。更新前退出旧版，复制时选择替换。
- **仅 ad-hoc 签名，未使用 Developer ID，未通过 Apple 公证。** 首次打开可能被系统阻止；按安装说明处理，不关闭 Gatekeeper。
- 会话数据库升级到 schema v6：v5 删除从未展示的传输历史表，v6 新增 `ssh_tunnels`；旧库首次打开时自动迁移。
- MCP 默认关闭，只监听 `127.0.0.1`；Token 赋予绑定 SSH 账号的命令权限，不是只读沙箱。
- Intel / Universal 2、公证及跨应用重启工作区恢复仍未交付。

## 本次验证

- Swift：277 项，270 通过、6 项外部夹具跳过；既有 `MountOperationsTests.testQuitIsCancelledWhenMountIsBusyOrMountTableCannotBeRead` 仍因 `invalidMapping` 失败，不能宣称全量通过。
- Rust：40 项单元测试通过；在一次性本机 sshd 上运行的 7 项回归全部通过（SFTP 4 项，含断线后句柄报告关闭；隧道 3 项，含 2 MB 并发转发、远端拒绝与断线回调）。
- Release 构建、镜像校验、SHA-256、只读挂载后的签名/架构/资源/版本检查通过；应用、Helper 与 Rust dylib 均为 arm64，7 个 Metal shader 和 876 条英文字符串资源通过验证。
- GUI、真实断网、真实服务器上的隧道与密钥登录、干净 Mac 安装/升级由用户验收，本轮不替代这些人工测试。

## 附件

- `Snake-1.4.1-macos-arm64.dmg`：11,636,955 字节。
- SHA-256：`3abacecffe846d542090f3254ad28f5387898d01194e01f0db433ec700061d88`。
- 将 DMG 与 `.dmg.sha256` 放在同一目录，运行 `shasum -a 256 -c Snake-1.4.1-macos-arm64.dmg.sha256`。

## English

Snake 1.4.1 adds a key library to the password manager: import OpenSSH, PEM or PuTTY private keys or generate Ed25519 keys in Snake, copy the `authorized_keys` line, and pick keys when creating sessions. Keys are stored as owner-only OpenSSH files with encrypted passphrases, and a key still used by a session cannot be deleted. The Disk Mappings page gains SSH Tunnels (local forwarding, like `ssh -L`) that listen on 127.0.0.1 only, show active connections, stop as Disconnected until you reconnect, and can start with Snake.

Terminal and SFTP tabs keep a per-tab connection log (address, authentication type, duration, negotiated algorithms, failure stage, retries; never passwords) and keep the connecting card after a failure, with the link shown broken plus Reconnect and View Log. The terminal has a context menu (copy, paste, paste selection, select all, clear screen, upload to the current directory, open it in SFTP, copy the SSH command, reconnect, log), and every context menu now shares one style with icons, small group headings, destructive items last in red and no ellipses. Dragging files between two SFTP tabs relays them through a local folder and deletes the relay copy afterwards.

The session editor switches password and key with an Authentication dropdown at a fixed height and reveals secrets with an inline eye icon; one authentication now covers other secrets for 30 seconds. Passwords and keys show created and modified times. The session page uses compact cards, a single header row, and reopens the folder browsed last. Settings is a larger window with a sidebar. Connections are faster (pipelined listing, parallel shell detection and PTY setup, 5 s keepalive, 10 s handshake timeout, cancellable). Reconnect notices continue below existing output, and SFTP tabs detect a dropped connection, reconnect on a 0.5/2/5 s schedule and return to the same directory.

Apple Silicon / macOS 15+, build 1410, **ad-hoc signed and not notarized**. The session database migrates to schema v6 on first open. Swift: 270 passed, 6 skipped and 1 pre-existing mount `invalidMapping` failure (277 total). Rust: 40 unit tests and all 7 loopback-sshd regressions passed. GUI, real network drops, tunnels and key login on real servers, and clean-Mac installation/upgrade are manual acceptance tasks. DMG and SHA-256 metadata above refer to the same verified artifact.
