[简体中文](../INSTALL.md) · **English**

# Installing Snake

1. Open the downloaded DMG and **drag Snake.app to Applications**.
2. Wait for the copy to finish, eject the disk image, then open Snake from Applications.
3. Before updating an older version, quit Snake and choose Replace when copying. The installer contains no user sessions or credentials and does not erase existing configuration; you may back up your configuration beforehand.

## System Requirements

macOS 15 or later. The `macos-arm64` installer is for Apple Silicon (M-series) Macs only and does not work on Intel Macs.
The macFUSE / sshfs components for disk mapping are optional external dependencies; this installer neither installs them automatically nor requests privileges.

## Signing Limitations of the Current Distribution Package

This 1.1.1 installer is only locally ad-hoc signed, without a Developer ID signature or Apple notarization, so it is not a formally notarized package free of security warnings.
Only open it after confirming that the download source is trustworthy and the checksum matches. If the system warns that the developer cannot be verified, follow the
[Apple official instructions](https://support.apple.com/zh-cn/102445): after attempting to open it, go to "System Settings → Privacy & Security → Open Anyway".
Do not disable Gatekeeper. Once a formally notarized package is available, it should be preferred.

## Verifying the Download

Put the `.dmg` and the `.dmg.sha256` file with the same name in the same directory, then run the following from that directory:

```sh
shasum -a 256 -c Snake-1.1.1-macos-arm64.dmg.sha256
```

An output of `OK` means the checksum matches the published value; a checksum does not replace a trustworthy source and a developer signature.
