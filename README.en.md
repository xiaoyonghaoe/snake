[简体中文](README.md) · **English**

# Snake

Snake is a native SSH workbench for macOS 15+: session management, terminal, SFTP file transfer, and SSHFS disk mapping share a single multi-window workspace.

## Installing 1.1.1

The current installer package is the **Apple Silicon (M-series) build**, requires **macOS 15 or later**, and there is no Intel / Universal 2 build.

1. Open `Snake-1.1.1-macos-arm64.dmg`.
2. Drag **Snake.app into Applications** and wait for the copy to finish.
3. Eject the disk image and launch Snake from Applications. Quit the old version before updating, and choose Replace when copying.

A local installer package has been generated and uploaded to GitHub Releases. Build artifacts are in `release/` and are not committed with the source; the release attachments are the DMG and a `.dmg.sha256` checksum file with the same name.

**The current package is only ad-hoc signed and has not been signed with a Developer ID or notarized by Apple, so the system may block it on first launch.** A passing signature integrity check does not mean Gatekeeper will allow it; see the [installation guide](docs/en/INSTALL.md) for installation and security notes. The installer contains no user sessions, passwords, or test configurations, and the macFUSE / sshfs required for disk mapping is not installed automatically.

Place the DMG and the checksum file in the same directory and run the following in that directory:

```sh
shasum -a 256 -c Snake-1.1.1-macos-arm64.dmg.sha256
```

See the [1.1.1 release notes](docs/RELEASE_NOTES_1.1.1.md) for this update, and the [release process](docs/en/RELEASING.md) for build, signing, and notarization steps.

## Current features

### Sessions and multi-window workspace

- Native AppKit/SwiftUI interface with a unified top bar and light/dark appearance; SSH sessions use card tabs instead of a sidebar or groups. Disk mappings open in a separate tab from the entry point in the top-right corner.
- Launching opens the SSH sessions page by default and never injects sample servers, sample mappings, or fake terminal output. Double-clicking the empty area at the end of the tab bar adds a session page to that split; `Command-K` focuses session search, creating a session page first when necessary.
- Supports session editing, space-separated tags, tag filtering with multi-selection, and cropping custom photo icons. Connecting through a card button, a double-click, or the context menu converts the current manager tab into a terminal or SFTP in place, without appending a tab.
- Bonsplit supports tab reordering, side-by-side/top-and-bottom splits, dragging tabs out into separate windows, and merging across windows. Dropping a session card into the workspace creates a new connection, and holding Option creates an SFTP connection; moving an existing connection tab does not reconnect.
- In the main workspace window, `Command-W` closes only the current tab or a redundant empty split, and the last empty split keeps the window open. The red button only closes the window, and reopening from the Dock restores the workspace within the current process; tab layouts are not restored across app restarts.

### SSH terminal and color themes

- The Rust/libssh2 `TerminalHandle` provides a real SSH PTY, while SwiftTerm handles rendering and input. Supports password/private-key authentication, host key verification, details of the actually negotiated algorithms, UTF-8 input and output, PTY resize, remote exit, and a 30-second keepalive; transient connection errors are retried once automatically, and the specific failure stage is displayed.
- Settings support the terminal font, font size, and the "Classic", "Vivid", and "Tokyo Night" themes. The default is Tokyo Night, and the light terminal background is pure white; switching themes preserves the connection and the output buffer.
- Log keywords and output fields such as permissions, time, paths, and addresses can be highlighted locally without rewriting terminal data; remote ANSI / True Color is respected, and the alternate screen disables local highlighting.
- Colorized `ls/ll` can be enabled in the current bash/zsh/fish session without modifying remote shell configuration files. The toggle takes effect on the next connection and preserves the user's complex aliases and a non-empty `NO_COLOR`. See the [terminal color guide](docs/en/TOKYO_NIGHT_COLORS.md) for details.

### SFTP and file transfer

