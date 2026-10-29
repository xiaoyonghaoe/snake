**简体中文** · [English](en/RELEASING.md)

# DMG 发布流程

## 构建

需要 macOS、Xcode 命令行工具、Swift 6、Rust 和 Python 3；先准备项目依赖。
脚本只构建当前宿主架构，不将 arm64 冒充 Universal 2。

```sh
zsh scripts/package-release-dmg.sh 1.3.0
```

输出在 `release/`（Git 忽略）：DMG 及 SHA-256 文件。已存在同名产物时拒绝覆盖。
应用使用 Release 优化构建；Rust、helper、终端 Metal 资源包和第三方许可证随包携带。
打包时会验证资源包定位，并在 GPU 可用时实际编译 Metal 着色器；不启动 Snake。
分发内容使用白名单复制，不包含会话数据库、密码、私钥、测试夹具或本机配置。
`.build/release-stage.*` 保留组装后的应用用于排查，确认无用后再手动清理。

版本以 `Resources/Info.plist` 为准，脚本参数可覆盖安装包内营销版本；正式更新时同步修改该文件。
构建号默认读取 plist，可用 `SNAKE_BUILD_NUMBER` 覆盖。
Cargo 许可证清单按锁文件和目标架构生成，包含 normal/build 依赖，不包含 dev 依赖。

## 当前 1.3.0

- Apple Silicon / macOS 15+；本地 ad-hoc 签名，不是 Apple 公证包。
- 不包含 Intel 或 Universal 2 产物。
- 图形页面、真实安装后的 SSH/SFTP 和升级凭据访问由用户验收。
- 本脚本不创建 Git 标签、不推送代码、不发布 GitHub Release。

## 正式 Developer ID 发布门槛

本机当前没有有效 Developer ID Application 证书。拥有证书后可使用
`SNAKE_SIGNING_IDENTITY='Developer ID Application: …'` 构建，脚本为代码启用 Hardened Runtime。
还需使用自己的 notarytool 钥匙串 profile 完成公证；不要将 Apple 账号、密码、证书或私钥写入仓库。
更换签名可能影响原测试包的钥匙串访问批准，发布前必须回归已保存凭据连接。

```sh
xcrun notarytool submit release/Snake-1.3.0-macos-arm64.dmg --keychain-profile <你的公证配置名> --wait
xcrun stapler staple release/Snake-1.3.0-macos-arm64.dmg
xcrun stapler validate release/Snake-1.3.0-macos-arm64.dmg
```

