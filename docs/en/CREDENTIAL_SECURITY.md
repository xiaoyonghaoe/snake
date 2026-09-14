[简体中文](../CREDENTIAL_SECURITY.md) · **English**

# Credential Encryption and Authenticated Reveal

## Storage and Migration

- `CredentialStore.save/readData/delete` remain the calling interface. Terminals, SFTP, uploads and other callers do not need to perform LocalAuthentication for ordinary connections.
- The entire account-to-secret dictionary is encrypted with CryptoKit AES-256-GCM, and the on-disk format is `{"version":1,"sealedBox":"<Base64>"}`. The combined sealed box contains the random nonce, ciphertext and authentication tag; the fixed AAD is `com.snake.credentials:v1:AES-256-GCM`. Every write uses a new random nonce.
- The 256-bit random key is stored in a generic-password Keychain item: service `com.snake.credentials.encryption`, account `master-key-v1`, `WhenUnlockedThisDeviceOnly`, synchronization off, with no ACL requiring a fingerprint on every connection. The key is not stored in configuration, the database or the binary.
- `~/Library/Application Support/Snake/credentials.json` keeps its original path; the parent directory is `0700` and the file `0600`. A storage lock serializes reads and writes; the temporary file contains only ciphertext, is verified by decryption and then atomically replaced, and a failed attempt cleans up the temporary ciphertext.
- Startup initialization, reads, saves and deletes all check the format. Old `[String:String]` plaintext files are migrated wholesale, including other sessions not connected in this run; when there is no credential file, startup does not create a key or an empty file. A migration failure notifies the user and keeps the original file, does not fall back to plaintext and does not make a plaintext backup.
- The old `com.snake.ssh.credentials` entry is read for compatibility only when the new store has no corresponding account; after a successful read it is written to the encrypted file and the old entry is kept. Deleting a credential also deletes the corresponding old entry, preventing the compatibility path from restoring a deleted credential. The old debug plaintext cache is removed.
- Unsupported versions, ciphertext authentication failures, Keychain access failures or a missing key all stop reads and writes. When ciphertext already exists, a replacement key is never created automatically.

## Authentication and UI

- "Reveal/Hide" is provided next to the original password and private-key-passphrase input fields; it is disabled when there is neither a draft nor a saved reference. After entering a password for a new session, the current draft can also be revealed by authenticating.
- Each reveal creates a new `LAContext`, with the reuse duration set to 0, using the system `deviceOwnerAuthentication`. The system provides Touch ID, the Mac login password and possibly a configured Apple Watch; Snake does not collect, receive or store the system password.
- After authentication succeeds and the source window is still in the foreground, the saved value is read when there is no draft, filled back into the original field and made editable; when input already exists, only the current draft is displayed and the old value is not read to overwrite it. Read-back and user editing are distinguished, and revealing alone does not trigger a credential write-back. Leaving the password input empty still keeps the original credential.
- Plaintext is shown for at most 30 seconds. Manual hiding, window focus loss or the app entering the background restores the dots and keeps the in-memory draft; only closing the form or switching the authentication method clears the draft and the reveal authorization. The system authentication panel and Keychain access authorization may temporarily steal focus; after authentication/read completes it waits at most 1.5 seconds for the original window to become visible again, the app to activate and input focus to return, and confirms again across different main-queue turns. If focus is not restored it gives a clear notice, and does not silently hide, force window activation or skip authentication.
- Each operation holds an independent request ID. After closing, switching or hiding, late authentication/decryption callbacks are all invalid. Cancelling authentication does not report an error, and unavailable/failed authentication has a clear message with no bypass provided.
- It does not automatically write to the clipboard, logs or persistent UI state. An authorized plaintext input field supports the standard text-editing operations. Swift strings and framework-internal copies cannot be guaranteed to be zeroed byte by byte; hiding only revokes the visible state and does not promise to erase the editing draft.
- `CredentialRevealController` separates secret storage from UI notification: ordinary updates are coalesced into the next main-queue execution, and when a native view is destroyed it synchronously clears the plaintext and cancels requests and timers, but no longer notifies the SwiftUI graph being destroyed. Different native observing views have independent IDs, so tearing down an old observing view does not affect a replacement view.

## Boundaries and Operations

- The protection target is credentials at rest on disk and reveal through the normal UI. Allowing automatic decryption for connections means it is not a security isolation boundary against a process that already controls the current user.
- Development builds are ad-hoc signed; after an update the system may request Keychain access approval again, which is distinct from the authentication performed when revealing plaintext. A formal release requires a stable Developer ID signature; do not bypass approval by relaxing access to any application.
- The key and the encrypted file must be paired. If the key is lost, first restore the original Keychain; if it cannot be restored, the original ciphertext must be manually saved elsewhere and the credentials re-established. This round provides no automatic reset/recovery entry point, to prevent accidental overwriting.
- Atomic migration cannot eliminate historical backups, APFS snapshots, historical SSD blocks or plaintext already held in process memory by an old app. After migrating, do not run an old plaintext-store app at the same time.
- No new Rust API, database migration, private-key file copying or password-tool integration is added.

