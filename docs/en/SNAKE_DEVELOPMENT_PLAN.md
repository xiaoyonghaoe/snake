[简体中文](../SNAKE_DEVELOPMENT_PLAN.md) · **English**

# Snake macOS SSH Client Development Plan

## Current Implementation Progress (2026-09-02)

Already delivered:

- The AppKit/SwiftUI main window, session tree, unified terminal/SFTP tabs, Bonsplit split view, tab tearing into windows, and cross-window drop targets are implemented according to the high-fidelity prototype.
- Double-clicking a session opens a terminal; the context menu offers opening a terminal/SFTP, editing, and delete with secondary confirmation; sessions can be dragged into peer groups.
- During the current development phase, session passwords/private key passphrases are temporarily stored in a plaintext credential file with permissions `0600`, and SQLite stores only a credential reference; this will later be replaced by an external password tool adapter, while the private key still stores only a security-scoped bookmark.
- The Rust `snake_core` is integrated into Swift through UniFFI and is responsible for groups, sessions, mappings, and transfer history in WAL SQLite; the legacy JSON configuration is migrated once.
- Real Rust/libssh2 SFTP connections: password/private key authentication, Snake-managed `known_hosts`, first-time fingerprint confirmation, fingerprint change blocking, directory browsing, creation, renaming, deletion, upload, and cached download-then-open.
- Finder file/folder selection and drag-in, real 1 MiB in-memory streaming transfer between SFTP panels, and progress, speed, pause, resume, and cancel driven by the Rust atomic controller; abnormal startup transitions to `interrupted`.
- SFTP local upload supports resume and parallel chunking for large files: by default, files over 50 MB use 4 independent connections, and the threshold and concurrency can be adjusted in settings; on overwrite, chunks are first merged into a hidden remote staging file and then replace the real file through `mv -f`.
- SFTP identifies symbolic links through `lstat/readlink`: the file table shows the link target, directory links can be entered, file links can be opened, deletion performs only `unlink`, and cross-SFTP copy preserves the original link target.
- Remote permission editing supports recursively applying `chmod -R` to real folders; symbolic links do not offer the recursive option, avoiding modification of external directories across the link boundary.
- The main window has no persistent transfer bar; when the current SFTP tab has local uploads, a mini determinate progress indicator appears to the left of the item statistics at the bottom of the file table and collapses into a record icon two seconds after completion. Clicking it shows only the upload records and control buttons for the current lifetime of the current tab.
- The settings window already provides the transfer threshold, chunk concurrency, and terminal monospaced font and font size; terminal font changes are applied immediately to the stable SwiftTerm surface without triggering an SSH reconnect.
- The Rust/libssh2 `TerminalHandle` has replaced the system `ssh`: SwiftTerm keeps a stable rendering surface, and UniFFI provides PTY output callbacks, input, resize, and close; terminals and SFTP share Snake `known_hosts`, the CredentialStore, a 15-second timeout, and a 30-second keepalive.
- Terminal I/O is exclusively owned by a single Rust worker thread holding the libssh2 Session/Channel, and Swift input, resize, and close are serialized through a command queue; password authentication, input after 20 seconds of idleness, `stty size` resize, command output, and exit with status code 0 have been verified against a real OpenSSH server.
- macFUSE/sshfs detection, managed mount paths, private key SSHFS, symbolic links, open in Finder, and safe unmounting; passwords never enter argv or environment variables.
- Self-contained debug app packaging: the Rust dylib is embedded into Frameworks using `@rpath` and carries `SnakeMountHelper`.

Still in later phases:

- SFTP name conflicts "apply to current batch", automatic renaming, per-host global concurrency limits, and LRU cleanup of the remote open cache.
- The managed `SSH_ASKPASS` FIFO for password-based SSHFS, `lsof` prompts for processes holding the mount, and forced unmount confirmation.
- Universal 2, Developer ID, notarized DMG, and isolated OpenSSH integration tests.

> Document version: 1.0  
> Target platform: macOS 15+  
> Interface language: Simplified Chinese (source language), English  
> Technology stack: Swift, SwiftUI, AppKit, Rust, UniFFI  
> Current phase: continuous production engineering implementation, Rust SSH PTY and the core SFTP path are complete

## 1. Document Purpose

This document guides the Snake macOS SSH client from the existing HTML high-fidelity prototype into production development, fixing the product scope, interaction rules, technical architecture, data model, security boundaries, phase deliverables, and acceptance criteria.

The first version of the product contains the following core capabilities:

- SSH sessions, single-level groups, tabs, icons, and credential management.
- Multiple terminal tabs, horizontal/vertical splitting, and cross-pane dragging.
- Google Chrome-like tab tearing into a separate window, cross-window moves, and re-merging.
- Opening SFTP from an SSH session, with file browsing, file picker upload, and remote file opening.
- Remote file transfer between two SFTP panels in the same window or across windows.
- Cross-SFTP transfers use global task state; local upload records reside only in the memory of the current SFTP tab and provide file-level progress, pause, resume, cancel, and failure retry.
- Local disk mapping based on macFUSE/SSHFS, dependency diagnostics, and safe unmounting.
- Developer ID signing, notarization, and DMG distribution.