只有公证结果为 Accepted 后才装订票据。装订会改变文件，必须重新生成 SHA-256，不能沿用旧值。
在干净 Mac 上下载实际发布地址的文件，验证 Gatekeeper、拖入 Applications、启动、升级和卸载。
Apple 安全机制参见 [官方说明](https://support.apple.com/zh-cn/102445)。

## 发布附件

上传 DMG、同名 SHA-256 和版本说明；在发布页注明架构、最低系统版本与是否公证。
公开版本前先提交对应源码并确认构建和源码一致，再由维护者创建标签及 Release。

## 本次构建验证记录（1.3.0 / 1300，2026-10-29）

- Release 构建成功；应用、Helper 和 Rust dylib 均为 arm64，版本 `1.3.0` / `1300`。
- DMG 10,455,647 字节；SHA-256：`10a9a0c80e2ab92db634612f2c586a349d9cad7927a359e27e1bc146dcb54de3`。
- `hdiutil verify`、SHA-256 与只读挂载后的 `codesign --verify --deep --strict` 通过；Applications 链接为 `/Applications`，中英文安装说明均为 1.3.0。
- 实际挂载应用通过资源定位与 7 个 Metal shader 编译检查，英文 700 条、中文源语言齐备；未启动应用进行页面验收。
- Swift 233 项中 227 通过、5 跳过、1 项既有挂载 `invalidMapping` 失败；新增 SSHFS 密码通道测试 7 项通过。Rust 32 项单元测试通过；3 项本机隔离 SSH/SFTP 回归需一次性 sshd，本轮未运行。DispatchWorkItem Sendable 与未使用变量编译警告保留。
- 发布内容见 [1.3.0 版本说明](RELEASE_NOTES_1.3.0.md)。本包 ad-hoc、未公证；GUI、真实身份验证和干净 Mac 安装/升级由用户验收。

## 历史构建验证记录（1.2.0 / 1200，2026-10-25）

- Release 构建成功；应用、Helper 和 Rust dylib 均为 arm64，版本 `1.2.0` / `1200`。
- DMG 10,580,322 字节；SHA-256：`bd45e81c11545bb47e286ff920cca283d9a1224e18668d08fb252bb0251f789b`。
- `hdiutil verify`、SHA-256 与只读挂载后的 `codesign --verify --deep --strict` 通过；Applications 链接为 `/Applications`，中英文安装说明均为 1.2.0。
- 实际挂载应用通过资源定位与 7 个 Metal shader 编译检查，英文 699 条、中文源语言齐备；未启动应用进行页面验收。
- Rust 32 项单元测试及 3 项本机隔离 SSH/SFTP 回归通过。Swift 226 项中 220 通过、5 跳过、1 项既有挂载 `invalidMapping` 失败；DispatchWorkItem Sendable 与未使用变量编译警告保留。
- 发布内容见 [1.2.0 版本说明](RELEASE_NOTES_1.2.0.md)。本包 ad-hoc、未公证；GUI、真实身份验证和干净 Mac 安装/升级由用户验收。
- 发布标签应绑定合并后的 main 提交，并上传本次已验证的 DMG、同名 SHA-256 与版本说明；文档或索引提交不得改变构建源码。不要覆盖旧版本附件。

## 历史构建验证记录（1.1.3 / 1130）

- Release 构建成功，应用、Helper 和 Rust dylib 均为 arm64；版本为 `1.1.3` / `1130`。
- DMG 8,693,334 字节；SHA-256：`a0f317358c222df7dbbbe903ee485cd8c006e927c59a17309458810a76c44a51`。
- `hdiutil verify`、SHA-256 校验及只读挂载后的 `codesign --verify --deep --strict` 通过；Applications 链接为 `/Applications`。
- 挂载包可定位全部资源，7 个 Metal shader 函数编译通过，英文 601 条语言资源与中文源语言齐备；未启动应用。
- Swift 197 项：5 项外部夹具跳过、1 项既有挂载 `invalidMapping` 失败；快捷键/工作区 25 项通过。Rust 22 项通过。
- 页面、真实系统身份验证、干净 Mac 安装与升级由用户验收；未完成 Developer ID 签名与公证。

## 历史构建验证记录（1.1.2 / 1120）

- Release 构建成功；应用、helper 和 Rust dylib 均为 arm64。
- `hdiutil verify` 通过；`shasum -a 256 -c` 校验通过。DMG 为 8,461,084 字节，
  SHA-256 `acd27ec8f8e93559c3753fe1cb9c4074b62e6dc19a89ac10520aab91dcb2f65b`。
- 只读挂载 DMG，确认卷名为 `Snake 1.1.2`、`Applications` 链接指向 `/Applications`，且包内
  `安装说明.md` / `Installation Guide.md` 的版本与本次一致；将应用复制到独立临时目录后，
  `codesign --verify --deep --strict` 通过。
- 独立副本可定位应用内部资源包；7 个 Metal shader 函数实际编译通过，没有启动应用。
- 随包语言资源完整：`zh-Hans` 为源语言，`en` 共 558 条；两种语言的 `InfoPlist.strings` 齐备。
- 动态链接检查仅包含随包 Rust dylib 和 Apple 系统框架／库，无 Homebrew 或工作目录动态库路径。
- 包内 `CFBundleShortVersionString` / `CFBundleVersion` 为 `1.1.2` / `1120`。
- 全量 `swift test --disable-sandbox`：187 项，1 项既有失败（挂载 `invalidMapping`），5 项因缺少
  外部夹具跳过；启用 Docker 传输夹具后其中 3 项通过。`LocalizationTests` 10 项通过。
- 同名产物保护已验证，重复执行打包不会覆盖已有 DMG。
