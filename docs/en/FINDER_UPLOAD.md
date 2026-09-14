[简体中文](../FINDER_UPLOAD.md) · **English**

# Finder Drag-and-Drop Upload: Reimplementation and Acceptance

Updated: 2026-09-09. Applies to the current Swift/AppKit + Rust implementation. Native gesture acceptance has not yet passed and cannot serve as a release note claiming the issue is fixed.

## Usage Rules

- Drag local files, multiple files or folders in from Finder; the target directory hint is shown before the drop.
- Terminal: uploads to the shell directory most recently reported by OSC 7; when the directory is unknown, an absolute-path confirmation dialog appears and it tries to prefill the home directory through a separate SFTP connection.
- SFTP: uploads to the current directory. Drops are rejected while a directory change is not yet complete, so files do not land in the old directory.
- Files are accepted only in the terminal/SFTP content area. The sidebar, title bar, tab bar and empty panes do not forward files to the last focused session.
- A disconnected session cannot upload; an overlay prompts you to complete the connection first.
- Folders preserve hierarchy, empty folders and zero-byte files; unreadable items show an error instead of being silently skipped.
- SSH upload also goes through a separate Rust SFTP connection, does not paste paths into the terminal and does not write file contents through the PTY.
- Upload progress and history are shown independently per tab, reusing pause, resume, cancel, failure retry, large-file chunking and safe overwrite.

## Tab and Sidebar Session Dragging

- SSH/SFTP tabs share the native `NSDraggingSession`: dragging next to an adjacent tab in the tab bar determines the merge and insertion position by the midpoint of the tab under the mouse; a non-empty content area creates a left/right/top/bottom split by direction and does not perform a center merge. The center of an empty workspace can still accept the first tab.
- The four-direction split hot zones extend inward to two-fifths (40%) of the current pane's width/height, with no fixed pixel limit; in overlapping regions the direction is chosen by the ratio of the distance to the corresponding edge. The latest visible pane size is read on every drag update and on drop, and the hot zones and preview are recalculated after a window or divider adjustment. The tab bar handles merge and reorder with priority.
- Cross-window drops go to the pane actually hit; the existing runtime does not reconnect or stop, and the SFTP path and terminal surface stay unchanged. The source is removed only after the target takes over successfully, and a temporary pane is reverted if takeover fails.
- A normal drag of a left-sidebar SSH session creates a new terminal, and holding Option creates a new SFTP; the preview updates with Option and the type is fixed on drop. Existing session configurations are not moved or deleted.
- An already-open tab can be dragged out of Snake to create a standalone window; dragging a sidebar session outside the window cancels. The title bar, sidebar and sheet-covered areas are not tab drop targets.
- Dragging a single tab to the edge of its own pane leaves a closable empty pane; moving to another existing pane cleans up the extra empty source pane.
- The event listener is only responsible for recognizing the mouse threshold that starts a drag and the Option/Escape state; commit and cleanup are handled by the native drag destination/source lifecycle callbacks, and tabs are not moved in a global mouse-up callback.

## Boundaries with Window/Tab Dragging

| Dragged content | Type | Receiver |
| --- | --- | --- |
| Finder local files/folders | `public.file-url` | The currently hit `FinderUploadHostingView` |
| Snake workspace tab | `com.snake.workspace-tab`, accepts only the active transaction of the current process | Bonsplit and the window coordinator |
| Left-sidebar SSH session | `com.snake.ssh-profile`, only the session ID and transaction identifier | The workspace native drag coordinator |
| SFTP remote file reference | `com.snake.remote-file-reference` | The existing SFTP mutual-transfer handler |

`FinderUploadSurface` is the AppKit host for workspace tab content and contains the SwiftTerm/SFTP views. The native receiving layer is re-hosted to the target window along with the content and does not cache screen coordinates. A native window delegate provides fallback routing: from the window coordinates of the current drop it walks the views, checks the actual bounds, visibleRect, current tab and occlusion state, and chooses the pane under the mouse rather than the pane holding keyboard focus.

After the window moves, the pane width changes or a tab becomes a standalone window, the next drop recalculates the coordinates. A native workspace payload must match the active transaction of the current process and does not accept IDs forged by another process or an invalidated drag. Non-Finder, non-workspace types are handed back to SwiftUI's original handling. In native routing mode Bonsplit only provides geometry markers that do not intercept the mouse; the split preview is added temporarily by the coordinator and cleaned up when the drag ends or is cancelled with Escape. The upload hint layer does not participate in ordinary mouse hit testing.

