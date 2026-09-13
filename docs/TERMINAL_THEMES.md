# 终端主题与日志关键词高亮

> 本文记录首版实现。2026-09-13 已扩展 Tokyo Night、输出字段与远端文件类型颜色；当前设置、默认值和边界以 [Tokyo Night 与终端颜色提示](TOKYO_NIGHT_COLORS.md) 为准。

## 使用

在「设置 → 终端」选择「经典／鲜明」、日志关键词高亮和字体字号。默认鲜明、高亮开启；配色随应用浅深色变化，不增加跟随系统模式。UserDefaults 保存主题与开关，已有窗口即时同步。

经典完整保留原 ANSI 16 色。鲜明以白底深色文字、深底清晰文字为基础，拉开蓝、青、紫、绿的差异。设置预览使用相同调色板和关键词规则，展示目录、普通文字及七种级别；大字号时可以滚动。

| 级别（忽略大小写） | 颜色 |
| --- | --- |
| ERROR、FATAL | 红 |
| WARN、WARNING | 橙 |
| INFO | 蓝 |
| DEBUG、TRACE | 紫 |

仅匹配完整关键词，支持 `[ERROR]`、`level=warn`，不匹配 `errorCount`、`information` 或 Unicode 字母／数字／组合符／下划线相连的片段。正文不着色。普通屏幕的命令回显也可能命中规则；不进行远程 Shell 语法高亮。

## 实现

- `TerminalTheme` = 预设 + 浅深色 + 高亮开关。`TerminalRuntime.applyTheme` 的相等判断避免重复应用，仍使用原 `TerminalView`、SSH handle、屏幕缓冲、选区与滚动位置。
- `TerminalLogHighlighter` 使用固定规则版本，按完整待绘制文本缓存 UTF-16 范围及级别；每个终端最多缓存 512 行，FIFO 淘汰。更换主题／开关创建新规则实例；内容变化、分批到达、缩放和软换行上下文变化得到新缓存键，不扫描历史日志。
- SwiftTerm 的可选绘制回调先按字符宽度建立 UTF-16→列映射，再在 CoreGraphics／Metal 共用行构建中装饰颜色。两侧有限软换行上下文避免跨行单词误匹配。详见 `Vendor/SwiftTerm/LOCAL_CHANGES.md`。
- 仅默认前景色可被装饰；远端指定 ANSI／True Color、选择、反色、隐藏属性优先。备用屏幕（Vim、top 等）不调用匹配器。
- 设置变化触发整屏刷新和 Metal 脏行更新，已有输出立即重新绘制。字体、光标和选择色仍走原 SwiftTerm 接口。
- 复制内容、终端输入输出、SSH 协议不改变；不改 Rust API、数据库、远端配置，不添加依赖。

持久化键：`com.snake.terminal.theme`（classic/vivid）、`com.snake.terminal.log-highlight`（Bool）。未知预设回退鲜明，缺失开关默认开启，显式关闭会恢复。

## 自动化与验收

运行：

```sh
swift test --disable-sandbox
GITHUB_ACTIONS=true swift test --disable-sandbox --package-path Vendor/SwiftTerm
```

应用测试覆盖主题完整性、正文／关键词 4.5:1 对比度、设置保存、边界／大小写／Unicode、宽字符与组合字符、分批输出、软换行、远端颜色优先、选区、备用屏幕、缓冲／复制不变及视图身份保持。性能测试输入 5,000 行日志，重建十轮可见行，使用 15 秒宽松回归阈值。

已知独立失败：`MountOperationsTests.testQuitIsCancelledWhenMountIsBusyOrMountTableCannotBeRead`。测试创建的新映射未绑定有效 SSH 配置，`ApplicationStore.preparedMappings` 抛出 `invalidMapping`，未到达忙碌挂载的退出判断；本轮未修改该测试或挂载逻辑。真实挂载／Finder 上传集成测试按原条件跳过。

本轮结果：应用 100 项测试中 97 项通过、2 项跳过、上述 1 项失败；新增主题高亮 9 项全部通过。SwiftTerm 的 41 项 XCTest 与 376 项 Swift Testing 全部通过（其中新增绘制回调测试 3 项）。5,000 行日志加十轮可见行重绘，本机约 0.16 秒；此数字不是实际 GUI 帧率或 GPU 基准。

页面由用户验收，未代替执行：浅／深色、经典／鲜明切换、关闭高亮后旧输出恢复、彩色 ls、Vim、top、选择复制、滚动及多分屏。可在已连接终端运行无文件副作用示例：

```sh
printf '[ERROR] failed\nlevel=warn retry\nINFO ready\nDEBUG trace\nerrorCount information\n'
printf '\033[32mERROR remote green\033[0m\n'
```

第二条 ERROR 必须保持远端指定的绿色。验证时切换配色或开关不应重连、清空输出或跳回滚动底部。真实 GUI／GPU 展示仍需页面验收，自动化行构建测试不等同截图验收。