- Supports path entry, forward/back/up-one-level, file search, symbolic links, creating files/folders, renaming, visual permission display and recursive permission changes, Command/Shift multi-select deletion, and downloading remote files to a cache before opening them.
- The cache used for opened remote files can be moved in Settings (the system cache directory by default) and is trimmed automatically by age and by size, 7 days / 500 MB by default; it can also be cleared on demand. Cleanup only touches the copies Snake downloaded and never other files in the chosen folder.
- Right-clicking a folder or an empty area offers new-file and upload entries, both targeting the currently browsed directory. Files and folders can be downloaded to a local directory chosen by the user; folder transfers preserve the directory hierarchy and empty folders.
- Finder files and folders can be dragged onto the SSH terminal or the SFTP content area to upload, isolated from tab dragging. SSH uses the most recently reported shell directory, confirming first when it is unknown; SFTP uses the current directory. See the [Finder upload guide](docs/en/FINDER_UPLOAD.md) for details.
- Uploads and downloads support configurable parallel transfer, using 4 connection shards by default for files over 50 MB. Uploads support shard resume and safe overwrite through a hidden staging file; retries on the SFTP-only compatibility path re-upload from scratch. Dragging remote files between SFTP splits/windows still transfers them from one to the other. Across concurrent transfers, the total number of transfer connections to one host is capped by "Connections per host" (8 by default, 2-16); transfers that would exceed it queue and show as waiting in the record.
- Remote SHA-256 is preferred, falling back to MD5 when it is unavailable; when neither is available or probing fails, the transfer is marked "unverified", which does not block normal uploads/downloads and never reads the remote file back. Digests obtained for both sides that disagree are still treated as a failure and do not overwrite the older file. See [downloads and integrity verification](docs/en/SFTP_DOWNLOAD_INTEGRITY.md) for details.
- The SSH connection strip and the bottom of SFTP show a compact progress entry on demand; clicking it shows the current tab's file-level records, elapsed time, result, and verification status, and allows pausing, resuming, cancelling, or retrying. Records are not written to SQLite and are cleared when the tab is closed or the app quits.
- Default SFTP shortcuts: `Command-F` to search, `Command-Delete (⌫)` to delete, and `Command-U` to upload files; these can be changed in Settings.

### Disk mappings and data

- Supports macFUSE/sshfs dependency detection, mapping editing, private-key SSHFS mounts, opening in Finder, and safe unmounting, using a constrained `SnakeMountHelper`.
- The Finder disk name shows "mapping name · SSH session name"; the system's actual mount table is authoritative. Before quitting, the app waits for mount operations and safely unmounts managed mappings, and a failed unmount cancels the quit. Only closing a window or a mapping tab does not unmount the disk.
- The Rust `snake_core` provides SQLite data storage, session/mapping/transfer record interfaces, and UniFFI Swift bindings; credentials are stored separately, encrypted, and never written to the database.

## Security boundaries

- Passwords and private-key passphrases are encrypted with AES-256-GCM and stored in `~/Library/Application Support/Snake/credentials.json`, with the random 256-bit key kept in the system keychain, file permissions of `0600`, and directory permissions of `0700`. If the file is corrupted or the key is lost, the original file is not overwritten and there is no fallback to plaintext.
- Connections are decrypted automatically; revealing saved plaintext on the edit page requires system authentication such as Touch ID or the Mac login password, and it is hidden after 30 seconds or when the window loses focus. Ad-hoc-signed updates may still trigger a separate keychain access authorization, so development builds are not guaranteed to be prompt-free.
- SQLite still stores only a credential reference, never passwords; integrating a password tool later will replace only the `CredentialStore` backend.
- Private keys are referenced through security-scoped bookmarks and the files are not copied.
- When a host key changes, the SSH terminal, SFTP, and remote directory picker show the old and new fingerprints; only after explicit confirmation is the trust record for the corresponding address and port updated and the connection re-established; cancelling keeps the original record, and the actual fingerprint is verified again on reconnect.
- `SnakeMountHelper` accepts only managed mount directories and sshfs executable paths from the allowlist.
- Terminal credentials are passed as bytes to Rust/libssh2 through UniFFI, and the authentication material is zeroed after use; the system `ssh` is never launched, and the password is never passed through argv, environment variables, or drag-and-drop payloads.
- SSHFS currently performs real mounts only for private-key sessions; password-based mounts fail explicitly until the managed SSH_ASKPASS FIFO is complete, and never fall back to passing secrets through insecure argv/environment variables.

## Localization

