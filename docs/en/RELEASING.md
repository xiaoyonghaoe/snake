[简体中文](../RELEASING.md) · **English**

# DMG Release Process

## Build

Requires macOS, Xcode command-line tools, Swift 6, Rust and Python 3; prepare the project dependencies first.
The script builds only the current host architecture and does not misrepresent arm64 as Universal 2.

```sh
zsh scripts/package-release-dmg.sh 1.1.0
```

The output goes to `release/` (Git-ignored): the DMG and its SHA-256 file. It refuses to overwrite an artifact that already exists under the same name.
The app is built with Release optimizations; Rust, the helper, the terminal Metal resource bundle and third-party licenses are bundled with the package.
Packaging verifies resource-bundle resolution and actually compiles the Metal shaders when a GPU is available; it does not launch Snake.
Distributed contents are copied from a whitelist and do not include the session database, passwords, private keys, test fixtures or local configuration.
`.build/release-stage.*` keeps the assembled app for troubleshooting; clean it up manually once you confirm it is no longer needed.

The version is governed by `Resources/Info.plist`, and the script argument can override the marketing version inside the installer; update that file as well for an official release.
The build number is read from the plist by default and can be overridden with `SNAKE_BUILD_NUMBER`.
The Cargo license manifest is generated from the lockfile and the target architecture and includes normal/build dependencies but not dev dependencies.

## Current 1.1.0

- Apple Silicon / macOS 15+; locally ad-hoc signed, not an Apple-notarized package.
- No Intel or Universal 2 artifacts.
- The GUI pages, and SSH/SFTP and upgrade credential access after a real installation, are accepted by the user.
- This script does not create Git tags, push code or publish GitHub Releases.

## Requirements for a Formal Developer ID Release

This machine currently has no valid Developer ID Application certificate. Once you have a certificate, you can build with
`SNAKE_SIGNING_IDENTITY='Developer ID Application: …'`, and the script enables Hardened Runtime for the code.
Notarization must also be completed with your own notarytool Keychain profile; never write the Apple account, password, certificate or private key into the repository.
Changing the signing identity may affect the Keychain access approval of the previously tested build, so connections using saved credentials must be regression-tested before release.

```sh
xcrun notarytool submit release/Snake-1.1.0-macos-arm64.dmg --keychain-profile <your-notary-profile-name> --wait
xcrun stapler staple release/Snake-1.1.0-macos-arm64.dmg
xcrun stapler validate release/Snake-1.1.0-macos-arm64.dmg
```

Only staple the ticket after the notarization result is Accepted. Stapling changes the file, so the SHA-256 must be regenerated and the old value cannot be reused.
On a clean Mac, download the file from the actual release address and verify Gatekeeper, drag-to-Applications, launch, upgrade and uninstall.
For Apple's security mechanisms see the [official instructions](https://support.apple.com/zh-cn/102445).

## Release Attachments

Upload the DMG, the same-named SHA-256 and the release notes; state the architecture, the minimum system version and whether the package is notarized on the release page.
Before publishing a version, commit the corresponding source and confirm that the build matches the source, then have a maintainer create the tag and Release.

## Build Verification Record for This Release (1.1.0 / 1100)

- The Release build succeeded; the app, helper and Rust dylib are all arm64.
- `hdiutil verify` and the DMG SHA-256 check passed.
- Mounted the DMG read-only and confirmed that the Applications link points to `/Applications`; after copying the app to a separate temporary directory, `codesign --verify --deep --strict` passed.
- The separate copy can locate the app-internal resource bundles; the 7 Metal shader functions actually compiled and the app was not launched.
- Dynamic-link inspection contains only the bundled Rust dylib and Apple system frameworks/libraries, with no Homebrew or working-directory dynamic library paths.
- `swift test --disable-sandbox --filter 'WorkspaceDraggingTests|SFTPShortcutTests'`: 24 passed.
- Same-name artifact protection was verified; running packaging again does not overwrite the existing DMG.
- `spctl --assess` rejects the current ad-hoc package, consistent with the lack of Developer ID / notarization; passing signature integrity does not mean Gatekeeper allows it.
- Clean-Mac installation, GUI and full mount regression were not performed; the pages are accepted by the user. The build still has SwiftTerm's pre-existing unused-return-value warning.
