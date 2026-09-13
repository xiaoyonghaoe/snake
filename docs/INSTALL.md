# 安装 Snake

1. 打开下载的 DMG，将 **Snake.app 拖到 Applications（应用程序）**。
2. 等待复制结束，推出磁盘映像，再从“应用程序”打开 Snake。
3. 更新旧版本前请退出 Snake，复制时选择替换。安装包不包含用户会话或凭据，也不会清除已有配置；更新前可自行备份配置。

## 系统要求

macOS 15 或更高版本。`macos-arm64` 安装包只适用于 Apple Silicon（M 系列）Mac，不适用于 Intel Mac。
磁盘映射的 macFUSE / sshfs 为可选外部依赖，本安装包不自动安装、不提权。

## 当前分发包的签名限制

本次 1.1.0 安装包仅有本地 ad-hoc 签名，没有 Developer ID 签名和 Apple 公证，不属于免安全警告的正式公证包。
只有确认下载来源可信且校验值一致后才打开。如果系统提示无法验证开发者，可按
[Apple 官方说明](https://support.apple.com/zh-cn/102445)，在尝试打开后进入“系统设置 → 隐私与安全性 → 仍要打开”。
不要关闭系统 Gatekeeper。正式公证包发布后应优先使用公证包。

## 校验下载

将 `.dmg` 和同名 `.dmg.sha256` 放在同一个目录，进入该目录执行：

```sh
shasum -a 256 -c Snake-1.1.0-macos-arm64.dmg.sha256
```

输出 `OK` 表示与发布的校验值一致；校验和不替代可信来源和开发者签名。
