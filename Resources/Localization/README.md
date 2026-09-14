# 本地化维护说明 / Localization maintenance

Snake 的界面语言由 `Resources/Localization/` 下的 `.lproj` 目录提供，打包时整目录复制到
`Snake.app/Contents/Resources/`，因此 `Bundle.main`（SwiftUI 的 `LocalizedStringKey`
与 `L10n` 都走它）可以直接解析。

## 目录约定

```
Resources/Localization/
  zh-Hans.lproj/Localizable.strings   # 源语言表：故意留空，缺失的 key 回退为中文原文
  zh-Hans.lproj/InfoPlist.strings
  en.lproj/Localizable.strings        # 全部 key 的英文
  en.lproj/InfoPlist.strings
```

## key 约定

- key 就是**简体中文原文**。纯字面量交给 `Text("…")`、`Button("…")`、`Label(…)`、`Section(…)`、
  `.help(…)`、`.accessibilityLabel(…)` 等 `LocalizedStringKey` 参数时，SwiftUI 会自动查表，无需改动代码。
- 含插值、三元表达式、返回 `String` 的计算属性，以及 `String` 类型参数（`NSAlert.messageText`、
  `NSMenuItem.title`、`panel.prompt` 等）必须使用 `L10n.text("…")`；含插值的用
  `L10n.format("…%@…", value)`，把每个 `\(value)` 改成 `%@`。
- 需要英文单复数的字符串用 `L10n.plural("…%@…", count: n, args…)`。表中同时保留
  `"<key>"`（单数）与 `"<key>#plural"`（复数）两条；缺少 `#plural` 的语言会回退到单数。

## 新增一种语言

1. `cp -R Resources/Localization/en.lproj Resources/Localization/<language>.lproj`，翻译
   `Localizable.strings`（保留每个 `%@` 占位符、`#plural` 条目与转义序列）和 `InfoPlist.strings`。
2. 在 `Resources/Info.plist` 的 `CFBundleLocalizations` 与 `AppLanguage.supportedIdentifiers`
   中加入该语言标识。回退语言由 `AppLanguage.fallbackIdentifier` 决定。
3. `swift test --disable-sandbox --filter LocalizationTests` 校验完整性；测试会报告缺失或多余的 key。

## 验证方式

- `swift run Snake` 不是打包后的 `.app`，`Bundle.main` 找不到 `.lproj`，界面保持简体中文；
  验证其他语言请使用 `scripts/package-debug-app.sh` 生成并打开 `Snake.app`。
- `scripts/verify-release-resources.swift` 会在打包时校验每种语言的 `Localizable.strings`
  与 `InfoPlist.strings` 是否存在且可解析。

## 翻译用语

| 中文 | English |
| --- | --- |
| SSH 会话 | SSH session |
| 磁盘映射 / 映射 | mount / mount mapping |
| 连接带 | connection belt |
| 终端 | terminal |
| 凭据 | credential |
| 主机密钥 / 指纹 | host key / fingerprint |
| 受管挂载点 | managed mount point |
| 本地访问目录 / Finder 入口 | local access folder / Finder entry |
| 校验 / 未校验 | verification / unverified |
| 暂存文件 | staging file |
| 并行传输 / 分片 | multipart transfer / shard |
| 私钥 / 口令 | private key / passphrase |
| 软链接 | symbolic link |
| 递归 | recursively |
| 会话头像 | session avatar |
| 外观 / 浅色 / 深色 | Appearance / Light / Dark |
| 跟随系统 | Follow System |
| 快捷键 / 键帽 | shortcut / key cap |
