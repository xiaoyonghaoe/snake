**简体中文** · [English](en/TOKYO_NIGHT_COLORS.md)

# Tokyo Night 与终端颜色提示

## 外观与设置

仅终端表面和预览采用 Tokyo Night：浅色 Day 的背景及光标内文字调整为纯白 `#FFFFFF`，深色 Night 不变；标题栏、SFTP、会话卡片不变。固定色值、来源提交和许可证位于 `Vendor/TokyoNight`，上游原始文件保留不动。原始 ANSI 16 色不改；本地语义强调色按背景调整至至少 4.5:1，保证 Day 上的可读性。

第一次升级通过 `com.snake.terminal.tokyo-migration-v1` 一次性选中 Tokyo Night，之后恢复用户选择；经典、鲜明仍可选。新增 `com.snake.terminal.field-highlight` 与 `com.snake.terminal.shell-colors` 开关，默认开启。日志开关独立保留。

主题、字体、日志及字段高亮即时应用原终端视图，不重建 SSH；彩色 ls／ll 开关在连接开始时取快照，下次连接生效，不向正在使用的 Vim／top 注入命令。

## 两层颜色

1. 远端文件类型：Shell 初始化检测 GNU／BSD ls，配置 ANSI 基础色规则。目录蓝、软链接青、可执行文件与源码绿、压缩包紫、配置文件橙黄。普通文件保持默认色。BSD 仅支持其原生文件类型分类，不提供 GNU 扩展名规则。
2. 本地字段：权限青、日期时间蓝灰、地址蓝、路径青、大小／百分比橙，成功／运行绿、失败红、停止／警告橙。保留原日志级别规则，默认不高亮裸数字或相对路径。

本地规则仅修改显示属性，不改终端缓冲、复制文本或远端字节。ANSI／True Color、选区、反色和隐藏属性优先；备用屏幕停用。普通屏幕的命令回显可能命中，不进行完整 Shell 输入语法分析。

匹配顺序：错误与警告、路径／地址／日期时间、权限／大小／状态，最后普通日志级别；范围不重复覆盖。语义高亮与原日志开关分别控制。IP 经系统地址解析验证。

## Shell 初始化边界

- 支持 bash、zsh、fish，跟随已有 OSC 7 初始化顺序，每个连接一次。没有远端文件写入、软件安装、永久 alias 或配置修改，也不依赖 SSH AcceptEnv。
- 使用换行分隔的函数定义，避免超过远端 TTY 单行长度限制；函数完整定义后调用，再清理辅助函数。
- GNU 通过 `--version` 和彩色选项能力检测，使用 `--color=auto`；BSD 使用 `-G` 和 CLICOLOR。不设置 FORCE_COLOR，不给管道强制着色。
- 已有 LS_COLORS 条目原样保留，仅补缺失键；已有 LSCOLORS 保留。非空 NO_COLOR 时跳过全部颜色设置，不调整 SYSTEMD_PAGERSECURE 等无关变量。
- 缺失 ll 时创建长列表别名。已有直接 ls 简单别名只允许文字选项，保留参数并补色；重复初始化不重复添加尾部颜色选项。
- 复杂函数、复杂别名、明确禁色、已有独立 ll 命令保留，并输出简短非阻塞说明。Fish 只处理可确认由 alias 生成、主体为直接 ls 参数加 argv 的函数，不任意重写函数。
- 不支持的 Shell／ls 及初始化失败不改变连接状态或触发重连。不保证用户复杂 ll 函数能自动获得颜色；这是保留服务器自定义行为的明确边界。
- 初始化定义可能显示在远端交互式 Shell 回显／命令历史中，不包含凭据；“不写配置文件”不等于禁用 Shell 自身的历史机制。

## 验证

```sh
swift test --disable-sandbox
GITHUB_ACTIONS=true swift test --disable-sandbox --package-path Vendor/SwiftTerm
docker build -f scripts/terminal-color-test.Dockerfile -t snake-terminal-color-test:local scripts
SNAKE_SHELL_COLOR_DOCKER_IMAGE=snake-terminal-color-test:local swift test --disable-sandbox --filter TerminalShellColorTests
```

Shell 测试通过伪终端运行，使用临时 HOME、目录／链接／可执行文件 fixture，检查别名、NO_COLOR、用户颜色和管道输出。本机覆盖 BSD ls，Docker 以只读挂载、无网络的临时容器覆盖 GNU ls；不启动 SSH 服务、不访问用户服务器或真实凭据。这些测试验证初始化脚本在实际 Shell 中的行为，不等同真实 SSH GUI 验收。

应用测试覆盖上游色值一致性、迁移一次性、语义匹配正反例、独立开关、Unicode、长路径软换行、缓冲不变和超限跳过；沿用视图身份、选区、ANSI／True Color、备用屏幕与性能测试。

既有 `MountOperationsTests.testQuitIsCancelledWhenMountIsBusyOrMountTableCannotBeRead` 的 invalidMapping 失败仍单独记录，不修改挂载逻辑。页面由用户验收：新开连接后 ls／ll，主题浅深色、长日志、Vim／top、选择复制及多分屏。

## 本轮记录（2026-09-13）

- 应用最终全量测试：114 项，111 通过、2 个既有集成测试按条件跳过、1 个上述挂载测试失败。Shell 专项 7 项在本机 BSD 与 Docker GNU 环境分别通过；主题与输出专项 16 项全部通过。
- SwiftTerm：41 项 XCTest、376 项 Swift Testing 全部通过。
- 性能回归：开启 Tokyo Night 与字段高亮，5,000 行日志加十轮可见行重绘，本机约 0.18 秒；非 GUI 帧率指标。
- 测试创建了 `snake-terminal-color-test:local` Docker 镜像以便复现；每个测试容器使用 `--rm` 自动退出删除，不启动常驻服务，不修改已有容器。
- 调试包：`.build/tokyo-night-app/Snake.app`，临时签名的 `codesign --verify --deep --strict` 检查通过；Tokyo Night 来源文件与许可证已附带在应用资源目录。未执行 GUI、Touch ID 或真实服务器操作。
