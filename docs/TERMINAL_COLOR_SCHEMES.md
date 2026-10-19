**简体中文** · [English](en/TERMINAL_COLOR_SCHEMES.md)

# 终端配色与导入

新增独立的「纯白」主题：在“设置 → 终端 → 配色主题”选择后，终端始终使用 `#FFFFFF` 白底、`#1F2328` 深色正文、蓝色光标和淡蓝选区，即使应用切换到深色外观也不变。ANSI、日志及字段高亮均使用适合白底的深色版本；新主题不改变默认选择。

设置 → 终端可选择 Ghostty 清晰、纯白、经典、鲜明、Tokyo Night、Catppuccin Latte/Mocha、Gruvbox Light/Dark、Solarized Light/Dark。新安装默认 Ghostty 清晰；第一次升级将原 Tokyo Night 选择迁入 Ghostty 清晰，其他内置或已导入主题保持选择。迁移只执行一次，之后手动选回 Tokyo Night 也会保留。除纯白固定白底外，其他内置主题随应用浅深外观切换，浅色版本的背景统一为 Snake 适配的白色。只更换 SwiftTerm 现有视图的调色板，不断开 SSH，也不清空终端缓冲。

Ghostty 清晰参考 [Ghostty 默认配置](https://github.com/ghostty-org/ghostty/blob/a2e440396403385680008e456a741a7776091412/src/config/Config.zig)和 [ANSI 色板](https://github.com/ghostty-org/ghostty/blob/a2e440396403385680008e456a741a7776091412/src/terminal/color.zig)：深色使用 `#282C34` 灰黑背景与 `#FFFFFF` 正文，避免蓝紫色正文偏灰；提亮 ANSI 暗灰、红色及亮色，除作为基础表面的 ANSI 黑色外，命名颜色对背景至少达到 4.5:1。正文与背景至少 10:1，正文与选区、光标内文字至少 7:1。设置预览增加灰色注释示例。该方案为 Snake 可读性适配，不代表 Ghostty 原样主题或渲染器；不改变远端 256 色、True Color 和弱化文字属性。

可导入 `.itermcolors`：文件由系统属性列表解析器读取，要求前景、背景及 ANSI 0–15 色；光标和选区缺失时使用明确的默认值。文件上限 1 MB。单套配色在两种应用外观中都保持原色；同一文件含 Light/Dark 两套时随外观切换。解析后保存在 `~/Library/Application Support/Snake/TerminalThemes/`，可在设置里删除。已选导入主题丢失或删除时回退 Ghostty 清晰并提示。

预览中的彩色文件列表仅是示例。Snake 不再向远端注入 `ls/ll` 别名、`LS_COLORS`、`CLICOLOR` 或颜色提示；远端自己输出的 ANSI/True Color 正常显示。OSC 7 当前目录 Shell Hook 保持不变，本地日志和字段高亮仍只影响绘制，不修改 SSH 数据或复制内容。

ANSI/SGR 和 OSC 颜色序列规定终端显示行为，并非统一的主题文件协议。Base16/Base24 是跨应用色板约定；本版只导入 `.itermcolors`，不读取其他主题格式。内置调色板的固定上游版本、MIT 许可和白底改动见 `Vendor/TerminalThemes/`；Tokyo Night 来源见 `Vendor/TokyoNight/`。