`WorkspaceHostingView` keeps the native ancestor receive registration for workspace and Finder types, preventing SwiftUI view updates from overriding the registration. A `FinderUploadArea` marks the upload area inside the terminal and the file table, and the path bar and connection band do not accept file drops. The window delegate keeps fallback routing; window dragging is still handled by AppKit. For the window's default behavior of forwarding drag destination messages see the [Apple NSWindow documentation](https://developer.apple.com/documentation/appkit/nswindow/registerfordraggedtypes(_:)).

The SwiftUI `SFTPFileDropDelegate` of the SFTP file table receives both Finder file URLs and remote file references, avoiding reliance on a child receiving layer that handles only remote transfers to pass Finder events upward. The two sources show their own hints; workspace tab and sidebar session payloads are rejected. Local files are resolved from the Data/NSURL representations through the shared URL validator, deduplicated while preserving order, and after the whole batch parses successfully they reuse the `SFTPRuntime` upload queue. The target directory is captured on drop, so changing directories during parsing does not change the target of this batch, and disconnecting/reconnecting discards a batch that has not yet been committed.

Workspace dragging is initiated by macOS 15 `NSWindow.beginDraggingSession`, not from a transparent geometry-marker view. During the drag, an AppKit receiving view registered only for workspace types is temporarily installed on the visible workspace window and removed when it ends; this overlay does not exist for ordinary clicks or Finder drag-and-drop. The native pasteboard is not system-level private storage, and the payload contains only an ID and a random transaction number, which the receiving side must also check against the current active transaction.

## Upload Data Flow

### 2026-09-10 Upload Feedback

- The SSH upload entry is at the top right of the connection band and reserves progress width; narrow panes hide secondary information such as the path. It takes no space before the first upload and keeps a clickable upload-record icon after completion.
- SSH and SFTP share progress/record components that observe LocalUploadCoordinator directly; clicking the progress or the icon opens the record for the current tab.
- A blue upload-icon pulse animation is shown during upload preparation and transfer; the percentage comes from the real transferred amount of the current file and does not simulate byte progress. The animation stops when Reduce Motion is enabled.
- When all uploads submitted in the current run finish with no failure, cancellation or skip, a green check and 100% are shown for about 4 seconds, then it collapses to the record entry; network transfer or remote commit is never delayed for the animation.
- Batch results include directory creation, skips, cancellations and failures; when only directories were uploaded with no file-level records, the details still show the result summary. Pause, resume, cancel and failure retry keep their existing behavior.
- This round verifies the feedback state through automated tests; real Finder operations, clicking the progress entry and light/dark pages are accepted by the user.

1. Read the file URL from each item of this NSPasteboard, verify that it is a local URL, and deduplicate while preserving order; if invalid items are mixed in, the whole batch reports an error.
2. Fix the remote target on drop. After the drop, switching tabs, running `cd` in the terminal or navigating in SFTP does not change the target of this batch of tasks.
3. `LocalUploadCoordinator` prepares batches for the same tab serially, preventing multiple same-name conflict confirmations from overwriting each other; concurrency inside a file still follows the settings.
4. Scan local files, normalize macOS path aliases, then compute the directory-relative path from the path components. The `/private/tmp` path returned by the enumerator must not be truncated by the raw string length of `/tmp`.
5. Call the existing Rust SFTP chunk/resume interface. Zero-byte files use a zero-length part; the UI progress denominator is handled separately from the actual file size.
6. Ask first for a same-name file; after confirming overwrite, upload the hidden part, merge staging, and finally `mv` to replace the target. The old file stays unchanged during the upload.
7. On successful transfer, update the record and have SFTP refresh the directory. A refresh error does not overwrite an upload that already succeeded.

The existing temporary bash/zsh/fish path hook continues to be used, and no remote configuration file writes are added. The upload itself does not create a new credential backend, bypass host-key verification or change the window-close policy.

## Automated Verification

Default Swift test coverage:

- Finder URL order preservation, deduplication, Chinese/spaces/percent signs and type isolation.
- Invalid items, non-existent files and disconnected tabs.
- Directory hierarchy and empty folders under macOS path aliases.
- Actual hits in both panes, hidden-tab exclusion, sidebar/title-bar rejection.
- The receiving view re-hosted to another window and continuing to receive after the window moves.
- Cancelling a drag cleans up the overlay, and invalidated coordinates no longer trigger an upload.

Rust tests add zero-length transfer and cancellation behavior; Bonsplit tests add drag-and-drop type isolation.

```sh
swift test
swift test --package-path Vendor/Bonsplit
cargo test --manifest-path Rust/snake_core/Cargo.toml
```

The real local transfer integration test is skipped by default and requires an explicitly set test directory:

```sh
SNAKE_LOCAL_SSH_FIXTURE_ROOT=/tmp/snake-finder-upload-<local-test-directory-suffix> \
  swift test --filter FinderUploadIntegrationTests
```

This test connects only to `127.0.0.1:49326` and uses the current macOS user and that test directory's `client_key`. The prerequisite is that the corresponding sshd is running and that the test service's host key has been checked and trusted in Snake; the test does not automatically accept unknown keys. It creates an independent SQLite/UserDefaults store and a random test subdirectory, does not overwrite the user's session configuration, and on completion cleans up only the test subdirectory it created.

The integration test has verified real SSH/SFTP: Chinese file names, hierarchical directories, empty folders, zero-byte files, 4 concurrent chunks (the test temporarily lowers the threshold to 1 MiB), the terminal's real OSC 7 and `cd`, receiving after moving to another window, directory changes after a drop, and safe overwrite, comparing the uploaded result byte by byte.

## Packaged GUI Manual Acceptance Checklist

The automated tests exercise the real AppKit drag-and-drop destination and the real SSH/SFTP path, but they are not equivalent to a real cross-application Finder mouse drag. After repackaging the app, re-test each of the following:

- Drag a single Finder file, multiple files and a folder respectively to the terminal text area, the terminal blank area, an SFTP file row and the SFTP blank area.
- The drag hint appears with the correct path; after the drop, progress is visible and the file really exists when finished.
- Move the window, split left/right and top/bottom, drag a tab out into a standalone window, and upload repeatedly after merging.
- Tab reordering/edge splitting, SFTP remote mutual transfer, and window title-bar dragging are not intercepted by the Finder receiving logic.
- After cancelling with Escape, terminal text can be selected normally, commands can be entered and the next file drag can be started.
- Multi-display, light/dark and system permission-prompt scenarios.

A real cross-application mouse drag could not be completed reliably by automation this round, so it is not marked as passed. The debug app uses a local ad-hoc signature and does not represent a Developer ID notarized release.

### 2026-09-09 Acceptance Record

- Swift: 41 tests passed, including a real local SSH/SFTP transfer integration test.
- Bonsplit: 12 passed; Rust: 15 passed.
- The packaged app can connect to the isolated local SSH; after running `cd` in the GUI the connection band updates to the target directory.
- Automated native sidebar dragging triggered the source's start/end and preview, but the destination `draggingEntered` / `performDragOperation` was not observed, no tab was created, and it **did not pass**.
- After placing Finder and Snake side by side, a cross-application test-file drag was performed but no upload record was observed; it **did not pass**. It has not yet been proven whether this is a problem in the app's receiving path or a limitation of the automated gesture.
- The next step is for a human to re-test sidebar dragging and Finder drag-and-drop in the latest debug build and to locate the issue with the `com.snake.client` / `WorkspaceDrag` logs. Until actual success evidence is obtained, four-direction dragging, real-time Option switching, cross-window merging and Finder upload are not marked as GUI-passed.

### Additional Verification for SFTP Table Receiving

- After completing Finder receiving handling for the SFTP table, 42 Swift tests passed, including shared parsing validation, mixed-payload rejection and split/move-window state preservation.
- The local integration test covers the SFTP table provider entry point: upload a Chinese file name, change the directory during asynchronous parsing, and verify the result in the original drop directory byte by byte.
- The current running window was in a confirmation dialog being operated by the user, so no further window control was performed this time to run human-equivalent cross-application gesture acceptance. The new package is output separately to `.build/sftp-drag-app/Snake.app`; passing tests are not equivalent to completed real Finder gesture acceptance.

### Hint Shown but No Task on Drop: Commit-Stage Diagnosis

- The user's actual drag-and-drop log confirms that the file table recognized `public.file-url` and executed `performDrop` on drop. This time the drag-and-drop event was not entirely unreceived.
- At commit time it branches on the validated drag type and no longer judges whether something is a local file by the number of results from querying the "remote reference provider", preventing Finder files from entering remote-reference handling that would silently ignore parse failures.
- The Finder provider now uses `loadDataRepresentation(public.file-url)` to read the URL bytes and then goes through the shared local URL validation, avoiding the nondeterminism of generic object conversion.
- The `FinderDrop` log records the commit, URL decode success/failure, enqueue and connection-change cancellation stages, and does not record paths, file contents or credentials.
- The 9 upload-related tests (including real local SSH/SFTP) passed; the new debug build is `.build/finder-fix-app/Snake.app`. The actual Finder gesture result still has to be confirmed with this commit's logs and the file results.