The internal interaction prototype is not released with the public source code. The production implementation should follow the confirmed information architecture, but must not embed the prototype HTML/CSS code directly into the final application.

## 2. Product and Interaction Conventions

### 2.1 Main Window Structure

Every Snake work window uses the full structure:

1. The macOS unified title bar and toolbar.
2. A hideable session/disk mapping sidebar.
3. The Bonsplit tab and pane workspace.
4. The connection band below the tabs.
5. Compact upload progress that appears on demand inside the SFTP file table; when there are no upload records it occupies no space.

The main interface does not keep a right-side session inspector. Session information is presented through the sidebar, connection band, edit form, and context menus.

Visual baseline:

- Chrome Frost: `#ECEEF2`
- Canvas: `#F7F8FA`
- Ink: `#1D1D1F`
- Muted: `#6E7380`
- Action Blue: `#0A84FF`
- Secure Mint: `#2DBE8C`
- Terminal Surface: `#111418`
- Toolbar height: 52pt
- Tab bar height: 34pt
- Sidebar row height: 28pt
- File table row height: 30pt
- Headings use SF Pro Display, controls use SF Pro Text, and IPs, ports, paths, fingerprints, and terminals use SF Mono

The "connection band" is Snake's signature interface element. The terminal connection band continuously shows the connection state and `user@host:port`, and the security lock popover shows the actually negotiated algorithms and the host fingerprint; because SSH has no reliable standard API for querying the current directory of an interactive shell, the terminal does not display a guessed path. The SFTP path is managed by the file browser itself. Apart from windows and system popovers, card shadows are not stacked.

### 2.2 Session Entry Points

- The sidebar shows only SSH sessions and disk mappings, not a separate SFTP navigation item.
- Double-clicking an SSH session always creates a new terminal tab; multiple terminals for the same session may exist at the same time.
- The SSH session context menu contains: open new terminal, open SFTP, edit, delete.
- SFTP tabs can only be created from an SSH session.
- Groups are single-level in the first version, and sessions can be dragged between peer groups.
- Closing a tab does not delete the SSH session configuration.

### 2.3 Workspace Lifecycle

- Terminals and SFTP use a unified work tab model.
- Tabs can be reordered within a window, moved to other panes, or dragged to an edge to create a split.
- Tabs can be torn out into full separate windows, and can be dragged back to the original window or to other Snake windows.
- The application persists only sessions, mappings, settings, and history; it does not restore terminals, SFTP tabs, window count, or the Bonsplit layout.
- On restart, the application creates only one empty work window.

## 3. Overall Technical Architecture

### 3.1 Project Composition

It is recommended to use Swift Package Manager to manage the native side:

| Module | Responsibility |
| --- | --- |
| `SnakeExecutable` | Application entry point, AppDelegate, menus, and lifecycle |
| `SnakeApp` | SwiftUI/AppKit interface, windows, Keychain, Finder, state coordination |
| `SnakeCoreBindings` | UniFFI-generated Swift bindings and Swift-side adapters |
| `SnakeMountHelper` | Constrained SSHFS mount helper process |
| `snake_core` | Rust models, SQLite, SSH/SFTP, transfer queue, and validation logic |

Responsibility boundaries:

- AppKit: `NSWindow`, toolbar, menus, keyboard shortcuts, drag and drop, file pickers, Finder, Keychain, permissions, and mount processes.
- SwiftUI: session tree, edit forms, connection state, SFTP toolbar, transfer queue, and settings interface.
- SwiftTerm: terminal rendering and input, integrated through `NSViewRepresentable` or `NSViewControllerRepresentable`.
- `NSTableView`: the SFTP file list for large directories, avoiding SwiftUI performance problems with large numbers of rows and frequent updates.
- Rust: business models, database, SSH/PTTY, SFTP, remote streaming, task state machine, and connection validation.
- UniFFI: Swift/Rust cross-language records, enums, handles, and observers.

### 3.2 Main Dependencies

Swift side:

