**简体中文** · [English](en/SNAKE_DEVELOPMENT_PLAN.md)

# Snake macOS SSH 客户端开发计划

## 当前实现进度（2026-09-02）

已落地：

- 按高保真原型实现 AppKit/SwiftUI 主窗口、会话树、统一终端/SFTP 标签、Bonsplit 分屏、标签撕出窗口和跨窗口落点。
- 会话双击打开终端，右键打开终端/SFTP/修改/二次确认删除；会话可拖入同级分组。
- 当前开发阶段会话密码/私钥口令暂存于权限为 `0600` 的明文凭据文件，SQLite 仅保存 credential reference；后续替换为外部密码工具适配器，私钥仍只保存 security-scoped bookmark。
- Rust `snake_core` 通过 UniFFI 接入 Swift，负责 WAL SQLite 中的分组、会话、映射和传输历史；旧 JSON 配置会一次性迁移。
- Rust/libssh2 SFTP 真实连接：密码/私钥认证、Snake 自管 `known_hosts`、首次指纹确认、指纹变化阻断、目录浏览、创建、重命名、删除、上传、缓存下载打开。
- Finder 文件/文件夹选择和拖入、SFTP 面板间真实 1 MiB 内存流式互传，以及由 Rust 原子控制器驱动的进度、速度、暂停、继续、取消；异常启动转 `interrupted`。
- SFTP 本地上传支持断点续传和大文件并行分片：默认超过 50 MB 使用 4 个独立连接，阈值与并发数可在设置中调整；覆盖时先合并到远端隐藏暂存文件，再通过 `mv -f` 替换正式文件。
- SFTP 通过 `lstat/readlink` 识别软连接：文件表展示链接目标，目录链接可进入、文件链接可打开、删除只执行 `unlink`，跨 SFTP 复制保留原始链接目标。
- 远程权限编辑支持对真实文件夹递归应用 `chmod -R`；软连接不会开放递归选项，避免越过链接边界修改外部目录。
- 主窗口不常驻传输条；当前 SFTP 标签有本地上传时，文件表底部项目统计左侧显示迷你确定进度，完成两秒后收为记录图标。点击后仅查看当前标签本次生命周期的上传记录和控制按钮。
- 设置窗口已提供传输阈值、分片并发数、终端等宽字体和字号；终端字体变化会即时应用到稳定 SwiftTerm 表面，不触发 SSH 重连。
- Rust/libssh2 `TerminalHandle` 已替换系统 `ssh`：SwiftTerm 保留稳定渲染表面，UniFFI 提供 PTY 输出回调、输入、resize 和关闭；终端与 SFTP 共用 Snake `known_hosts`、CredentialStore、15 秒超时和 30 秒 Keepalive。
- 终端 I/O 由单一 Rust 工作线程独占 libssh2 Session/Channel，Swift 输入、resize 和关闭通过命令队列串行化；已在真实 OpenSSH 服务器验证密码认证、空闲 20 秒后输入、`stty size` resize、命令输出和状态码 0 退出。
- macFUSE/sshfs 检测、受管挂载路径、私钥 SSHFS、软链接、Finder 打开和安全卸载；密码不会进入 argv 或环境变量。
- 自包含调试 App 打包：Rust dylib 使用 `@rpath` 嵌入 Frameworks，并携带 `SnakeMountHelper`。

仍在后续阶段：

- SFTP 重名“应用到当前批次”、自动重命名。
- 密码型 SSHFS 的受管 `SSH_ASKPASS` FIFO、占用进程 `lsof` 提示、强制卸载确认。
- Universal 2、Developer ID、公证 DMG 与隔离 OpenSSH 集成测试。

> 文档版本：1.0  
> 目标平台：macOS 15+  
> 界面语言：简体中文（源语言、默认与回退）、English  
> 技术栈：Swift、SwiftUI、AppKit、Rust、UniFFI  
> 当前阶段：生产工程持续实现，Rust SSH PTY 与核心 SFTP 链路已完成

## 1. 文档目标

本文档用于指导 Snake macOS SSH 客户端从现有 HTML 高保真原型进入生产开发，固定产品范围、交互规则、技术架构、数据模型、安全边界、阶段交付物和验收标准。

第一版产品包含以下核心能力：

- SSH 会话、单层分组、标签、图标和凭据管理。
- 多终端标签、横向/纵向分屏和跨分栏拖动。
- 类似 Google Chrome 的标签撕出独立窗口、跨窗口移动和重新合并。
- 从 SSH 会话打开 SFTP，支持文件浏览、文件选择器上传和远程文件打开。
- 同窗口或跨窗口的双 SFTP 面板远程文件互传。
- 跨 SFTP 传输使用全局任务状态；本地上传记录仅驻留当前 SFTP 标签内存，提供文件级进度、暂停、继续、取消与失败重试。
- 基于 macFUSE/SSHFS 的本地磁盘映射、依赖诊断和安全卸载。
- Developer ID 签名、公证和 DMG 分发。

内部交互原型不随公开源码发布。生产实现应遵循经确认的信息架构，但不得把原型 HTML/CSS 代码直接嵌入最终应用。

