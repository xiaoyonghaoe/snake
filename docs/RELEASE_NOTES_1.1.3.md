# Snake 1.1.3

## 更新

- 设置新增密码管理：加密保存常用账号与密码，可填入 SSH 会话；条目修改后支持多选关联会话同步，会话独立修改凭据时解除关联。
- 私钥认证的会话编辑页展示实际本机密钥路径，文件失效时提示重新选择。
- 修复 SFTP `⌘F` 检索、`⌘U` 上传快捷键的工作窗口路由；连接未就绪时显示原因。
- 新建 SSH 会话标签默认使用 `⌘T`，可在设置中自定义；标签栏尾部双击和空工作区入口继续保留。
- 新建会话标签自动聚焦检索框，切回已有标签不抢占焦点。
- 改进密码查看的窗口就绪等待和取消重试，避免系统身份验证未出现或迟到回调显示凭据。
- 包含 1.1.2 发布后的终端主题扩展：Catppuccin、Gruvbox、Solarized 与 `.itermcolors` 导入；移除远端 `ls/ll` 自动颜色配置，保留本地高亮及目录 Hook。

## 安装与限制

- Apple Silicon（arm64），macOS 15+；打开 DMG，将 Snake.app 拖到 Applications。
- 本包仅使用 ad-hoc 签名，未完成 Developer ID 签名与 Apple 公证，首次启动可能出现系统安全提示。
- 新密码库及会话密码均加密保存；查看明文需要 macOS 身份验证。测试签名升级可能再次要求钥匙串访问批准。
- Swift 自动化：197 项，5 项因外部夹具缺失跳过，1 项既有挂载 `invalidMapping` 失败；其余通过。Rust：22 项通过。不能将全量测试描述为全部通过。
- GUI、Touch ID、真实 Finder 操作、干净 Mac 安装与升级由用户验收；本次未替代这些人工验收。
- 密码型 SSHFS 挂载、Intel / Universal 2、公证以及跨应用重启的工作区恢复仍未交付。

## English

Snake 1.1.3 adds an encrypted password library with selective synchronization to linked SSH profiles, displays resolved private-key paths, fixes SFTP keyboard shortcut routing, makes the new-session-tab shortcut configurable (default Command-T), and automatically focuses search in newly opened session tabs. Credential reveal handles window readiness and cancellation more reliably. The release also includes the post-1.1.2 terminal theme additions and `.itermcolors` import without modifying remote `ls/ll` color settings.

Apple Silicon / macOS 15+, ad-hoc signed and **not notarized**. Swift: 197 tests, 5 skipped, 1 pre-existing mount `invalidMapping` failure. Rust: 22 passed. GUI, system authentication and clean-Mac installation/upgrade acceptance remain manual.
