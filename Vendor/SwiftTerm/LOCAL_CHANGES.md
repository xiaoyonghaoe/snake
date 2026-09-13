# Snake 本地维护记录

上游与 MIT 许可见 `README.md`、`LICENSE` 及项目根目录 `THIRD_PARTY_NOTICES.md`。

## 2026-09-12：可选绘制高亮

- macOS `TerminalView.displayHighlights` 提供可选闭包：接收绘制行文本，返回 `TerminalDisplayHighlight`（UTF-16 范围、NSColor）。未配置时保持原行为，iOS/Linux 不受影响。
- 文本包含两侧最多 8 个字符的软换行上下文，可正确装饰最长 7 字符的完整关键词，避免将跨行的 `errorCount` 当作 `ERROR`。不跨显式换行匹配，不扫描整个历史缓冲。
- `TerminalDisplayHighlight.swift` 按实际 CharData 字符构建 UTF-16 范围与终端列的映射，跳过宽字符尾单元，支持代理对、中文与组合字符。只接受有效且完整覆盖字符的范围。
- 在 `AppleTerminalView.buildAttributedString` 合并显示前景色。CoreGraphics 和 Metal 共用此入口；装饰颜色参与 attributed-run 分批，避免串色。
- 显式 ANSI/True Color、选区、反色、隐藏字符优先；使用显示缓冲（包括 synchronized output）的备用屏幕标志禁用回调。
- 替换回调会标记整屏脏区域并进入原生刷新队列；输出变化扩展相邻行绘制失效范围，以更新软换行上下文与 Metal 持久行缓存。换色继续沿用上游 `installColors` 的缓存清理。
- 关键词规则与有界行匹配缓存位于 Snake，不进入终端解析器；无 ANSI 注入，不改 CharData、复制文本或 SSH 字节。
- 测试：本包 `DisplayHighlightTests`；应用 `TerminalHighlightTests` 覆盖实际关键词、颜色优先级及主题设置联动。

后续跟进上游时重点核对共用行构建入口、脏行队列及 Metal 行缓存；不以改写终端缓冲替代此绘制扩展。

## 2026-09-13：有界逻辑行高亮

- 替换此前两侧 8 字符窗口。回调文本现在是当前绘制行所属的完整软换行逻辑行，最多 4,096 个显示字符（含空白单元）；组合字符的 UTF-16 总长度额外限制为 16,384。超限不调用匹配器，避免长日志阻塞 UI。
- 按真实字符宽度遍历列，只为本次绘制行生成颜色映射；历史缓冲仅查询与该行相连的有界上下文。历史开头已被淘汰的残缺逻辑行保守跳过。
- 输出更新向同一逻辑行的可见前后行扩展失效范围，包括 Metal 持久行缓存。缩放重排、分批输出及超过长度上限都会正确刷新旧高亮。
- 无回调、备用显示缓冲、远端显式前景色和终端特殊属性的优先级保持不变。应用匹配规则与 512 项缓存仍在 Snake 层。