- [Bonsplit](https://github.com/almonk/bonsplit): in-window tabs, panes, and dragging.
- SwiftTerm: terminal control.
- Security.framework: macOS Keychain.
- AppKit, SwiftUI, UniformTypeIdentifiers.

Rust side:

- `ssh2`/libssh2: SSH, PTY, and SFTP.
- `rusqlite`: SQLite access, using bundled SQLite.
- `uniffi`: Swift bindings.
- `serde`: configuration and internal event serialization.
- `uuid`: stable identifiers.
- `sha2`: mount directories and cache keys.
- `thiserror`: structured errors.
- `zeroize`: cleanup of temporary credential memory.

Dependencies must be locked to `Package.resolved` and `Cargo.lock`. Version upgrades require the full regression test suite.

### 3.3 Threading Model

- Swift UI state is updated only on `@MainActor`.
- Each interactive terminal connection uses a dedicated blocking worker thread and command channel.
- SFTP browsing connections are independent of terminal connections.
- Transfer tasks are managed by the Rust global scheduler and do not depend on whether a particular SFTP view still exists.
- UniFFI observer callbacks must not wait for Swift to return; after Swift receives an event it switches to the main thread.
- Terminal output should be merged into bounded batches before callbacks, avoiding byte-by-byte crossing of the FFI boundary.

## 4. Bonsplit and Chrome-Style Multi-Window

### 4.1 Framework Decision

No new third-party multi-window framework is added. Bonsplit is responsible for tab reordering, cross-pane movement, and horizontal/vertical splitting within a single window; AppKit is responsible for native windows and cross-window drag and drop.

Bonsplit currently has no public tab-tearing interface, so a minimal MIT-licensed fork is maintained. The modification scope is limited to:

- Providing screen coordinate callbacks when tab dragging starts, updates, and ends.
- Providing the `detachTab` and `insertExternalTab` controller methods.
- Providing external tab drop target and insertion position callbacks.
- Keeping the split tree, animations, keyboard navigation, and content lifecycle unchanged.

The fork must be pinned to an explicit commit, record its patches separately, retain the upstream LICENSE, and preferably contribute general capabilities upstream.

`NSWindowTabGroup` is not used. System window tabs can only combine entire native windows and cannot express the Bonsplit multi-pane structure inside a single Snake window.

### 4.2 State Ownership

```text
ApplicationStore
├── SessionRepository
├── GlobalTransferStore
├── MountStore
├── CredentialCoordinator
├── ActiveConnectionRegistry
└── WorkspaceWindowCoordinator
    ├── WorkspaceWindowState A
    │   └── BonsplitController A
    └── WorkspaceWindowState B
        └── BonsplitController B

WorkspaceTabRuntime
├── TerminalRuntime + TerminalHandle + TerminalSurfaceController
└── SFTPRuntime + SFTPHandle + NavigationState
```

- `ApplicationStore` is application-level shared state.
- `WorkspaceWindowState` stores only one window's tabs, panes, focus, and interface expansion state.
- `WorkspaceTabRuntime` exists independently of windows, ensuring that connection and content state is not rebuilt when tabs move across windows.
- `WorkspaceWindowCoordinator` registers all windows and is responsible for hit testing, creation, closing, and tab move transactions.

### 4.3 Drag and Drop Payloads

Define the following UTTypes:

| Type | Purpose | Payload |
| --- | --- | --- |
| `com.snake.workspace-tab` | Tab move | `windowID`, `tabID`, transaction ID |
| `com.snake.remote-file-reference` | SFTP remote file transfer | In-process reference ID, source profile, path, type |

Drag and drop payloads must not contain passwords, Keychain contents, private key paths, complete SSH configurations, or connection handles.

### 4.4 Tab Move Transactions

Cross-window moves use two-phase commit:

1. The source creates a random transaction ID and marks the runtime as `moving`.
2. The target window verifies that the tab, runtime, and drop target are still valid.
3. The target reserves the tab position or creates the target pane.
4. The target takes over the `WorkspaceTabRuntime` and completes view mounting.
5. After the target confirms success, the source deletes the original tab.
6. If any step fails or the user presses Escape, the target cancels the reservation and the source restores the original tab.

Drag behavior:

- Dropping on the tab bar of the same window: reordered by Bonsplit.
- Dropping on another pane of the same window: moved by Bonsplit.
- Dropping on the content edge of a window: creates a horizontal or vertical pane according to the hit edge.
- Dropping on the tab bar of another window: inserts at the specified index.
- Dropping on the content edge of another window: creates a pane in the target window and then inserts.
- Dropping outside all Snake windows: creates a new window near the pointer.

The default size of a separate window is 1120×760, and the minimum size is 1024×700. New windows must be constrained within the `visibleFrame` of the target display.

The source pane closes automatically when it becomes empty; the source window closes automatically when it loses its last tab. The application must always keep at least one empty work window. When dragging the last tab, the target window is shown first, and then the source window is closed.

### 4.5 Runtime Preservation

- Terminal PTYs and Rust `TerminalHandle`s are not reconnected because a tab changes windows.
- `TerminalSurfaceController` holds a stable SwiftTerm view and re-mounts it in the target host to preserve the buffer, selection, and scroll position.
- The SFTP runtime preserves the connection, current path, history, selection, sorting, and upload entry state.
- The Bonsplit view does not own the connection lifecycle; closing or destroying a view must not implicitly close a Rust handle.
- Cross-SFTP transfer tasks are held by the global runtime; local upload records belong only to the SFTP tab that initiated the upload, are released when the tab closes, and are not written to SQLite.
- A window stores only the sidebar and Bonsplit focus; no persistent transfer queue is shown at the bottom of the main window.
- Windows set `isRestorable = false`, disabling automatic macOS workspace restoration.

Closing a window that contains active terminals shows a confirmation; after confirmation, the terminals in that window are closed. Transfer tasks are not cancelled by closing a window.

## 5. Session and Group Management

### 5.1 SSH Session Fields

- Name
- Parent group
- Hostname or IP
- Port, default 22, range 1...65535
- Username
- Authentication method: password or private key
- Keychain reference
- Private key security-scoped bookmark
- Tag array
- SF Symbol icon name
- Sort value

Name, host, port, and username are required. Password and passphrase input is written only to the Keychain and is never filled back in plaintext.

### 5.2 Delete Semantics

Deleting a session requires secondary confirmation and executes in the following order:

1. List active terminals, SFTP browsing connections, and dependent mappings.
2. After the user confirms, stop active terminals and browsing connections.
3. Disable dependent mappings, but keep the mapping records so the user can rebind them.
4. Keep transfer history with session snapshots.
5. Delete the session in a SQLite transaction and release associated foreign keys.
6. After the database transaction succeeds, delete the Keychain credential and private key bookmark references.

If the database transaction fails, credential references must not be deleted in advance. If deletion of the credential file fails, record a repair event containing no secrets and retry cleanup on the next launch.

## 6. SSH, Terminal, and Credential Security

### 6.1 CredentialStore

- Current backend: `~/Library/Application Support/Snake/credentials.json`.
- File permissions are forced to `0600`, and parent directory permissions are forced to `0700`.
- Password reference: `<profileID>/password`; private key passphrase reference: `<profileID>/key-passphrase`.
- SQLite stores only the credential reference; the credential file uses a versioned AES-256-GCM ciphertext format, with a new nonce on every save. The 256-bit random key is stored separately in the system keychain, is not synced, and is not embedded in the application.
- `CredentialStore` keeps the save/readData/delete interface and can later be replaced by a password tool adapter. SSH, SFTP, and upload decrypt automatically without adding an authentication barrier merely to view plaintext.
- Migration of the legacy plaintext file is supported at startup and on first access; temporary ciphertext is written, decryption is verified, and then the file is atomically replaced without creating a plaintext backup. If the key is missing, the file is corrupted, or writing fails, the operation stops and the original file is preserved.
- Legacy Keychain references are migrated to the encrypted backend after the first successful read; the system keychain is still used to store the encryption key.
- Viewing a password/passphrase on the session edit page requires deviceOwnerAuthentication with a fresh LAContext; a saved value is filled back into its original field and can be edited, and when a draft exists the old value is not read to overwrite it. After 30 seconds, on focus loss, or when returning from the background, dots are restored and the draft is preserved; the draft is cleared only when the form is closed or the authentication method is switched. Mere viewing without modification does not rewrite the credential. See [Credential Encryption and Viewing](CREDENTIAL_SECURITY.md) for specific boundaries and acceptance criteria.
- The private key is selected with `NSOpenPanel`, saving a security-scoped bookmark without copying the file.

After Swift parses a credential, it passes it to Rust as `Data`/bytes through UniFFI. Rust uses `Zeroizing<Vec<u8>>`, and clears it immediately after authentication completes or fails.

### 6.2 Host Keys

- The first connection shows the host, port, algorithm, and SHA-256 fingerprint.
- The user can choose to accept for this session only, accept and save, or cancel.
- After saving, it is written to the Snake-managed `known_hosts`.
- When the fingerprint of a known host changes, authentication is forbidden, and the old fingerprint, new fingerprint, and an entry point to remove trust are displayed.
- Terminals, SFTP, and mounts share the same host trust data.

### 6.3 Terminal Connection

- `TERM=xterm-256color`
- UTF-8 input and output
- Default connection timeout 15 seconds
- Keepalive interval 30 seconds
- Support for PTY resize, writing, closing, and state subscription
- The light/dark terminal palette follows application appearance changes, and switching does not rebuild the PTY, connection, or scroll buffer
- Rust provides the host key, SHA256 fingerprint, key exchange, and bidirectional encryption and integrity algorithms using the actual libssh2 negotiation results; the interface displays them through the security lock popover rather than using static algorithm text
- The terminal connection band does not show a fixed or guessed working directory, nor does it inject a path tracking hook into the remote shell
- The recommended upper limit for a single output block crossing the FFI boundary is 64 KiB
- Network errors, authentication failures, host key errors, and remote exits use different error codes
- A transient terminal `Connection` error is automatically retried once after about 400 ms; authentication, host key, and parameter errors are not retried automatically. The TCP, handshake, channel, PTY, and shell startup stages each report their own error context.

Secrets must not appear in:

- SQLite
- Logs
- Crash contexts
- `Process` arguments
- Environment variables
- `NSPasteboard`
- Drag and drop payloads
- Error messages the user can copy

## 7. SFTP and Transfer Queue

### 7.1 SFTP Browsing

Each SFTP tab uses an independent SSH/SFTP connection, with features including:

- A path bar where an absolute address can be typed directly and navigated with Enter, plus copying of the current address.
- A directory tree and a high-density file table.
- Name, size, type, modification time, and permissions columns.
- Refresh, back, forward, and parent directory.
- Right-click in an empty area to create a file, create a directory, or upload files or folders.
- Right-click a file/folder to rename, modify octal permissions, copy the address, copy across SFTP, and delete.
- Symbolic links use a separate icon and a `→ target` marker; directory symbolic links navigate as directories, and deleting a symbolic link does not delete its target.
- File and folder upload.
- Remote file download-then-open.

Double-clicking a directory enters it; double-clicking a file first downloads it to a controlled cache and then opens it with the default application via `NSWorkspace`. The first version does not monitor external edits or automatically push changes back.

Remote open cache:

```text
~/Library/Caches/Snake/RemoteOpen/<profileID>/<path-hash>/
```

The cache uses LRU cleanup and enters cleanup when either condition is met: files older than 7 days or a total size over 500 MB.

### 7.2 Upload Entry Points

- Right-click in an empty area of the file table and choose "Upload Files" or "Upload Folder", selecting local items with `NSOpenPanel` multi-selection.
- On Finder drag-in, only the file URL, name, type, and size are read.
- The drop overlay must display the target SSH session and remote directory.
- Folder tasks scan the total size first; indeterminate progress is shown during scanning, switching to determinate progress when done.

#### 7.2.1 Resume and Parallel Chunking

- Small and large files are uniformly written to deterministic hidden chunks in the target directory, without truncating the real target directly.
- The default threshold is 50 MB; parallelism is enabled only when the file is strictly larger than the threshold, with a default concurrency of 4, configurable in settings from 1 to 8.
- Parallel chunks use mutually independent SSH/SFTP connections. Each connection writes only one contiguous range, avoiding random writes to the same remote handle from multiple threads.
- Chunk names are derived from a SHA-256 digest computed from the target path, local size, modification time, and chunk count, and contain no credentials. When the same version of a file is selected again, Rust reads the remote chunk lengths and continues from the corresponding local offsets.
- Pause and cancel are driven by a `CoreTransferControl` shared by all chunks; on interruption, complete or partial chunks are retained so the user can resume by starting the same upload again.
- After all chunks complete, the remote side first merges them sequentially into a `staging` file in the same directory using `cat`. If the user explicitly chooses to overwrite, `mv -f -- <staging> <target>` is executed last; if merging or transfer fails, the old target remains unchanged.
- Merging and moving use strict absolute path validation and single-quote shell escaping; the root directory, parent directory traversal, control characters, and leading/trailing whitespace are forbidden.
- Progress aggregates the completed bytes of all chunks, UI updates are throttled to at most 10 Hz, and the upload popover states "parallel chunking / resume supported".

### 7.3 Cross-Remote Transfer

Remote files or folders can be dragged between two SFTP panes or between different Snake windows.

Implementation rules:

- Rust obtains SFTP connections for the source and target separately.
- Streaming reads and writes use a fixed 1 MiB bounded in-memory buffer.
- Creating local temporary files is forbidden.
- Folders are expanded by the queue into directory creation and file copy tasks.
- Resuming from the completed part on the target side is allowed based on file size and offset, but the source size and modification time must be revalidated before resuming.

### 7.4 Conflict Policy

- `ask`: ask item by item.
- `overwrite`: overwrite the target.
- `skip`: skip conflicting items.
- `rename`: generate `name copy N.ext`.

The conflict dialog supports "apply to current batch". Overwriting must not be the default without the user's choice.

### 7.5 Queue State Machine

```text
draft -> scanning -> queued -> running
                           ├-> paused -> queued
                           ├-> succeeded
                           ├-> failed -> queued (retry)
                           ├-> cancelled
                           └-> interrupted -> queued (manual retry)
```

- Global concurrency: 3
- Per-host concurrency: 2
- UI progress update frequency: at most 10 Hz
- Progress fields: total bytes, completed bytes, speed, remaining time, current file, total item count, and completed item count
- Pause takes effect after the current read/write block completes
- Cancel closes handles; whether to delete incomplete target files is decided by the task policy and recorded as an event
- After an abnormal application exit, `scanning`, `queued`, and `running` are transitioned to `interrupted` and are not automatically continued
- The main window does not show a persistent transfer bar. Local uploads show only a mini progress indicator of about 116pt on the current SFTP file table status line; on success it stays at 100% for two seconds and then collapses into a record icon, while failures and cancellations collapse directly into an icon with a status color.
- Clicking the mini progress indicator or record icon opens the current tab's records, showing file name, remote path, size, start time, live/final elapsed time, and result; clearing records does not affect active tasks, and records are cleared when the tab or application is closed.

## 8. Local Disk Mapping

### 8.1 Dependency Detection

The following need to be detected:

- `/opt/homebrew/bin/sshfs`
- `/usr/local/bin/sshfs`
- `/Library/Filesystems/macfuse.fs`

When dependencies are missing, show the current detection results, installation instructions, and a "Recheck" button. Snake does not automatically download, install, or elevate privileges.

### 8.2 Path Model

```text
Remote directory
   ↓ SSHFS
/Users/Shared/.SnakeMounts/<SHA256(mappingID)>
   ↓ symbolic link
User-selected local access directory
```

The actual mount path is managed by Snake. The user path serves only as a symbolic link entry point, avoiding FUSE mounts directly on arbitrary user directories.

### 8.3 SnakeMountHelper

The helper must be signed with the application and perform strict validation:

- Only preset sshfs executable paths are allowed.
- The real mount target must be located under `/Users/Shared/.SnakeMounts/`.
- Invoking an arbitrary shell is forbidden.
- Arguments are passed to `Process` as structured arrays and must not be concatenated into command strings.
- The password is received from standard input.
- The helper creates a one-time FIFO accessible only to the current user, which `SSH_ASKPASS` reads once and which is then deleted.
- The password must not appear in argv, environment variables, or logs.

SSHFS arguments should include strict host key verification, Snake `known_hosts`, reconnect, ServerAlive, connection timeout, macOS permission compatibility, and controlled caching.

### 8.4 Unmount and Recovery

- Normal unmounting preferentially calls `diskutil unmount`.
- On failure, `/usr/sbin/lsof` is used to find holding processes and show them to the user.
- Forced unmounting is allowed only after explicit user confirmation.
- Mounts established by external programs are detected and displayed as "external mount", and their credentials must not be taken over directly.
- Automatic mounts are attempted only once at startup; after a dependency, credential, or host trust check fails, the failure state remains visible without infinite retries.

Automatic mounting is configuration behavior and does not mean restoring terminals, SFTP, or the window workspace.

## 9. Data Model and Persistence

Database path:

```text
~/Library/Application Support/Snake/snake.sqlite3
```

Database settings:

- `PRAGMA foreign_keys = ON`
- WAL journal mode
- Versioned migrations
- Each migration is transactional

### 9.1 Main Tables

#### `session_groups`

| Field | Type | Description |
| --- | --- | --- |
| `id` | TEXT PK | UUID |
| `name` | TEXT | Group name |
| `sort_order` | INTEGER | Sort order |
| `created_at` | INTEGER | Creation time |
| `updated_at` | INTEGER | Update time |

#### `ssh_profiles`

| Field | Type | Description |
| --- | --- | --- |
| `id` | TEXT PK | UUID |
| `group_id` | TEXT FK | Parent group |
| `name` | TEXT | Name |
| `host` | TEXT | Host/IP |
| `port` | INTEGER | Port |
| `username` | TEXT | Username |
| `auth_method` | TEXT | `password`/`private_key` |
| `keychain_account` | TEXT NULL | Keychain reference |
| `private_key_bookmark` | BLOB NULL | security-scoped bookmark |
| `tags_json` | TEXT | Tag array |
| `symbol_name` | TEXT | SF Symbol |
| `sort_order` | INTEGER | Sort order |
| `created_at` | INTEGER | Creation time |
| `updated_at` | INTEGER | Update time |

#### `known_hosts`

Stores host, port, algorithm, fingerprint, public key, and first confirmation time. A unique constraint is established on `host + port`.

#### `transfer_jobs`

Stores source/target profile IDs, session snapshots, source/target paths, file type, total size, completed size, speed, state, conflict policy, error code, and timestamps.

#### `transfer_events`

Stores task state changes and diagnostic events containing no sensitive data.

#### `mount_mappings`

Stores profile ID, session snapshot, remote path, user access path, actual mount path, automatic mount, enabled state, and last error.

#### `settings`

Stores theme, default conflict policy, queue concurrency settings, sidebar behavior, and log level.

The current implementation first saves the chunk threshold, chunk concurrency, and terminal font and font size through `UserDefaults`; when the `settings` table migration is introduced, key-value compatibility is maintained and the user's existing configuration is migrated once.

The database does not store windows, tabs, terminals, the current SFTP path, or the Bonsplit layout.

## 10. Swift and UniFFI Interface Contract

### 10.1 Swift Workspace Types

```swift
struct WindowID: Hashable, Codable
struct WorkspaceTabID: Hashable, Codable

enum WorkspaceTabKind {
    case terminal(profileID: String)
    case sftp(profileID: String)
}

struct TabTransferPayload: Codable {
    let sourceWindowID: WindowID
    let tabID: WorkspaceTabID
    let transactionID: UUID
}
```

Need to implement:

- `ApplicationStore`
- `WorkspaceWindowState`
- `WorkspaceTabRuntime`
- `TerminalSurfaceController`
- `WorkspaceWindowCoordinator`
- `GlobalTransferStore`
- `CredentialCoordinator`
- `MountCoordinator`

### 10.2 UniFFI Data Types

- `SessionGroup`
- `SSHProfile`
- `AuthMethod`
- `AuthMaterial`
- `HostKeyChallenge`
- `HostKeyDecision`
- `ConnectionState`
- `TransferRequest`
- `TransferJob`
- `TransferState`
- `ConflictPolicy`
- `MountMapping`
- `MountState`
- `DependencyStatus`
- `SnakeError`

### 10.3 UniFFI Operations

```text
open_terminal(profile_id, auth_material, observer) -> TerminalHandle
open_sftp(profile_id, auth_material, observer) -> SftpHandle
respond_to_host_key(challenge_id, decision)

enqueue_transfer(request) -> TransferJob
pause_transfer(job_id)
resume_transfer(job_id)
cancel_transfer(job_id)
retry_transfer(job_id)

create_group(input)
update_group(id, input)
delete_group(id)

create_profile(input)
update_profile(id, input)
delete_profile(id)

create_mount_mapping(input)
update_mount_mapping(id, input)
delete_mount_mapping(id)
```

`open_terminal` and `open_sftp` immediately return a handle in the connecting state. The host key challenge is emitted through the observer, and the UI calls `respond_to_host_key` to continue or terminate the connection.

## 11. Error Handling and Logging

Errors are divided at least into:

- Configuration validation errors
- Keychain errors
- Invalid private key bookmark
- DNS/network errors
- Connection timeout
- First host key confirmation or mismatch
- SSH authentication failure
- SFTP permission or path errors
- Local file read errors
- Transfer conflict, cancellation, or interruption
- Missing macFUSE/SSHFS
- Mount point in use or unmount failure
- SQLite/migration errors

Error messages need to explain what happened and the next step the user can take, without vague "operation failed" wording.

The recommended log path is:

```text
~/Library/Logs/Snake/snake.log
```

Logs use structured fields, are rolled to retain 7 days by default, and apply tiered redaction to usernames, hosts, paths, and all credentials. The first version does not introduce remote telemetry.

## 12. Build, Signing, and Release

- Minimum deployment version: macOS 15.0.
- Swift builds arm64 and x86_64.
- Rust builds `aarch64-apple-darwin` and `x86_64-apple-darwin` separately, then merges them into Universal 2.
- Hardened Runtime is enabled.
- The main application, Rust dynamic libraries, and `SnakeMountHelper` are all signed.
- Use a Developer ID Application certificate.
- Submit notarization through an App Store Connect API Key.
- Generate and sign the DMG after stapler validation.
- Before release, run `codesign --verify`, `spctl --assess`, and notarization ticket checks.
- Do not publish a Mac App Store version and do not enable App Sandbox.

## 13. Phased Development Plan

### Phase 0: Foundation Engineering

Deliverables:

- SwiftPM, Cargo, and UniFFI projects.
- Minimal Rust/Swift call chain.
- SQLite v1 migration.
- Structured logging and error model.
- Universal 2, signing, notarization, and DMG pipeline skeleton.

Exit criteria: Swift tests can call the Rust core, and both debug and release builds launch without unsigned embedded artifacts.

### Phase 1: Session Management and Terminal

Deliverables:

- Single-level groups and session CRUD.
- Password/private key authentication form.
- Keychain and security-scoped bookmark.
- known hosts and host key confirmation.
- Session context menu and double-click new terminal.
- SwiftTerm, SSH PTY, and the connection band.

Exit criteria: Multiple terminals can be opened for the same session at the same time, and passwords do not enter SQLite, logs, or arguments.

### Phase 2: Bonsplit and Multi-Window Workspace

Deliverables:

- Bonsplit tabs, horizontal/vertical splitting, and cross-pane dragging.
- Minimal Bonsplit fork and upstream patch records.
- `WorkspaceWindowCoordinator`.
- Tab tearing, cross-window moves, re-merging, and edge splitting.
- Multi-display window positioning and two-phase failure rollback.

Exit criteria: Moving a terminal across windows does not reconnect, and the scroll buffer and selection state are preserved; an abnormal drop target does not lose tabs.

### Phase 3: SFTP and Transfer Queue

Deliverables:

- SFTP browsing, path navigation, and file operations.
- Uploading files or folders through the system file picker.
- Remote file cache-then-open.
- Transfer queue, progress, pause, resume, cancel, and failure retry.
- In-window and cross-window remote file streaming transfer.

Exit criteria: Cross-remote transfer does not create local temporary files; after closing the SFTP window, background tasks continue and can be viewed in other windows.

### Phase 4: Disk Mapping and Release

Deliverables:

- macFUSE/SSHFS dependency diagnostics.
- `SnakeMountHelper`.
- Managed mount paths and user symbolic links.
- Automatic mounting, reconnection, external mount identification, and safe unmounting.
- Complete signing, notarization, and DMG.

Exit criteria: Credentials do not appear in argv, environment variables, or logs; missing dependencies are not installed automatically.

### Phase 5: Stability and Formal Acceptance

Deliverables:

- Keyboard operation, VoiceOver, focus rings, and reduced motion.
- Large directory, large file, weak network, and abnormal exit tests.
- Simplified Chinese copy proofreading.
- Third-party license list and release checklist.

Exit criteria: All acceptance matrix items pass, and there are no high-priority security or data loss issues.

## 14. Test Plan

### 14.1 Rust Unit Tests

- SQLite first migration, successive upgrades, and failure rollback.
- SSHProfile, path, and port validation.
- known hosts first confirmation, match, and mismatch.
- All legal/illegal transitions of the transfer state machine.
- File resume and source change validation.
- Conflict policies and batch rules.
- Session deletion transaction and history snapshot retention.
- Scheduler global/per-host concurrency limits.

### 14.2 Swift Unit Tests

- Mock Keychain save, read, update, and delete.
- security-scoped bookmark creation, invalidation, and reselection.
- Session list, edit form, and context menu ViewModels.
- `WorkspaceWindowCoordinator` window registration and hit testing.
- Two-phase tab move success, cancellation, and failure rollback.
- Active terminal confirmation when closing a window.
- Rust observer to `@MainActor` state mapping.

### 14.3 Integration Tests

Using an isolated OpenSSH/SFTP service, cover:

- Password authentication and private key authentication.
- First host key and key change.
- PTY input, output, resize, and remote exit.
- File/folder upload, download, and resume.
- Network interruption and task retry.
- Streaming transfer between two remote servers.
- Large directory listing and large file transfer.

Mount tests use a mock sshfs/helper by default. Real macFUSE smoke tests run only on a controlled signed macOS machine.

### 14.4 UI Tests

- Session right-click to open terminal, SFTP, edit, and delete.
- Double-clicking the same session creates two independent terminals.
- Tab ordering, horizontal/vertical splitting, and cross-pane movement.
- Terminal/SFTP tab tearing, dragging back, and cross-window merging.
- Dragging out the last tab and multi-display positioning.
- Escape cancellation and invalid drop target rollback.
- File picker upload and cross-panel/cross-window dragging of remote files.
- Tab and remote file UTTypes are not mistakenly identified as each other.
- Transfer queue expansion, pause, resume, cancel, and retry.
- Mapping disabled, history retained, and credentials cleaned up after session deletion.

### 14.5 Visual and Accessibility

- 1440×960
- 1280×800
- Minimum 1024×700
- Single display and multiple displays
- Light, dark, and high contrast
- Keyboard focus and full keyboard access
- VoiceOver labels and action order
- `prefers-reduced-motion`
- Long Chinese text, long hostnames, IPv6, long paths, and large file numbers

## 15. Requirements Traceability Matrix

| Requirement | Main Modules | Phase | Key Acceptance |
| --- | --- | --- | --- |
| Session and group management | SessionRepository, SwiftUI Sidebar | 1 | CRUD, dragging, context menu, double-click terminal |
| Password/private key authentication | CredentialCoordinator, snake_core | 1 | Keychain, bookmark, no plaintext on disk |
| Terminal tabs and splitting | SwiftTerm, Bonsplit | 1-2 | Multiple terminals, resize, cross-pane |
| Chrome-style tab tearing | WorkspaceWindowCoordinator, Bonsplit fork | 2 | Tear out, drag back, cross-window, connection preserved |
| SFTP file browsing | SFTPRuntime, NSTableView | 3 | Navigation, refresh, file operations, open |
| Local upload | NSOpenPanel, TransferQueue | 3 | Click selection, files and folders, safe overwrite |
| SFTP transfer | Rust TransferQueue | 3 | Same window/cross window, in-memory streaming, no local files |
| Transfer progress | GlobalTransferStore | 3 | Overall progress, speed, pause, cancel, retry |
| Disk mapping | MountCoordinator, SnakeMountHelper | 4 | Dependency detection, mount, reconnect, safe unmount |
| Installation and release | Build Scripts, Signing | 4-5 | Universal 2, signing, notarization, DMG |

## 16. Copyright and Third-Party Licenses

Stacio may serve only as a behavioral and architectural reference:

- Do not copy source code, comments, naming, copy, tests, screenshots, or directory structure.
- Snake is reimplemented based on this document, upstream public documentation, and independent tests.
- Create independent models, APIs, error codes, and test data.
- Perform a manual similarity check before release.

The Bonsplit fork must retain the MIT LICENSE and copyright notice. The project needs to maintain `THIRD_PARTY_NOTICES.md`, registering Bonsplit, SwiftTerm, libssh2, OpenSSL, UniFFI, SQLite, and other dependencies included in release artifacts.

## 17. Not Included in the First Version

- ProxyJump/jump hosts.
- SSH port forwarding.
- Terminal macros, script recording, and command broadcasting.
- Uploading custom session image icons.
- Live sync-back of remote files modified by external applications.
- Restoring windows, terminals, SFTP tabs, and the Bonsplit layout on launch.
- Automatically installing macFUSE/SSHFS.
- Mac App Store and App Sandbox versions.
- Cloud sync, account systems, and remote telemetry.

## 18. Definition of Done

The first version of Snake can enter formal release only after satisfying the following conditions:

- The requirements traceability matrix is fully complete with corresponding automated or manual test records.
- Terminal and SFTP tabs can move between panes and windows without losing connection or runtime state.
- SFTP supports file picker upload, folder upload, cross-remote transfer, and complete queue control.
- Disk mapping provides dependency diagnostics, secure credential passing, and in-use prompts.
- No plaintext secrets exist in SQLite, logs, drag and drop payloads, argv, or environment variables.
- Usable at the specified window sizes, in light and dark modes, with multiple displays, and in accessibility scenarios.
- The Universal 2 application, dynamic libraries, and helper are all signed and pass notarization verification.
- Third-party licenses are complete, and the Stacio clean-room requirements pass manual review.