## Acceptance

Automation uses only temporary directories, test-generated keys and mock authentication, and does not access the user's real credentials or display a system authentication prompt:

- Encryption/decryption, random nonces, permissions, reload, delete, full migration and idempotency.
- A failed atomic replacement keeps the original file and cleans up the temporary ciphertext; a missing/wrong key, corrupted format, tampering and an unknown version fail closed.
- Authentication success, failure, cancellation, unavailability, timeout, focus loss, and late callbacks after closing; passwords are not read without authorization.

Page and system verification are performed by the user and cannot yet be replaced by mock tests:

1. Close the old version and open the new package; if the system asks, approve Keychain access for the signed app. After a successful startup migration, existing sessions can still connect.
2. Edit a session with a saved password and private-key passphrase and click reveal; verify Touch ID / Mac password and the cancellation path respectively.
3. First enter a new value that has not been saved, then click reveal; after authentication the original field shows the new value rather than the old password. After closing without saving, the old value on disk is still valid. With no draft, revealing fills back the old value, and revealing without modifying and then saving should not rewrite the credential.
4. After revealing, wait 30 seconds, switch windows, switch to another app, close the form, switch the authentication method; plaintext is no longer shown in any case, and revealing again re-authenticates.
5. In a new session with no password entered the reveal button is unavailable; after entering one, authenticate to reveal the draft; after the password and passphrase are saved encrypted, regress the SSH, SFTP, upload and existing mapping authentication flows.
6. In light/dark themes and the 1024×700 window, check the buttons, long-password horizontal editing, scroll areas and the system authentication prompt.

Sources: [Apple AES.GCM](https://developer.apple.com/documentation/cryptokit/aes/gcm), [Apple deviceOwnerAuthentication](https://developer.apple.com/documentation/localauthentication/lapolicy/deviceownerauthentication).

## Verification Record for This Round (2026-09-12)

- New credential-encryption and authentication-state tests: 15 passed.
- `swift test --disable-sandbox`: 77 tests, 74 passed, 2 integration tests skipped under environment conditions, 1 pre-existing mount test failed. The failure is `MountOperationsTests.testQuitIsCancelledWhenMountIsBusyOrMountTableCannotBeRead`, whose newly created mapping is not bound to a session and triggers the unchanged `invalidMapping` validation in `ApplicationStore.preparedMappings`; neither of these two files was modified this round.
- Debug build: `.build/credential-security-app/Snake.app`, build number `20260912090148`, arm64, ad-hoc signed; `codesign --verify --deep --strict` passed, confirming linkage against Security, LocalAuthentication and CryptoKit.
- The app was not opened, no real system authentication was triggered, and the user's existing credentials were not read or migrated; the real migration runs when the user launches the new package. Page, Touch ID / Mac password and real connection regression await user acceptance.

## Fixes for the Save Crash and the Nothing-Shown-After-Authentication Bug

- The user reported that `20260912090148` crashed after saving. The crash stack is clearly `dismantleNSView → CredentialRevealController.hide → @Published plaintext.setter → SwiftUI GraphHost → swift_beginAccess`: a change is published synchronously during view destruction, triggering a Swift exclusive-access conflict, not an AES encryption/decryption exception.
- The user confirmed that the system authentication prompt appeared but the password was not shown after success. The original code checked input focus immediately when authentication returned and silently called `hide()` on failure; it now waits for the system prompt to hand focus back and provides a notice when focus is not restored, while also handling the case where the parent window of an attached editing sheet is the key window.
- 7 regression tests were added: the actual native teardown entry point does not send UI notifications, a late authentication after teardown does not read credentials, the next main-queue notification is coalesced, the replacement observer is protected, the authentication-prompt/Keychain-authorization focus handoff, and cancellation on close during the focus handoff. All 22 credential-related tests passed.
- The tests only construct non-displayed native observing views, mock authentication and test credentials; they do not open the app or operate the user's authentication prompts. The user needs to focus on re-testing closing the editor after saving, cancelling editing, revealing passwords/passphrases, cancelling authentication, closing the window during a reveal and the 30-second auto-hide.
- The fix build is `.build/credential-reveal-fix-app/Snake.app`, build number `20260912091151`; the build and `codesign --verify --deep --strict` both passed. Of 84 total tests, 81 passed, 2 environment-dependent integration tests were skipped, and the pre-existing unbound-session mount test still failed without modifying the mount logic. This fix does not change the encryption format, the key or the user credential file.