## 2. 产品与交互约定

### 2.1 主窗口结构

每个 Snake 工作窗口都采用完整结构：

1. macOS 统一标题栏和工具栏。
2. 可隐藏的会话/磁盘映射侧栏。
3. Bonsplit 标签与分栏工作区。
4. 标签下方的连接带。
5. SFTP 文件表内按需出现的紧凑上传进度；无上传记录时不占用任何空间。

主界面不保留右侧会话检查器。会话信息通过侧栏、连接带、编辑表单和上下文菜单呈现。

视觉基准：

- Chrome Frost：`#ECEEF2`
- Canvas：`#F7F8FA`
- Ink：`#1D1D1F`
- Muted：`#6E7380`
- Action Blue：`#0A84FF`
- Secure Mint：`#2DBE8C`
- Terminal Surface：`#111418`
- 工具栏高度：52pt
- 标签栏高度：34pt
- 侧栏行高：28pt
- 文件表格行高：30pt
- 标题使用 SF Pro Display，控件使用 SF Pro Text，IP、端口、路径、指纹和终端使用 SF Mono

“连接带”是 Snake 的标志性界面元素。终端连接带持续显示连接状态与 `user@host:port`，安全锁弹层展示实际协商算法和主机指纹；由于 SSH 没有可靠查询交互式 shell 当前目录的标准 API，终端不显示猜测路径。SFTP 路径由文件浏览器自身管理。除窗口和系统弹层外不堆叠卡片阴影。

### 2.2 会话入口

- 侧栏只显示 SSH 会话和磁盘映射，不显示独立 SFTP 导航项。
- 双击 SSH 会话始终创建新的终端标签；同一会话允许同时存在多个终端。
- SSH 会话右键菜单包含：打开新终端、打开 SFTP、修改、删除。
- SFTP 标签只能从 SSH 会话创建。
- 分组首版为单层结构，会话可以在同级分组间拖动。
- 标签关闭不删除 SSH 会话配置。

### 2.3 工作区生命周期

- 终端和 SFTP 使用统一的工作标签模型。
- 标签可在一个窗口内重排、移动到其他分栏或拖到边缘创建分屏。
- 标签可撕出为完整独立窗口，也可拖回原窗口或其他 Snake 窗口。
- 应用只持久化会话、映射、设置和历史，不恢复终端、SFTP 标签、窗口数量或 Bonsplit 布局。
- 应用重新启动时只创建一个空工作窗口。

## 3. 总体技术架构

### 3.1 工程组成

建议使用 Swift Package Manager 管理原生端：

| 模块 | 职责 |
| --- | --- |
| `SnakeExecutable` | 应用入口、AppDelegate、菜单和生命周期 |
| `SnakeApp` | SwiftUI/AppKit 界面、窗口、Keychain、Finder、状态协调 |
| `SnakeCoreBindings` | UniFFI 生成的 Swift 绑定和 Swift 侧适配器 |
| `SnakeMountHelper` | 受约束的 SSHFS 挂载辅助进程 |
| `snake_core` | Rust 模型、SQLite、SSH/SFTP、传输队列和校验逻辑 |

职责边界：

- AppKit：`NSWindow`、工具栏、菜单、快捷键、拖放、文件选择器、Finder、Keychain、权限和挂载进程。
- SwiftUI：会话树、编辑表单、连接状态、SFTP 工具栏、传输队列和设置界面。
- SwiftTerm：终端渲染和输入，通过 `NSViewRepresentable` 或 `NSViewControllerRepresentable` 接入。
- `NSTableView`：大目录 SFTP 文件列表，避免大量行和频繁更新时的 SwiftUI 性能问题。
- Rust：业务模型、数据库、SSH/PTTY、SFTP、远程流式传输、任务状态机和连接校验。
- UniFFI：Swift/Rust 跨语言记录、枚举、handle 和 observer。

### 3.2 主要依赖

Swift 侧：