- Snake ships Simplified Chinese (the source language, default, and fallback) and English.
- The interface language can be changed in Settings › Appearance › Language; it applies immediately and is remembered.
- Text provided by macOS (permission prompts, Finder and system menus) follows the system language.
- How to add a language: copy `Resources/Localization/en.lproj` to a new `<language>.lproj`, translate `Localizable.strings` (keys are the Simplified Chinese source strings; keep every `%@` placeholder and the `<key>#plural` entries), add the language to `CFBundleLocalizations` in `Resources/Info.plist` and to `AppLanguage.supportedIdentifiers`, then run `swift test --disable-sandbox --filter LocalizationTests` to verify the table is complete.
- Note that `swift run Snake` is not a bundled app, so `Bundle.main` cannot find the `.lproj` tables and the interface stays Simplified Chinese; use `scripts/package-debug-app.sh` to test another language.

## Not yet delivered

- Workspaces are not restored across app restarts and interrupted transfers are not resumed automatically; a failed download retries from a fresh source version, and resumable downloads are not promised.
- Password-based mount AskPass, the Intel / Universal 2 installer package, and Developer ID signing and notarization have not been delivered yet.
- The known mount test `MountOperationsTests.testQuitIsCancelledWhenMountIsBusyOrMountTableCannotBeRead` fails with `invalidMapping`, so the overall test suite cannot be claimed to pass completely. The 24 shortcut/workspace tests related to this packaging and the installer integrity check pass; page and clean-Mac installation acceptance still need to be performed.

## Interface preview

<img width="1120" height="840" alt="image" src="https://github.com/user-attachments/assets/d9f0fd93-cc37-468d-8256-0020b76ac4f5" />
<img width="1120" height="840" alt="image" src="https://github.com/user-attachments/assets/711f9420-4b34-4621-baab-fb8f64d4e9a0" />
<img width="1120" height="840" alt="image" src="https://github.com/user-attachments/assets/5a3191e4-2f8f-467c-803d-fc2be2273275" />
<img width="1120" height="840" alt="image" src="https://github.com/user-attachments/assets/d6e4ae1c-2fa5-47a8-8071-b5d571061f6e" />
<img width="1120" height="840" alt="image" src="https://github.com/user-attachments/assets/b8586934-23b7-4b10-be21-ea05357c86f5" />
<img width="1120" height="840" alt="image" src="https://github.com/user-attachments/assets/68f66f07-2eb6-400a-83da-158eeabf8b4e" />
<img width="1120" height="840" alt="image" src="https://github.com/user-attachments/assets/c11929f1-a08b-4af1-aee9-9fd6472b8ccc" />
<img width="1120" height="840" alt="image" src="https://github.com/user-attachments/assets/2f150786-87b7-4950-a307-9670158da30c" />

## Local development

```bash
scripts/generate-core-bindings.sh
swift test --disable-sandbox
swift run Snake
scripts/package-debug-app.sh

cd Rust/snake_core
cargo test
# The password is provided on standard input and is not written to arguments or source code
cargo run --example terminal_smoke -- <host> <port> <username> <known-hosts-path>
cargo run --example sftp_smoke -- <host> <port> <username> <known-hosts-path>
```

System requirements: Xcode 16.4, Swift 6.1, Rust 1.87+. SwiftTerm is pinned to `v1.13.0` because Swift 6.1 on the current workstation is incompatible with the Swift 6.2 manifest on its main branch.

`scripts/package-debug-app.sh` creates an ad-hoc-signed development app at `.build/debug-app/Snake.app` with the embedded Rust dynamic library and Mount Helper, for local interface testing.

### Building the DMG

```sh
zsh scripts/package-release-dmg.sh 1.1.1
```

Python 3 is required; the script builds with Release optimizations and only produces an installer package for the current host architecture. Artifacts are placed in `release/`, and it refuses to overwrite existing files with the same name. The app contains the Rust dynamic library, the Mount Helper, SwiftTerm Metal resources, and third-party licenses, and does not depend on dynamic libraries or rendering resources from the workspace.

The version and build numbers are stored in `Resources/Info.plist` and are currently `1.1.1` / `1110`. The script uses ad-hoc signing by default; see the [release process](docs/en/RELEASING.md) for Developer ID signing, notarization, and regenerating the checksum file. Local packaging does not automatically create Git tags or publish a GitHub Release.

On launch, the app automatically migrates legacy plaintext credentials to the encrypted file; if an old session still has only a Keychain reference, it is migrated into encrypted storage after its first successful read. See [credential encryption and viewing](docs/en/CREDENTIAL_SECURITY.md) for the detailed design and manual acceptance steps.

See the [development plan](docs/en/SNAKE_DEVELOPMENT_PLAN.md) for the complete product and security constraints. The public source does not include the internal interaction design prototypes.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the complete third-party attribution.
