[简体中文](README.md) · **English**

# Snake

Snake is a native SSH workbench for macOS 15+: session management, terminal, SFTP file transfer, and SSHFS disk mapping share a single multi-window workspace.

Website and live demo: [snakem.com](https://snakem.com)

## Installing 1.4.2

The current installer package is the **Apple Silicon (M-series) build**, requires **macOS 15 or later**, and there is no Intel / Universal 2 build.

1. Open `Snake-1.4.2-macos-arm64.dmg`.
2. Drag **Snake.app into Applications** and wait for the copy to finish.
3. Eject the disk image and launch Snake from Applications. Quit the old version before updating, and choose Replace when copying.

A local installer package has been generated and uploaded to GitHub Releases. Build artifacts are in `release/` and are not committed with the source; the release attachments are the DMG and a `.dmg.sha256` checksum file with the same name.

**The current package is only ad-hoc signed and has not been signed with a Developer ID or notarized by Apple, so the system may block it on first launch.** A passing signature integrity check does not mean Gatekeeper will allow it; see the [installation guide](docs/en/INSTALL.md) for installation and security notes. The installer contains no user sessions, passwords, or test configurations, and the macFUSE / sshfs required for disk mapping is not installed automatically.

Place the DMG and the checksum file in the same directory and run the following in that directory:

```sh
shasum -a 256 -c Snake-1.4.2-macos-arm64.dmg.sha256
```

See the [1.4.2 release notes](docs/RELEASE_NOTES_1.4.2.md) for this update, and the [release process](docs/en/RELEASING.md) for build, signing, and notarization steps.

## Current features

### Sessions and multi-window workspace

- Native AppKit/SwiftUI interface with a unified top bar and light/dark appearance; SSH sessions are managed as cards organized into nested folders, instead of a sidebar or tags. Disk mappings, the MCP service and the password manager open from the top-right corner as full-window tabs, like terminals and SFTP, and share one sectioned add/edit sheet design. Settings is a larger window with a sidebar (Appearance, Transfers, Shortcuts, Terminal, Privacy & Security); it is modal, so close it to return to other windows.
- Launching opens the SSH sessions page by default and never injects sample servers, sample mappings, or fake terminal output. Double-click the empty area at the end of the tab bar, or press the configurable `Command-T` shortcut (default), to add a session page to the current split and automatically focus search.
- The sessions page shows folder cards above sessions that are in no folder; click selects and double-click opens a folder. Folders can be created at any level, edited (name and icon) and deleted (their sessions and subfolders move up one level); search covers name, IP, user and folder. Drag a card to put folders or sessions in a new order, with the other cards sliding aside; drop a session on a folder, or a folder on the middle of another, to move it inside, or drop either on any level of the breadcrumb path to move it there; Move to Folder in the context menu and the folder picker in the editor do the same. Older tags migrate once into folders named after each session's first tag. Custom photo icons can be cropped. Session cards are compact rows showing only the icon, name and address; double-click opens a terminal and the context menu opens SFTP. The edit sheet sizes itself to its content, changes the icon from the avatar, and shows when the session was created and last updated; only changing a session's details or password counts as an update, so reordering and the re-save at launch leave it unchanged. Connecting through a card button, a double-click, or the context menu converts the current manager tab into a terminal or SFTP in place, without appending a tab.
- Bonsplit supports tab reordering, side-by-side/top-and-bottom splits, dragging tabs out into separate windows, and merging across windows. Dragging cards on the sessions page only reorders and files them; it no longer opens connections in the workspace. Moving an existing connection tab does not reconnect.
- In the main workspace window, `Command-W` closes only the current tab or a redundant empty split, and the last empty split keeps the window open. The red button only closes the window, and reopening from the Dock restores the workspace within the current process; tab layouts are not restored across app restarts.

### SSH terminal and color themes

- The Rust/russh `TerminalHandle` provides a real SSH PTY, while SwiftTerm handles rendering (Metal GPU by default) and input. Supports password/private-key authentication, host key verification, details of the actually negotiated algorithms, UTF-8 input and output, PTY resize, remote exit, and a 5-second keepalive. Terminals, SFTP browsing and MCP commands for the same session share one authenticated connection, while transfer workers use their own; transient connection errors are retried once automatically, dropped sessions reconnect automatically, and the specific failure stage is displayed. SFTP tabs check their connection every 2 seconds; after a network drop they reconnect on a 0.5/2/5 second schedule and return to the same directory instead of staying on a stale error. New SSH session tabs open the folder browsed last (or the top level if it was deleted). Terminal and SFTP tabs show a connecting animation that can be cancelled or used to View Log; when a connection fails the card stays, the link shows as broken, and the reason appears with Reconnect. The per-tab connection log records each attempt's start, duration, negotiated algorithms, failure stage code and automatic retries, never passwords or passphrases, and can be copied. The terminal's context menu offers Copy, Paste, Paste Selection, Select All, Clear Screen, Upload Files to Current Directory, Open Current Directory in SFTP, Copy SSH Command, Reconnect and View Connection Log; right-clicking empty space on the SSH sessions page creates a session or folder in the folder being shown. Every context menu (terminal, session cards, SFTP, mappings, tunnels, passwords and keys) follows one style: each item has an icon, main actions come first and later groups get a small heading, destructive items sit alone at the bottom in red, unavailable items are dimmed rather than hidden, and titles carry no ellipsis; session cards and SFTP items can also copy the SSH command or path. The session editor switches between password and key with an Authentication dropdown; keys can be picked from Keys or a file on this Mac.
- Settings offer terminal font/size, Ghostty Clear, Pure White, Classic, Vivid, Tokyo Night, Catppuccin, Gruvbox and Solarized, plus `.itermcolors` import. The default Ghostty Clear uses a charcoal background, white text and more legible ANSI colors. A one-time upgrade replaces the previous Tokyo Night selection while preserving other themes. Pure White keeps a white surface and dark text even in the dark app appearance. Other built-in light themes use white; imports keep their original colors. Switching themes preserves connections and output buffers.
- Log keywords and output fields such as permissions, time, paths, and addresses can be highlighted locally without rewriting terminal data; remote ANSI / True Color is respected, and the alternate screen disables local highlighting.
- Snake no longer injects `ls/ll` aliases, `LS_COLORS`, `CLICOLOR` or color hints into the remote shell; ANSI colors emitted by the server itself are still displayed normally. See the [current terminal color guide](docs/en/TERMINAL_COLOR_SCHEMES.md) for details.

### SFTP and file transfer

- Supports path entry, forward/back/up-one-level, file search, symbolic links, creating files/folders, renaming, visual permission display and recursive permission changes, Command/Shift multi-select deletion, and downloading remote files to a cache before opening them.
- The cache used for opened remote files can be moved in Settings (the system cache directory by default) and is trimmed automatically by age and by size, 7 days / 500 MB by default; it can also be cleared on demand. Cleanup only touches the copies Snake downloaded and never other files in the chosen folder.
- Right-clicking a folder or an empty area offers new-file and upload entries, both targeting the currently browsed directory. Files and folders can be downloaded to a local directory chosen by the user; folder transfers preserve the directory hierarchy and empty folders.
- Finder files and folders can be dragged onto the SSH terminal or the SFTP content area to upload, isolated from tab dragging. SSH uses the most recently reported shell directory, confirming first when it is unknown; SFTP uses the current directory. See the [Finder upload guide](docs/en/FINDER_UPLOAD.md) for details.
- Uploads and downloads support configurable parallel transfer, using 4 connection shards by default for files over 50 MB. Uploads support shard resume and safe overwrite through a hidden staging file; retries on the SFTP-only compatibility path re-upload from scratch. Dragging files from one SFTP tab to another server relays them through this Mac: they are downloaded to the relay folder under Settings › Transfers › Server-to-Server Transfers (the system cache folder by default), uploaded to the destination's current folder, and the relay files are deleted as soon as the upload ends, whatever the outcome. Both halves appear in the destination tab's transfer records, conflicts are asked about as for uploads, symbolic links are not transferred, and a failed copy is retried by dragging again. Across concurrent transfers, the shard and per-file transfer connections to one host are capped by "Connections per host" (8 by default, 2-16); each tab's long-lived connection and each upload batch's single operation connection are not counted. Transfers that would exceed the cap queue and show as waiting in the record.
- Remote SHA-256 is preferred, falling back to MD5 when it is unavailable; when neither is available or probing fails, the transfer is marked "unverified", which does not block normal uploads/downloads and never reads the remote file back. Digests obtained for both sides that disagree are still treated as a failure and do not overwrite the older file. See [downloads and integrity verification](docs/en/SFTP_DOWNLOAD_INTEGRITY.md) for details.
- The SSH connection strip and the bottom of SFTP show a compact progress entry on demand; clicking it shows the current tab's file-level records, elapsed time, result, and verification status, and allows pausing, resuming, cancelling, or retrying. Records are not written to SQLite and are cleared when the tab is closed or the app quits.
- Default SFTP shortcuts: `Command-F` to search, `Command-Delete (⌫)` to delete, and `Command-U` to upload files; these can be changed in Settings.

### Disk mappings and data

- Supports macFUSE/sshfs dependency detection, mapping editing, password and private-key SSHFS mounts, opening in Finder, and safe unmounting, using a constrained `SnakeMountHelper`. The password (or a saved key passphrase) reaches ssh through a managed SSH_ASKPASS channel, is tried once, and a failed mount cleans up its whole process group.
- Switch the Disk Mappings page to SSH Tunnels for local port forwarding (like `ssh -L`): pick an SSH session and enter a local port, a remote host as the server sees it (127.0.0.1 by default), a remote port and a note. Local ports listen on 127.0.0.1 only; each tunnel opens its own SSH connection and needs the server's host key already confirmed in a terminal. The status shows active connections; if SSH drops the tunnel stays Disconnected until you reconnect it; tunnels can start with Snake. Deleting a session keeps its tunnels but unbinds them. Mappings and tunnels share one row style: name and path on the left, status and an Auto-mount/Auto-connect badge on the right, then Mount/Open or Connect/Disconnect, edit and delete buttons; a click selects at once and a double-click edits. The mapping editor lists its Access Paths top to bottom (remote folder → mount point with the Finder disk name → Finder entry), each on its own line with a copy button.
- The Finder disk name shows "mapping name · SSH session name"; the system's actual mount table is authoritative. When quitting with directories still mounted or SSH tunnels still running, one confirmation lists both; confirming waits for mount operations, safely unmounts managed mappings and disconnects the tunnels, and a failed unmount cancels the quit. Cancelling leaves everything as it was. Only closing a window or a mapping tab does not unmount the disk.
- The Rust `snake_core` provides SQLite data storage, session/mapping/transfer record interfaces, and UniFFI Swift bindings; credentials are stored separately, encrypted, and never written to the database.

## Local MCP remote commands

- Enable the loopback HTTP server in the MCP service tab (top-right corner) (default `http://127.0.0.1:47821/mcp`). Create a token bound to selected SSH profiles, with optional expiry, revocation and deletion.
- Call `list_sessions` first, then `run_command` with a returned session ID. Commands run in remote `/bin/sh` without a PTY; each call is independent. Use `cwd` or `cd / && ls -l` for a directory; interactive programs are unsupported.
- Tokens are encrypted, and revealing an existing token requires system authentication. Commands, output excerpts and denials are audited, with filters, deletion and retention controls. Retention days and record limits apply on Return or when the field loses focus, changing them never deletes anything by itself, and older records are removed at launch, every 100 new records, hourly, or with Clean Up Now. A token grants execution as its bound SSH account, not a read-only sandbox. Do not put secrets in commands or output. The server is loopback-only and real tokens are never bundled.

## Security boundaries

- Passwords and private-key passphrases are encrypted with AES-256-GCM and stored in `~/Library/Application Support/Snake/credentials.json`, with the random 256-bit key kept in the system keychain, file permissions of `0600`, and directory permissions of `0700`. If the file is corrupted or the key is lost, the original file is not overwritten and there is no fallback to plaintext.
- Connections are decrypted automatically; revealing saved plaintext on the edit page requires system authentication such as Touch ID or the Mac login password, and it is hidden after 30 seconds or when the window loses focus. After a successful authentication, other passwords and passphrases can be revealed for 30 seconds without authenticating again. Ad-hoc-signed updates may still trigger a separate keychain access authorization, so development builds are not guaranteed to be prompt-free.
- SQLite still stores only a credential reference, never passwords; integrating a password tool later will replace only the `CredentialStore` backend.
- Private keys are referenced through security-scoped bookmarks; files picked directly are not copied.
- The Keys section of the password manager tab imports OpenSSH/PEM/PuTTY private keys or generates Ed25519 keys, and copies the public key line for `authorized_keys`. Imported keys are re-encoded as OpenSSH (same passphrase) and stored as `0600` files in `~/Library/Application Support/Snake/Keys/` (directory `0700`), with passphrases encrypted. Sessions pick them from the Keys menu in the editor, and terminals, SFTP, MCP and SSHFS all use the same file. A key whose fingerprint is already present is not imported twice, and a key still used by a session cannot be deleted. Both password and key lists show created and modified times (renaming, a new username or a new password counts as a change). A click selects a row at once and a double-click opens its editor; the key editor renames the key and shows its public key, fingerprint and the sessions using it.
- The password manager tab in the top-right corner encrypts reusable accounts and passwords. Each SSH profile receives its own copy; library updates can be selectively synchronized, and independent username/password edits detach the profile. The private-key editor displays the resolved local path.
- Settings › Privacy & Security can turn off "Show macOS Passwords AutoFill when clicking a password field"; Snake's password and key passphrase fields then stop offering AutoFill suggestions (on by default; no system setting changes).
- When a host key changes, the SSH terminal, SFTP, and remote directory picker show the old and new fingerprints; only after explicit confirmation is the trust record for the corresponding address and port updated and the connection re-established; cancelling keeps the original record, and the actual fingerprint is verified again on reconnect.
- `SnakeMountHelper` accepts only managed mount directories and sshfs executable paths from the allowlist.
- Terminal credentials are passed as bytes to Rust/russh through UniFFI, and the authentication material is zeroed after use; the connection pool keys entries by a credential digest and never stores the secret; the system `ssh` is never launched, and the password is never passed through argv, environment variables, or drag-and-drop payloads.
- Password SSHFS mounts never pass the secret through argv, environment variables or files: the app opens a one-off Unix socket in a private temporary folder and answers only an askpass process owned by the user, running SnakeMountHelper, and inside that mount's process group; the secret is wiped when the mount ends.

## Localization

- Snake ships Simplified Chinese (the source language, default, and fallback) and English.
- The interface language can be changed in Settings › Appearance › Language; it applies immediately and is remembered.
- Text provided by macOS (permission prompts, Finder and system menus) follows the system language.
- How to add a language: copy `Resources/Localization/en.lproj` to a new `<language>.lproj`, translate `Localizable.strings` (keys are the Simplified Chinese source strings; keep every `%@` placeholder and the `<key>#plural` entries), add the language to `CFBundleLocalizations` in `Resources/Info.plist` and to `AppLanguage.supportedIdentifiers`, then run `swift test --disable-sandbox --filter LocalizationTests` to verify the table is complete.
- Note that `swift run Snake` is not a bundled app, so `Bundle.main` cannot find the `.lproj` tables and the interface stays Simplified Chinese; use `scripts/package-debug-app.sh` to test another language.

## Not yet delivered

- Workspaces are not restored across app restarts and interrupted transfers are not resumed automatically; a failed download retries from a fresh source version, and resumable downloads are not promised.
- The Intel / Universal 2 installer package, and Developer ID signing and notarization have not been delivered yet.
- 1.4.2 verification: of 281 Swift tests, 274 passed, 6 external fixtures were skipped and 1 pre-existing mount test failed with `invalidMapping`. Rust: 40 unit tests passed (the Rust core is unchanged, so the loopback-sshd regressions that passed for 1.4.1 were not rerun). The full suite is not all-green; GUI, the quit confirmation, the AutoFill switch in real windows and clean-Mac installation acceptance remain manual.

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

System requirements: Xcode 16.4, Swift 6.1, Rust 1.89+ (required by russh 0.64) and Python 3. SwiftTerm is pinned to `v1.13.0` because Swift 6.1 on the current workstation is incompatible with the Swift 6.2 manifest on its main branch.

`scripts/package-debug-app.sh` creates an ad-hoc-signed development app at `.build/debug-app/Snake.app` with the embedded Rust dynamic library and Mount Helper, for local interface testing.

### Building the DMG

```sh
zsh scripts/package-release-dmg.sh 1.4.2
```

Python 3 is required; the script builds with Release optimizations and only produces an installer package for the current host architecture. Artifacts are placed in `release/`, and it refuses to overwrite existing files with the same name. The app contains the Rust dynamic library, the Mount Helper, SwiftTerm Metal resources, and third-party licenses, and does not depend on dynamic libraries or rendering resources from the workspace.

The version and build numbers are stored in `Resources/Info.plist` and are currently `1.4.2` / `1420`. The script uses ad-hoc signing by default; see the [release process](docs/en/RELEASING.md) for Developer ID signing, notarization, and regenerating the checksum file. Local packaging does not automatically create Git tags or publish a GitHub Release.

On launch, the app automatically migrates legacy plaintext credentials to the encrypted file; if an old session still has only a Keychain reference, it is migrated into encrypted storage after its first successful read. See [credential encryption and viewing](docs/en/CREDENTIAL_SECURITY.md) for the detailed design and manual acceptance steps.

See the [development plan](docs/en/SNAKE_DEVELOPMENT_PLAN.md) for the complete product and security constraints. The public source does not include the internal interaction design prototypes.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the complete third-party attribution.
