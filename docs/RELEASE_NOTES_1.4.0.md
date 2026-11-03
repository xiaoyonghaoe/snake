# Snake 1.4.0

发布日期：2026-11-03 · 构建号：1400

## 更新

- SSH 会话页去掉标签，改用文件夹管理：每一层分「文件夹」和「会话」两段，顶部路径可点击返回任一层；搜索覆盖当前文件夹的所有下级。首次启动时，旧标签按每个会话的第一个标签迁移为顶层文件夹，会话原有标签数据保留不删。
- 文件夹可以嵌套，任意一层都能新建子文件夹。单击选中、双击打开；编辑弹窗可改名并上传、裁剪自定义图标。删除文件夹时，里面的会话和子文件夹移到上一层。
- 按住卡片拖动即可整理：同类卡片上停留片刻后其余卡片带动画让位，松手完成排序；拖到文件夹中部移入；在文件夹内拖动时，可放到顶部路径的任一层，或放到搜索框位置出现的「移到上一层」区域移出。单击不会误移；卡片右键菜单也可「移到文件夹」。
- 会话卡片不再触发窗口或工作区拖动；右上角工具栏按钮扩大点击范围并增加悬停反馈。
- 修复终端拖选文字时字符左右轻微抖动：Metal 渲染改为按单元格网格放置字形、下划线和删除线。

## 安装与安全边界

- Apple Silicon（arm64），macOS 15+；打开 DMG，将 Snake.app 拖到 Applications。更新前退出旧版，复制时选择替换。
- **仅 ad-hoc 签名，未使用 Developer ID，未通过 Apple 公证。** 首次打开可能被系统阻止；按安装说明处理，不关闭 Gatekeeper。
- 会话数据库升级到 schema v4（`session_groups` 新增 `parent_id`），旧库首次打开时自动迁移。
- MCP 默认关闭，只监听 `127.0.0.1`；Token 赋予绑定 SSH 账号的命令权限，不是只读沙箱。
- Intel / Universal 2、公证及跨应用重启工作区恢复仍未交付。

## 本次验证

- Swift：242 项，236 通过、5 项外部夹具跳过；既有 `MountOperationsTests.testQuitIsCancelledWhenMountIsBusyOrMountTableCannotBeRead` 仍因 `invalidMapping` 失败，不能宣称全量通过。新增文件夹迁移、命名、搜索、嵌套移动/删除/持久化、拖动激活及 Metal 字形网格定位测试均通过。
- Rust：33 项单元测试通过，新增嵌套文件夹与旧库补列迁移测试；3 项 SFTP 回归需要一次性本机 sshd，本轮未运行（本次 Rust 改动只涉及会话分组表）。
- Release 构建、镜像校验、SHA-256、只读挂载后的签名/架构/资源/版本检查通过；应用、Helper 与 Rust dylib 均为 arm64，7 个 Metal shader 和 721 条英文字符串资源通过验证。
- 拖动手感与动画、旧标签迁移的真实数据、GUI 及干净 Mac 安装/升级由用户验收，本轮不替代这些人工测试。

## 附件

- `Snake-1.4.0-macos-arm64.dmg`：10,825,593 字节。
- SHA-256：`a9ce170061f6d68b3464da16eeb7c5277f552c0c49f282dc5fd9bbd5129c20f3`。
- 将 DMG 与 `.dmg.sha256` 放在同一目录，运行 `shasum -a 256 -c Snake-1.4.0-macos-arm64.dmg.sha256`。

## English

Snake 1.4.0 replaces SSH session tags with folders. Each level lists Folders and Sessions, with a clickable path back to any level, and search covers every descendant. On first launch, each session's first tag becomes a top-level folder; the original tag data is kept. Folders nest to any depth: click to select, double-click to open, and edit a folder to rename it or give it a cropped custom icon. Deleting a folder moves its contents up one level.

Press and drag a card to organize: pausing over a card of the same kind slides the others aside, and releasing reorders; dropping on the middle of a folder moves the item in; inside a folder, dropping on any level of the path, or on the "move up" zone that replaces the search field while dragging, moves it out. A plain click never moves anything, and the card menu still offers Move to Folder. Session cards no longer start window or workspace drags, the top-right toolbar buttons have larger hit areas, and the Metal renderer now places glyphs on the cell grid, so text no longer shifts sideways during drag-selection.

Apple Silicon / macOS 15+, build 1400, **ad-hoc signed and not notarized**. The session database migrates to schema v4 on first open. Swift: 236 passed, 5 skipped and 1 pre-existing mount `invalidMapping` failure (242 total). Rust: 33 unit tests passed; the 3 isolated SFTP regressions were not run. Drag feel, real tag migration, GUI and clean-Mac installation/upgrade are manual acceptance tasks. DMG and SHA-256 metadata above refer to the same verified artifact.
