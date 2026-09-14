[简体中文](../SFTP_DOWNLOAD_INTEGRITY.md) · **English**

# SFTP Download and Transfer Integrity Verification

## Usage

- Right-click "Download…" on a file or folder, with Command/Shift multi-selection. Choose the local save directory first, then start the task; cancelling the selection transfers nothing.
- Folders preserve the top-level directory, hidden files, subdirectories and empty folders. Selecting a parent directory and its children repeatedly downloads them only once.
- Symbolic links preserve the original link target and are not followed, so they may remain dangling after download; special device files are skipped.
- Files and chunks share the per-batch concurrency limit. The settings reuse the original parameters: by default, files over 50 MB use 4 independent SFTP connections for chunking; small files are processed in batches by the concurrency count.
- Uploads and downloads share the original compact bottom entry, and clicking it shows the current tab's records. A record shows direction, both paths, elapsed time, transfer status and verification status; when there are no records no persistent bar is added.
- Name conflicts first ask to overwrite/skip/cancel, and the choice can be applied to the current batch. Directory merging does not delete extra files. Failed and cancelled downloads can be retried; a retry downloads again from the new source version and does not automatically resume across launches.

## Verification Rules

1. Probe for remote SHA-256: `sha256sum`, `shasum -a 256`, `openssl dgst -sha256`.
2. When unavailable, probe for MD5: `md5sum`, `md5 -q`, `openssl dgst -md5`.
3. Both uploads and downloads prioritize completing the transfer. When neither algorithm is available, the server allows only SFTP, capability probing fails, the digest command fails or the digest cannot be parsed, verification is skipped and the file is still published, and the record shows "not verified" with the reason. **The remote file is not read back and no extra copy is downloaded to compute a checksum.**

Locally, CryptoKit is used to stream-compute the corresponding algorithm with a buffer of about 1 MiB; MD5 is used only to detect accidental corruption and is not a guarantee against malicious tampering.

After the transfer reaches 100% it enters the verification stage and is marked "verified" only after passing; when verification cannot be completed, an orange "not verified" hint is used and the task is not marked as failed. If the digests already computed by both sides clearly disagree, the file is still considered possibly corrupted: the staged file is not published and the old file is not overwritten. Cancellation and actual read/write errors are not ignored because of the optional verification policy.

A change in the size or modification time of the source file during scanning/transfer/verification causes a failure. The hash comparison guarantees that the content of this transfer is consistent, not that the file cannot be modified afterwards by another program. Directories and symbolic links record their creation result and link-target check separately and are not disguised as file-content hash verification.

## Implementation and Security Boundaries

- Rust provides range download, remote metadata, controlled-command digest, staging merge and publish interfaces; Swift coordinates batches, concurrency, records and local digests. The existing `LocalUploadCoordinator`/`SFTPUploadRecord` names are kept for compatibility with existing callers, and records gain a download direction and an independent verification status.
- Downloads use the opened directory descriptor to `openat(O_NOFOLLOW)` layer by layer, and temporary files are created with `O_EXCL`. Rust clones the staging descriptor held by Swift and uses positional writes; different chunks do not share a seek offset. Publishing uses `renameatx_np` in the same directory, and non-overwrite mode uses `RENAME_EXCL`.
- Therefore an existing local symbolic link cannot redirect writes outside the download directory; a failure/cancellation deletes this managed download's temporary files, the original target is unchanged, and the user's directory is not deleted.
- Ordinary uploads still use independent chunked resume: merge into a hidden staging file → verify → `mv` to publish. A verification failure clears this run's chunks and staging file, and a retry does not reuse corrupted chunks.
- When only SFTP is allowed or capability probing fails, it does not rely on `cat`/`mv`: it uses an independent connection to write disjoint ranges into the same newly created staging file and publishes through an SFTP rename. Overwriting requires the server to support atomic rename, otherwise it fails without first deleting the original target. This compatibility path supports pause/resume, and a failed retry re-uploads rather than reusing hidden chunks.
- The verification command runs only through the exec channel of an independent connection and does not feed commands to the terminal; paths use shell single quotes and stdin redirection, output is bounded and the digest is parsed strictly. Waiting for the remote command is cancellable; pausing stops the client from advancing further and does not promise to pause a hash process already started on the server.
- sshd parses exec commands with the account's login Shell; the original direct POSIX probe script would be rejected by fish. Now probing, digest, merge and publish commands are all executed through a safely quoted `/bin/sh -c`, keeping quotes, backslashes, dollar signs and backticks in paths as literal content. The user's Shell configuration is not modified; if execution is still impossible it is marked not verified per the policy above.
- Records are kept only for the lifetime of the current tab and no database table is added; the existing remote-to-remote copy and double-click-to-download-then-open flows are unchanged. After closing a tab, background tasks that need no interaction continue; tasks that later need conflict confirmation are cancelled, avoiding a background wait forever on an invisible dialog.

## Verification and Reproduction

```sh
cargo test --manifest-path Rust/snake_core/Cargo.toml
swift test --disable-sandbox --filter 'TransferIntegrityTests|SFTPDirectoryDestinationTests|UploadActivityTests'
docker build -t snake-transfer-test:local scripts/transfer-fixture
docker run --rm -d --name snake-transfer-fixture -p 127.0.0.1::22 snake-transfer-test:local
docker port snake-transfer-fixture 22
# Use the local port returned by the previous command:
SNAKE_TRANSFER_TEST_PORT=<port> swift test --disable-sandbox --filter SFTPDownloadIntegrationTests
docker stop snake-transfer-fixture
```

The test account and password exist only in the local isolated container fixture and must not be used for production deployment. The container does not mount host files, does not use real SSH configuration, credentials or Keychain, and does not change existing services. During the test, source files and the database are created in a temporary local directory and deleted afterwards; the container uses `--rm`, and its test data is destroyed after stopping.

Automated coverage: SHA-256/MD5/missing tools/SFTP-only, fish/zsh login Shells, abnormal probe output, digest command failure, chunk and size boundaries, multiple files and empty directories, Chinese quotes and Shell special-character paths, symbolic links, local out-of-bounds protection, overwrite protection, digest mismatch, pause/resume/cancel, and source-file changes. Page, Finder and real-server GUI operations are accepted by the user; isolated interface tests do not replace GUI acceptance.

## Acceptance Results for This Round (2026-09-13)

- Rust: 20 passed, including executing probes and special-character quoting through the local sh/bash/zsh/fish.
- Full Swift suite: 122 of 125 passed, 2 skipped under environment conditions; the pre-existing `MountOperationsTests.testQuitIsCancelledWhenMountIsBusyOrMountTableCannotBeRead` failed with `invalidMapping`, and the mount logic was not modified.
- Final transfer/verification/Finder parsing/directory snapshot/progress focused run: all 22 passed, 3 of them using a real isolated SSH service.
- Real transfers covered directory upload and download for eight account types: SHA-256, MD5-only, no tools, SFTP-only, fish, zsh, abnormal probing and digest command failure; in the latter four, accounts with a working Shell verified successfully, while the faulty accounts completed the transfer and were marked not verified. Verified symbolic links, chunking, pause/resume/cancel, and that the old files on both ends are not overwritten under an artificially wrong digest.
- Debug build: `.build/download-integrity-app/Snake.app`. UniFFI bindings were regenerated, and the build and `codesign --verify --deep --strict` passed; the signature is the existing temporary signature, not a Developer ID notarized release.
- The app was not launched to run page tests. The isolated container was stopped and automatically deleted after the tests; the `snake-transfer-test:local` image is kept for reproduction.
