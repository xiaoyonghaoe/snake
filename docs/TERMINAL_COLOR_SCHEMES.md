# 终端配色与导入

设置 → 终端可选择经典、鲜明、Tokyo Night、Catppuccin Latte/Mocha、Gruvbox Light/Dark、Solarized Light/Dark。已有选择保留；新安装默认 Tokyo Night。内置主题随应用浅深外观切换，浅色版本的背景统一为 Snake 适配的白色。只更换 SwiftTerm 现有视图的调色板，不断开 SSH，也不清空终端缓冲。

可导入 `.itermcolors`：文件由系统属性列表解析器读取，要求前景、背景及 ANSI 0–15 色；光标和选区缺失时使用明确的默认值。文件上限 1 MB。单套配色在两种应用外观中都保持原色；同一文件含 Light/Dark 两套时随外观切换。解析后保存在 `~/Library/Application Support/Snake/TerminalThemes/`，可在设置里删除。已选导入主题丢失或删除时回退 Tokyo Night 并提示。

预览中的彩色文件列表仅是示例。Snake 不再向远端注入 `ls/ll` 别名、`LS_COLORS`、`CLICOLOR` 或颜色提示；远端自己输出的 ANSI/True Color 正常显示。OSC 7 当前目录 Shell Hook 保持不变，本地日志和字段高亮仍只影响绘制，不修改 SSH 数据或复制内容。

ANSI/SGR 和 OSC 颜色序列规定终端显示行为，并非统一的主题文件协议。Base16/Base24 是跨应用色板约定；本版只导入 `.itermcolors`，不读取其他主题格式。内置调色板的固定上游版本、MIT 许可和白底改动见 `Vendor/TerminalThemes/`；Tokyo Night 来源见 `Vendor/TokyoNight/`。
