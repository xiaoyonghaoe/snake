# SFTP 下载与传输完整性校验

## 使用方式

- 文件或文件夹右键“下载…”，支持 Command／Shift 多选。先选择本地保存目录，再开始任务；取消选择不传输。
- 文件夹保留顶层目录、隐藏文件、子目录和空文件夹。重复选择父目录与其子项只下载一次。
- 软链接保留原始链接目标，不跟随链接，下载后可能仍为悬空链接；特殊设备文件跳过。
- 文件和分片共享每批并发上限。设置沿用原参数：默认超过 50 MB 使用 4 个独立 SFTP 连接分片；小文件按并发数分批处理。
- 上传、下载共用原来的底部紧凑入口，点击查看当前标签记录。记录显示方向、两端路径、耗时、传输状态、校验状态；没有记录时不增加常驻栏。
- 重名先确认覆盖／跳过／取消，可应用到当前批次。目录合并不删除额外文件。失败、取消的下载可以重试；重试从新的源版本重新下载，不做跨启动自动续传。

## 校验规则

1. 探测远端 SHA-256：`sha256sum`、`shasum -a 256`、`openssl dgst -sha256`。
2. 不可用时探测 MD5：`md5sum`、`md5 -q`、`openssl dgst -md5`。
3. 上传和下载均以完成传输为优先。两种算法都不可用、服务器仅允许 SFTP、能力探测失败、摘要命令失败或摘要无法解析时，跳过校验并继续发布文件，记录显示“未校验”及原因。**不回读远端文件，不额外下载一份来计算校验值。**

本地用 CryptoKit 流式计算对应算法，缓冲约 1 MiB；MD5 仅用于检测意外损坏，不作为抵御恶意篡改的保证。

传输达到 100% 后进入校验阶段，通过后才标记“校验通过”；无法完成校验使用橙色“未校验”提示，不将任务标记为失败。如果双方已经算出的摘要明确不一致，仍视为文件可能损坏，不发布暂存文件、不覆盖旧文件。取消和实际读写错误不因可选校验策略被忽略。

源文件在扫描／传输／校验期间的大小和修改时间变化会导致失败。哈希比较保证本次传输内容一致，不保证文件之后不会被其他程序修改。目录和软链接分别记录创建结果与链接目标核对，不伪装为文件内容哈希校验。

## 实现与安全边界

- Rust 提供区间下载、远端元数据、受控命令摘要、暂存合并和发布接口；Swift 协调批次、并发、记录及本地摘要。现有 `LocalUploadCoordinator`／`SFTPUploadRecord` 名称为兼容现有调用保留，记录增加下载方向及独立校验状态。
- 下载使用打开的目录描述符逐层 `openat(O_NOFOLLOW)`，临时文件 `O_EXCL` 创建。Rust 克隆 Swift 持有的暂存描述符并使用 positional write；不同分片不共享 seek 偏移。发布使用同目录 `renameatx_np`，非覆盖模式使用 `RENAME_EXCL`。
- 因此已存在的本地软链接不能将写入导向下载目录外；失败／取消会删除本次受管下载临时文件，原目标不变，不删除用户目录。
- 普通上传仍沿用独立分片续传：合并到隐藏暂存文件 → 校验 → `mv` 发布。校验失败清除本次分片和暂存文件，重试不沿用损坏分片。
- 仅允许 SFTP 或校验能力探测失败时，不依赖 `cat`／`mv`：使用独立连接写入同一新建暂存文件的不相交范围，并通过 SFTP rename 发布。覆盖要求服务器支持原子重命名，否则失败而不先删除原目标。此兼容路径支持暂停／继续，失败重试重新上传，不复用隐藏分片。
- 校验命令只通过独立连接的 exec channel 执行，不向终端输入命令；路径采用 shell 单引号和 stdin 重定向，输出有界且摘要严格解析。远端命令等待可取消；暂停停止客户端后续推进，不承诺暂停服务器已启动的哈希进程。
- sshd 会使用账号的登录 Shell 解析 exec 命令；原先直接发送 POSIX 探测脚本会被 fish 拒绝。现在统一通过安全引用的 `/bin/sh -c` 执行探测、摘要、合并及发布命令，保持路径中的引号、反斜杠、美元符号和反引号为字面内容。不修改用户 Shell 配置；仍无法执行时按上述策略标记未校验。
- 记录仅在当前标签生命周期保留，不新增数据库表；现有跨远端复制及双击文件下载到缓存后打开的流程不变。关闭标签后无需交互的后台任务继续；后续需要冲突确认的任务取消，避免后台永久等待不可见弹窗。

## 验证与复现

```sh
cargo test --manifest-path Rust/snake_core/Cargo.toml
swift test --disable-sandbox --filter 'TransferIntegrityTests|SFTPDirectoryDestinationTests|UploadActivityTests'
docker build -t snake-transfer-test:local scripts/transfer-fixture
docker run --rm -d --name snake-transfer-fixture -p 127.0.0.1::22 snake-transfer-test:local
docker port snake-transfer-fixture 22
# 使用上条命令返回的本机端口：
SNAKE_TRANSFER_TEST_PORT=<端口> swift test --disable-sandbox --filter SFTPDownloadIntegrationTests
docker stop snake-transfer-fixture
```

测试账号及密码仅存在于本机隔离容器 fixture，禁止用于生产部署。容器不挂载宿主文件，不使用真实 SSH 配置、凭据或 Keychain，不改变已有服务。测试期间在临时本地目录创建源文件和数据库，结束后删除；容器使用 `--rm`，停止后销毁其中测试数据。

自动化覆盖：SHA-256／MD5／缺少工具／SFTP-only、fish／zsh 登录 Shell、探测输出异常、摘要命令失败、分片与大小边界、多文件和空目录、中文引号及 Shell 特殊字符路径、软链接、本地越界防护、覆盖保护、摘要不一致、暂停继续取消以及源文件变化。页面、Finder 和真实服务器 GUI 操作由用户验收；隔离接口测试不替代 GUI 验收。

## 本次验收结果（2026-09-13）

- Rust：20 项通过，包括通过本机 sh／bash／zsh／fish 执行探测和特殊字符引用。
- Swift 全量：125 项中 122 项通过、2 项环境条件跳过；原有 `MountOperationsTests.testQuitIsCancelledWhenMountIsBusyOrMountTableCannotBeRead` 因 `invalidMapping` 失败，未修改挂载逻辑。
- 最终传输／校验／Finder 解析／目录快照／进度专项：22 项全部通过，其中 3 项使用真实隔离 SSH 服务测试。
- 真实传输覆盖 SHA-256、仅 MD5、无工具、SFTP-only、fish、zsh、探测异常、摘要命令失败八类账号的目录上传与下载；后四类中的 Shell 正常账号校验通过、故障账号完成传输并标记未校验。验证软链接、分片、暂停继续取消，以及人为错误摘要下两端旧文件不被覆盖。
- 调试包：`.build/download-integrity-app/Snake.app`。已重新生成 UniFFI 绑定、构建并通过 `codesign --verify --deep --strict`；签名为现有临时签名，不是 Developer ID 公证发行包。
- 未启动应用执行页面测试。隔离容器测试完成后停止并自动删除；保留 `snake-transfer-test:local` 镜像用于复现。