- [Bonsplit](https://github.com/almonk/bonsplit)：窗口内标签、分栏和拖动。
- SwiftTerm：终端控件。
- Security.framework：macOS Keychain。
- AppKit、SwiftUI、UniformTypeIdentifiers。

Rust 侧：

- `ssh2`/libssh2：SSH、PTY 和 SFTP。
- `rusqlite`：SQLite 访问，使用 bundled SQLite。
- `uniffi`：Swift 绑定。
- `serde`：配置和内部事件序列化。
- `uuid`：稳定标识符。
- `sha2`：挂载目录和缓存键。
- `thiserror`：结构化错误。
- `zeroize`：临时凭据内存清理。

依赖必须锁定到 `Package.resolved` 和 `Cargo.lock`。版本升级需要通过完整回归测试。

### 3.3 线程模型

- Swift UI 状态仅在 `@MainActor` 更新。
- 每个交互式终端连接使用一个独立阻塞工作线程和命令通道。
- SFTP 浏览连接独立于终端连接。
- 传输任务由 Rust 全局调度器管理，不依赖某个 SFTP 视图是否仍然存在。
- UniFFI observer 回调不得等待 Swift 返回；Swift 收到事件后切换到主线程。
- 终端输出应合并为有界批次再回调，避免逐字节跨 FFI。

## 4. Bonsplit 与 Chrome 式多窗口

### 4.1 框架决策

不新增多窗口第三方框架。Bonsplit 负责单窗口内部的标签重排、跨分栏移动和横纵分屏；AppKit 负责原生窗口和跨窗口拖放。

Bonsplit 当前没有公开的标签撕出接口，因此维护一个最小化 MIT 许可 fork。修改范围限制为：

- 标签拖动开始、更新和结束时提供屏幕坐标回调。
- 提供 `detachTab` 和 `insertExternalTab` 控制器方法。
- 提供外部标签落点和插入位置回调。
- 保持分割树、动画、键盘导航和内容生命周期不变。

fork 必须固定到明确 commit，单独记录补丁，保留上游 LICENSE，并优先将通用能力提交上游。

不使用 `NSWindowTabGroup`。系统窗口标签只能组合整个原生窗口，无法表达单个 Snake 窗口内部的 Bonsplit 多分栏。

### 4.2 状态所有权

```text
ApplicationStore
├── SessionRepository
├── GlobalTransferStore
├── MountStore
├── CredentialCoordinator
├── ActiveConnectionRegistry
└── WorkspaceWindowCoordinator
    ├── WorkspaceWindowState A
    │   └── BonsplitController A
    └── WorkspaceWindowState B
        └── BonsplitController B

WorkspaceTabRuntime
├── TerminalRuntime + TerminalHandle + TerminalSurfaceController
└── SFTPRuntime + SFTPHandle + NavigationState
```

- `ApplicationStore` 是应用级共享状态。
- `WorkspaceWindowState` 只保存一个窗口的标签、分栏、焦点和界面展开状态。
- `WorkspaceTabRuntime` 独立于窗口存在，保证标签跨窗口时连接和内容状态不重建。
- `WorkspaceWindowCoordinator` 注册全部窗口，负责命中测试、创建、关闭和标签移动事务。

### 4.3 拖放载荷

定义以下 UTType：

| 类型 | 用途 | 载荷 |
| --- | --- | --- |
| `com.snake.workspace-tab` | 标签移动 | `windowID`、`tabID`、transaction ID |
| `com.snake.remote-file-reference` | SFTP 远程文件互传 | 进程内引用 ID、来源 profile、路径、类型 |

拖放载荷禁止包含密码、Keychain 内容、私钥路径、完整 SSH 配置或连接 handle。

### 4.4 标签移动事务

跨窗口移动采用两阶段提交：

1. 来源创建随机 transaction ID，并将 runtime 标记为 `moving`。
2. 目标窗口验证 tab、runtime 和落点仍然有效。
3. 目标预留标签位置或创建目标分栏。
4. 目标接管 `WorkspaceTabRuntime` 并完成视图挂载。
5. 目标确认成功后，来源删除原标签。
6. 任一步失败或用户按 Escape，目标撤销预留，来源恢复原标签。

拖动行为：

- 落到本窗口标签栏：由 Bonsplit 重排。
- 落到本窗口其他分栏：由 Bonsplit 移动。
- 落到窗口内容边缘：按命中边缘创建横向或纵向分栏。
- 落到其他窗口标签栏：插入指定索引。
- 落到其他窗口内容边缘：在目标窗口创建分栏后插入。
- 落到所有 Snake 窗口之外：在指针附近创建新窗口。

独立窗口默认尺寸为 1120×760，最小尺寸为 1024×700。新窗口需要限制在目标显示器的 `visibleFrame` 内。

来源分栏为空时自动关闭；来源窗口失去最后一个标签时自动关闭。应用必须至少保留一个空工作窗口。拖动最后一个标签时先显示目标窗口，再关闭来源窗口。

### 4.5 运行时保持

- 终端 PTY 和 Rust `TerminalHandle` 不因标签换窗而重连。
- `TerminalSurfaceController` 持有稳定 SwiftTerm 视图，在目标宿主中重新挂载，以保留缓冲、选择和滚动位置。
- SFTP runtime 保留连接、当前路径、历史、选择、排序和上传入口状态。
- Bonsplit view 不拥有连接生命周期；关闭或销毁视图不得隐式关闭 Rust handle。
- 跨 SFTP 传输任务由全局运行时持有；本地上传记录只属于发起上传的 SFTP 标签，关闭标签后释放且不写入 SQLite。
- 窗口仅保存侧栏与 Bonsplit 焦点；主窗口底部不显示常驻传输队列。
- 窗口设置 `isRestorable = false`，禁止 macOS 自动恢复工作区。

关闭包含活动终端的窗口时显示确认；确认后关闭该窗口内的终端。传输任务不随窗口关闭而取消。

## 5. 会话与分组管理

### 5.1 SSH 会话字段

- 名称
- 所属分组
- 主机名或 IP
- 端口，默认 22，范围 1...65535
- 用户名
- 认证方式：密码或私钥
- Keychain 引用
- 私钥 security-scoped bookmark
- 标签数组
- SF Symbol 图标名称
- 排序值

名称、主机、端口和用户名必填。密码和口令输入只写入 Keychain，不回填明文。

### 5.2 删除语义

删除会话必须二次确认，并按以下顺序执行：

1. 列出活动终端、SFTP 浏览连接和依赖映射。
2. 用户确认后停止活动终端和浏览连接。
3. 禁用依赖映射，但保留映射记录供用户重新绑定。
4. 保留带会话快照的传输历史。
5. 在 SQLite 事务中删除会话并解除关联外键。
6. 数据库事务成功后删除 Keychain 凭据和私钥 bookmark 引用。

如果数据库事务失败，不得提前删除凭据引用。凭据文件删除失败时记录不含秘密的修复事件并在下次启动重试清理。

## 6. SSH、终端与凭据安全

### 6.1 CredentialStore

- 当前后端：`~/Library/Application Support/Snake/credentials.json`。
- 文件权限强制为 `0600`，父目录权限强制为 `0700`。
- 密码引用：`<profileID>/password`；私钥口令引用：`<profileID>/key-passphrase`。
- SQLite 只保存 credential reference；凭据文件采用带版本号的 AES-256-GCM 密文格式，每次保存使用新 nonce。256 位随机密钥独立存于系统钥匙串，不同步、不嵌入应用。
- `CredentialStore` 保留 save/readData/delete 接口，后续可以替换为密码工具适配器。SSH、SFTP 与上传自动解密，不增加查看明文所用的身份验证门槛。
- 启动及首次访问均支持旧明文文件迁移；写入临时密文、解密校验后原子替换，不创建明文备份。缺失密钥、损坏文件或写入失败时停止操作并保留原文件。
- 旧 Keychain 引用首次成功读取后迁移到加密后端；系统钥匙串仍用于保存加密密钥。
- 会话编辑页查看密码／口令须通过新 LAContext 的 deviceOwnerAuthentication；已保存值回填原框可编辑，有草稿时不读旧值覆盖。30 秒后、失焦或进入后台恢复圆点并保留草稿，关闭表单或切换认证方式才清除。仅查看不修改不重写凭据。具体边界和验收见 [凭据加密与查看](CREDENTIAL_SECURITY.md)。
- 私钥由 `NSOpenPanel` 选择，保存 security-scoped bookmark，不复制文件。

Swift 解析凭据后，以 `Data`/字节通过 UniFFI 传给 Rust。Rust 使用 `Zeroizing<Vec<u8>>`，认证结束或失败后立即清零。

### 6.2 主机密钥

- 首次连接显示主机、端口、算法和 SHA-256 指纹。
- 用户可选择仅本次接受、接受并保存或取消。
- 保存后写入 Snake 管理的 `known_hosts`。
- 已知主机指纹变化时禁止认证，并显示旧指纹、新指纹和移除信任入口。
- 终端、SFTP 和挂载共用同一主机信任数据。

### 6.3 终端连接

- `TERM=xterm-256color`
- UTF-8 输入输出
- 默认连接超时 15 秒
- Keepalive 间隔 30 秒
- 支持 PTY resize、写入、关闭和状态订阅
- 浅色/深色终端调色板跟随应用外观切换，切换时不重建 PTY、连接或滚动缓冲
- Rust 使用 libssh2 的实际协商结果提供主机密钥、SHA256 指纹、密钥交换、双向加密与完整性算法；界面通过安全锁弹层展示，不使用静态算法文案
- 终端连接带不显示固定或推测的工作目录，也不向远端 shell 注入路径跟踪 Hook
- 单次跨 FFI 输出块上限建议为 64 KiB
- 网络错误、认证失败、主机密钥错误和远端退出使用不同错误码
- 终端的瞬时 `Connection` 错误会在约 400 ms 后自动重试一次；认证、主机密钥和参数错误不自动重试。TCP、握手、通道、PTY 与 shell 启动阶段分别报告错误上下文。

秘密不得出现在：

- SQLite
- 日志
- 崩溃上下文
- `Process` 参数
- 环境变量
- `NSPasteboard`
- 拖放载荷
- 用户可复制的错误信息

## 7. SFTP 与传输队列

### 7.1 SFTP 浏览

每个 SFTP 标签使用独立 SSH/SFTP 连接，功能包括：

- 可直接输入绝对地址并回车跳转的路径栏，以及当前地址复制。
- 目录树和高密度文件表格。
- 名称、大小、类型、修改时间和权限列。
- 刷新、返回、前进、上级目录。
- 空白区右键新建文件、新建目录、上传文件或文件夹。
- 文件/文件夹右键重命名、修改八进制权限、复制地址、跨 SFTP 复制和删除。
- 软连接使用独立图标与 `→ 目标` 标识；目录软连接按目录导航，删除软连接不删除目标。
- 文件和文件夹上传。
- 远程文件下载后打开。

目录双击进入目录；文件双击先下载到受控缓存，再由 `NSWorkspace` 使用默认应用打开。首版不监控外部编辑，也不自动回传修改。

远程打开缓存：

```text
<缓存根目录>/<profileID>/<远端路径 SHA-256 前 16 位>-<文件名>
```

缓存根目录默认为 `~/Library/Caches/Snake/RemoteOpen`，可在设置中更换；写入采用「临时文件 + 原子替换」，文件权限 `0600`、目录 `0700`。

清理在启动时、打开文件前与手动触发时执行，满足任一条件即删除：文件超过保留时长（默认 7 天）或总量超过上限（默认 500 MB）。容量回收按最久未用优先，并始终保留刚打开的那一份。清理只处理符合上述布局的条目，不触碰所选目录中的其他文件。

### 7.2 上传入口

- 在文件表空白区右键选择“上传文件”或“上传文件夹”，通过 `NSOpenPanel` 多选本地项目。
- Finder 拖入时只读取文件 URL、名称、类型和大小。
- 投放遮罩必须展示目标 SSH 会话和远程目录。
- 文件夹任务先扫描总量；扫描期间显示不确定进度，完成后切换为确定进度。

#### 7.2.1 断点续传与并行分片

- 小文件和大文件统一写入目标目录中的确定性隐藏分片，不直接截断正式目标。
- 默认阈值为 50 MB；仅当文件严格大于阈值时启用并行，默认并发为 4，可在设置中配置为 1～8。另设「每主机连接数」（2～16，默认 8）限制对单台主机的传输连接总数，超出时传输排队等待，避免多标签同时传输把同一服务器打成连接风暴。
- 并行分片使用相互独立的 SSH/SFTP 连接。每个连接只写一个连续区间，避免多个线程对同一远程句柄随机写入。
- 分片名称由目标路径、本地大小、修改时间与分片数计算的 SHA-256 摘要派生，不包含凭据。重新选择同一版本文件时，Rust 读取远端分片长度并从对应本地偏移继续。
- 暂停和取消由所有分片共享的 `CoreTransferControl` 驱动；中断时保留完整或部分分片，供用户再次发起相同上传时恢复。
- 所有分片完成后，远端先使用 `cat` 顺序合并为同目录 `staging` 文件。若用户明确选择覆盖，最后执行 `mv -f -- <staging> <target>`；合并或传输失败时旧目标保持不变。
- 合并与移动使用严格的绝对路径校验和单引号 shell 转义；禁止根目录、父目录穿越、控制字符和首尾空白。
- 进度由各分片完成字节聚合，UI 更新节流到最多 10 Hz，并在上传弹层标明“分片并行 / 支持断点续传”。

### 7.3 跨远程传输

两个 SFTP 分栏或不同 Snake 窗口之间可以拖动远程文件或文件夹。

实现规则：

- Rust 为来源和目标分别获取 SFTP 连接。
- 使用固定 1 MiB 有界内存缓冲流式读取和写入。
- 禁止创建本地临时文件。
- 文件夹按队列展开为目录创建和文件复制任务。
- 目标端已完成部分允许基于文件大小和偏移继续，但恢复前必须重新验证来源大小和修改时间。

### 7.4 冲突策略

- `ask`：逐项询问。
- `overwrite`：覆盖目标。
- `skip`：跳过冲突项。
- `rename`：生成 `name copy N.ext`。

冲突对话框支持“应用到当前批次”。未经用户选择不得默认覆盖。

### 7.5 队列状态机

```text
draft -> scanning -> queued -> running
                           ├-> paused -> queued
                           ├-> succeeded
                           ├-> failed -> queued (retry)
                           ├-> cancelled
                           └-> interrupted -> queued (manual retry)
```

- 全局并发数：3
- 单主机并发数：2
- UI 进度更新频率：最多 10 Hz
- 进度字段：总字节、完成字节、速度、剩余时间、当前文件、总项数和完成项数
- 暂停在当前读写块完成后生效
- 取消后关闭句柄；是否删除不完整目标文件由任务策略决定并记录事件
- 应用异常退出后将 `scanning`、`queued`、`running` 转为 `interrupted`，不自动继续
- 主窗口不显示常驻传输条。本地上传只在当前 SFTP 文件表状态行显示约 116pt 的迷你进度；成功保留 100% 两秒后收起为记录图标，失败与取消直接收起为带状态色的图标。
- 点击迷你进度或记录图标打开当前标签记录，展示文件名、远程路径、大小、开始时间、实时/最终耗时和结果；清除记录不影响活动任务，关闭标签或应用后记录清空。

## 8. 本地磁盘映射

### 8.1 依赖检测

需要检测：

- `/opt/homebrew/bin/sshfs`
- `/usr/local/bin/sshfs`
- `/Library/Filesystems/macfuse.fs`

缺少依赖时显示当前检测结果、安装说明和“重新检测”按钮。Snake 不自动下载、安装或提权。

### 8.2 路径模型

```text
远程目录
   ↓ SSHFS
/Users/Shared/.SnakeMounts/<SHA256(mappingID)>
   ↓ 符号链接
用户选择的本地访问目录
```

实际挂载路径由 Snake 管理。用户路径只作为软链接入口，避免直接在任意用户目录上执行 FUSE 挂载。

### 8.3 SnakeMountHelper

helper 必须随应用签名，并执行严格校验：

- 只允许预设 sshfs 可执行文件路径。
- 真实挂载目标必须位于 `/Users/Shared/.SnakeMounts/`。
- 禁止调用任意 shell。
- 参数使用结构化数组传给 `Process`，不得拼接命令字符串。
- 密码从标准输入接收。
- helper 创建权限仅限当前用户的一次性 FIFO，供 `SSH_ASKPASS` 读取一次后删除。
- 密码不得出现在 argv、环境变量和日志中。

SSHFS 参数应包含严格主机密钥校验、Snake `known_hosts`、重连、ServerAlive、连接超时、macOS 权限兼容和受控缓存。

### 8.4 卸载与恢复

- 正常卸载优先调用 `diskutil unmount`。
- 失败时使用 `/usr/sbin/lsof` 查询占用进程并展示给用户。
- 只有用户明确确认后允许强制卸载。
- 检测由外部程序建立的挂载，显示为“外部挂载”，不得直接接管其凭据。
- 自动挂载启动时仅尝试一次；依赖、凭据或主机信任检查失败后保持可见失败状态，不无限重试。

自动挂载是配置行为，不代表恢复终端、SFTP 或窗口工作区。

## 9. 数据模型与持久化

数据库路径：

```text
~/Library/Application Support/Snake/snake.sqlite3
```

数据库启用：

- `PRAGMA foreign_keys = ON`
- WAL journal mode
- 版本化迁移
- 每次迁移事务化

### 9.1 主要数据表

#### `session_groups`

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | TEXT PK | UUID |
| `name` | TEXT | 分组名称 |
| `sort_order` | INTEGER | 排序 |
| `created_at` | INTEGER | 创建时间 |
| `updated_at` | INTEGER | 更新时间 |

#### `ssh_profiles`

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | TEXT PK | UUID |
| `group_id` | TEXT FK | 所属分组 |
| `name` | TEXT | 名称 |
| `host` | TEXT | 主机/IP |
| `port` | INTEGER | 端口 |
| `username` | TEXT | 用户名 |
| `auth_method` | TEXT | `password`/`private_key` |
| `keychain_account` | TEXT NULL | Keychain 引用 |
| `private_key_bookmark` | BLOB NULL | security-scoped bookmark |
| `tags_json` | TEXT | 标签数组 |
| `symbol_name` | TEXT | SF Symbol |
| `sort_order` | INTEGER | 排序 |
| `created_at` | INTEGER | 创建时间 |
| `updated_at` | INTEGER | 更新时间 |

#### `known_hosts`

保存 host、port、algorithm、fingerprint、公钥和首次确认时间。`host + port` 建立唯一约束。

#### `transfer_jobs`

保存来源/目标 profile ID、会话快照、来源/目标路径、文件类型、总量、完成量、速度、状态、冲突策略、错误码和时间戳。

#### `transfer_events`

保存任务状态变化和不含敏感数据的诊断事件。

#### `mount_mappings`

保存 profile ID、会话快照、远程路径、用户访问路径、实际挂载路径、自动挂载、启用状态和最后错误。

#### `settings`

保存主题、默认冲突策略、队列并发设置、侧栏行为和日志级别。

当前实现先通过 `UserDefaults` 保存分片阈值、分片并发数、终端字体和字号；引入 `settings` 表迁移时保持键值兼容，并将用户现有配置一次性迁移。

数据库不保存窗口、标签、终端、SFTP 当前路径或 Bonsplit 布局。

## 10. Swift 与 UniFFI 接口契约

### 10.1 Swift 工作区类型

```swift
struct WindowID: Hashable, Codable
struct WorkspaceTabID: Hashable, Codable

enum WorkspaceTabKind {
    case terminal(profileID: String)
    case sftp(profileID: String)
}

struct TabTransferPayload: Codable {
    let sourceWindowID: WindowID
    let tabID: WorkspaceTabID
    let transactionID: UUID
}
```

需要实现：

- `ApplicationStore`
- `WorkspaceWindowState`
- `WorkspaceTabRuntime`
- `TerminalSurfaceController`
- `WorkspaceWindowCoordinator`
- `GlobalTransferStore`
- `CredentialCoordinator`
- `MountCoordinator`

### 10.2 UniFFI 数据类型

- `SessionGroup`
- `SSHProfile`
- `AuthMethod`
- `AuthMaterial`
- `HostKeyChallenge`
- `HostKeyDecision`
- `ConnectionState`
- `TransferRequest`
- `TransferJob`
- `TransferState`
- `ConflictPolicy`
- `MountMapping`
- `MountState`
- `DependencyStatus`
- `SnakeError`

### 10.3 UniFFI 操作

```text
open_terminal(profile_id, auth_material, observer) -> TerminalHandle
open_sftp(profile_id, auth_material, observer) -> SftpHandle
respond_to_host_key(challenge_id, decision)

enqueue_transfer(request) -> TransferJob
pause_transfer(job_id)
resume_transfer(job_id)
cancel_transfer(job_id)
retry_transfer(job_id)

create_group(input)
update_group(id, input)
delete_group(id)

create_profile(input)
update_profile(id, input)
delete_profile(id)

create_mount_mapping(input)
update_mount_mapping(id, input)
delete_mount_mapping(id)
```

`open_terminal` 和 `open_sftp` 立即返回处于 connecting 状态的 handle。主机密钥挑战通过 observer 发出，UI 调用 `respond_to_host_key` 后继续或终止连接。

## 11. 错误处理与日志

错误至少分为：

- 配置校验错误
- Keychain 错误
- 私钥 bookmark 失效
- DNS/网络错误
- 连接超时
- 主机密钥首次确认或不匹配
- SSH 认证失败
- SFTP 权限或路径错误
- 本地文件读取错误
- 传输冲突、取消或中断
- macFUSE/SSHFS 缺失
- 挂载点占用或卸载失败
- SQLite/迁移错误

错误信息需要说明发生了什么和用户可以执行的下一步，不使用模糊的“操作失败”。

日志路径建议为：

```text
~/Library/Logs/Snake/snake.log
```

日志采用结构化字段，默认滚动保存 7 天，并对用户名、主机、路径和所有凭据进行分级脱敏。第一版不引入远程遥测。

## 12. 构建、签名与发布

- 最低部署版本：macOS 15.0。
- Swift 构建 arm64 和 x86_64。
- Rust 分别构建 `aarch64-apple-darwin` 与 `x86_64-apple-darwin`，再合并为 Universal 2。
- 开启 Hardened Runtime。
- 主应用、Rust 动态库和 `SnakeMountHelper` 全部签名。
- 使用 Developer ID Application 证书。
- 通过 App Store Connect API Key 提交 notarization。
- stapler 验证后生成并签名 DMG。
- 发布前执行 `codesign --verify`、`spctl --assess` 和公证票据检查。
- 不发布 Mac App Store 版本，不启用 App Sandbox。

## 13. 分阶段开发计划

### 阶段 0：基础工程

交付：

- SwiftPM、Cargo 和 UniFFI 工程。
- Rust/Swift 最小调用链。
- SQLite v1 迁移。
- 结构化日志和错误模型。
- Universal 2、签名、公证和 DMG 流程骨架。

退出条件：Swift 测试可以调用 Rust 核心，调试版与发布版均能启动且不包含未签名嵌入产物。

### 阶段 1：会话管理与终端

交付：

- 单层分组和会话 CRUD。
- 密码/私钥认证表单。
- Keychain 和 security-scoped bookmark。
- known hosts 和主机密钥确认。
- 会话上下文菜单和双击新终端。
- SwiftTerm、SSH PTY 和连接带。

退出条件：同一会话可同时打开多个终端，密码不会进入 SQLite、日志或参数。

### 阶段 2：Bonsplit 与多窗口工作区

交付：

- Bonsplit 标签、横纵分屏和跨分栏拖动。
- 最小 Bonsplit fork 和上游补丁记录。
- `WorkspaceWindowCoordinator`。
- 标签撕出、跨窗口移动、重新合并和边缘分屏。
- 多显示器窗口定位和两阶段失败回滚。

退出条件：终端跨窗口移动不会重连，滚动缓冲和选择状态保持；异常落点不会丢失标签。

### 阶段 3：SFTP 与传输队列

交付：

- SFTP 浏览、路径导航和文件操作。
- 通过系统文件选择器上传文件或文件夹。
- 远程文件缓存打开。
- 传输队列、进度、暂停、继续、取消和失败重试。
- 同窗口及跨窗口远程文件流式传输。

退出条件：跨远程传输不创建本地临时文件；关闭 SFTP 窗口后后台任务继续并可在其他窗口查看。

### 阶段 4：磁盘映射与发布

交付：

- macFUSE/SSHFS 依赖诊断。
- `SnakeMountHelper`。
- 受管挂载路径和用户软链接。
- 自动挂载、重连、外部挂载识别和安全卸载。
- 完整签名、公证和 DMG。

退出条件：凭据不出现在 argv、环境变量或日志；缺少依赖时不自动安装。

### 阶段 5：稳定性与正式验收

交付：

- 键盘操作、VoiceOver、焦点环和减少动态效果。
- 大目录、大文件、弱网和异常退出测试。
- 简体中文文案校对。
- 第三方许可清单和发布检查表。

退出条件：所有验收矩阵项目通过，不存在高优先级安全或数据丢失问题。

## 14. 测试计划

### 14.1 Rust 单元测试

- SQLite 首次迁移、连续升级和失败回滚。
- SSHProfile、路径和端口校验。
- known hosts 首次确认、匹配和不匹配。
- 传输状态机全部合法/非法转换。
- 文件续传和来源变化校验。
- 冲突策略和批次规则。
- 删除会话事务和历史快照保留。
- 调度器全局并发限制（单主机传输连接上限已在客户端落地）。

### 14.2 Swift 单元测试

- 模拟 Keychain 保存、读取、更新和删除。
- security-scoped bookmark 创建、失效和重新选择。
- 会话列表、编辑表单和上下文菜单 ViewModel。
- `WorkspaceWindowCoordinator` 窗口注册和命中测试。
- 两阶段标签移动成功、取消和失败回滚。
- 关闭窗口时活动终端确认。
- Rust observer 到 `@MainActor` 的状态映射。

### 14.3 集成测试

使用隔离 OpenSSH/SFTP 服务覆盖：

- 密码认证和私钥认证。
- 首次主机密钥和密钥变化。
- PTY 输入、输出、resize 和远端退出。
- 文件/文件夹上传、下载和续传。
- 网络中断和任务重试。
- 两台远程服务器之间的流式传输。
- 大目录列表和大文件传输。

挂载测试默认使用模拟 sshfs/helper。真实 macFUSE 冒烟测试只在受控签名 macOS 机器上执行。

### 14.4 UI 测试

- 会话右键打开终端、SFTP、修改和删除。
- 双击同一会话生成两个独立终端。
- 标签排序、横纵分屏和跨分栏移动。
- 终端/SFTP 标签撕出、拖回和跨窗口合并。
- 拖出最后一个标签和多显示器定位。
- Escape 取消和非法落点回滚。
- 文件选择器上传和远程文件跨面板/跨窗口拖动。
- 标签与远程文件 UTType 不互相误识别。
- 传输队列展开、暂停、继续、取消和重试。
- 会话删除后映射禁用、历史保留和凭据清理。

### 14.5 视觉与无障碍

- 1440×960
- 1280×800
- 最小 1024×700
- 单显示器和多显示器
- 浅色、深色和高对比度
- 键盘焦点和全键盘访问
- VoiceOver 标签和操作顺序
- `prefers-reduced-motion`
- 长中文、长主机名、IPv6、长路径和大文件数字

## 15. 需求追踪矩阵

| 需求 | 主要模块 | 阶段 | 关键验收 |
| --- | --- | --- | --- |
| 会话与分组管理 | SessionRepository、SwiftUI Sidebar | 1 | CRUD、拖动、右键、双击终端 |
| 密码/私钥认证 | CredentialCoordinator、snake_core | 1 | Keychain、bookmark、无明文落盘 |
| 终端标签与分屏 | SwiftTerm、Bonsplit | 1-2 | 多终端、resize、跨分栏 |
| Chrome 式标签撕出 | WorkspaceWindowCoordinator、Bonsplit fork | 2 | 撕出、拖回、跨窗口、连接保持 |
| SFTP 文件浏览 | SFTPRuntime、NSTableView | 3 | 导航、刷新、文件操作、打开 |
| 本地上传 | NSOpenPanel、TransferQueue | 3 | 点击选择、文件及文件夹、安全覆盖 |
| SFTP 互传 | Rust TransferQueue | 3 | 同窗/跨窗、内存流式、不落本地 |
| 传输进度 | GlobalTransferStore | 3 | 总进度、速度、暂停、取消、重试 |
| 磁盘映射 | MountCoordinator、SnakeMountHelper | 4 | 依赖检测、挂载、重连、安全卸载 |
| 安装发布 | Build Scripts、Signing | 4-5 | Universal 2、签名、公证、DMG |

## 16. 版权与第三方许可

Stacio 只能作为行为和架构参考：

- 不复制源码、注释、命名、文案、测试、截图或目录结构。
- Snake 根据本文档、上游公开文档和独立测试重新实现。
- 新建独立模型、API、错误码和测试数据。
- 发布前执行人工相似性检查。

Bonsplit fork 必须保留 MIT LICENSE 和版权声明。项目需要维护 `THIRD_PARTY_NOTICES.md`，登记 Bonsplit、SwiftTerm、libssh2、OpenSSL、UniFFI、SQLite 及其他发布产物包含的依赖。

## 17. 第一版不包含

- ProxyJump/跳板机。
- SSH 端口转发。
- 终端宏、脚本录制和命令广播。
- 上传自定义会话图片图标。
- 远程文件由外部应用修改后的实时同步回传。
- 启动后恢复窗口、终端、SFTP 标签和 Bonsplit 布局。
- 自动安装 macFUSE/SSHFS。
- Mac App Store 和 App Sandbox 版本。
- 云同步、账号系统和远程遥测。

## 18. 完成定义

Snake 第一版满足以下条件后才能进入正式发布：

- 需求追踪矩阵全部完成并有对应自动化或人工测试记录。
- 终端和 SFTP 标签可在分栏和窗口之间移动，连接及运行状态不丢失。
- SFTP 支持文件选择器上传、文件夹上传、跨远程互传和完整队列控制。
- 磁盘映射具备依赖诊断、安全凭据传递和占用提示。
- SQLite、日志、拖放载荷、argv 和环境变量中不存在明文秘密。
- 在规定窗口尺寸、深浅色、多显示器和辅助功能场景下可用。
- Universal 2 应用、动态库和 helper 全部签名并通过公证验证。
- 第三方许可完备，Stacio clean-room 要求通过人工审核。
