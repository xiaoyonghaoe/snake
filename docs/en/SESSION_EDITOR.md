[简体中文](../SESSION_EDITOR.md) · **English**

# Compact Session Editor

## Layout

- The edit sheet is 840×600pt; the title area is 60pt, the bottom is 56pt, and the horizontal margin is 20pt.
- The left column is 188pt wide and contains an 88pt avatar, a single row of four preset icons, the full "Choose Photo…"/"Choose Another Photo…" buttons and handshake feedback. The button labels have a fixed content width while the outer container takes the remaining width, so the margins do not squeeze the text.
- The right column is laid out as two columns for session name / tag, host / port, and username / authentication method; the private-key chooser is a conditional row, and the password / passphrase and the reveal button share one row. Controls are about 32pt with 12pt row spacing.
- It reuses Snake's existing SF system font and light/dark tokens; addresses, ports, passwords and fingerprints use a monospaced font. No decorative cards are added.
- Regular content is laid out as a single page; the two columns keep content-driven scrolling as a fallback. Long test information scrolls in the 112pt detail area on the left and does not push the form or the bottom action buttons.

## Password

- `CredentialRevealController` holds the in-memory draft, the user-modified flag and the reveal authorization. After successful authentication, it reads the credential back and fills it in only when there is no draft; if a draft exists, it only authorizes displaying the original input.
- Read-back does not set the modified flag; `valueToSave` returns only a non-empty draft that the user actively modified. An empty value keeps the existing retain-old-credential semantics and does not mean deleting the password.
- After 30 seconds, a manual hide, loss of focus or return from the background, the dots are restored and the draft is not lost. Revealing again performs system authentication again.
- Closing the form or switching the authentication method clears the draft, the modified flag and the authorization, and invalidates late callbacks. Switching the authentication method does not carry the original password reference into the new private-key-passphrase authentication method.
- It retains the existing protection of synchronous clearing during view destruction and asynchronous UI notification, and does not change the encryption format or the Rust interface.

## Connection Test

- `SessionConnectionTestController` independently maintains the idle/testing/success/failure state and a snapshot of the target; it does not reuse the save form's error variable.
- The test button remains at the bottom left. Below the photo button it shows testing, SSH handshake success or failure, and the host, port, algorithm and fingerprint. It does not verify the account password and does not display "login succeeded".
- A change to the host or port clears the old result and invalidates the request ID; closing the form invalidates it as well. The underlying handshake may complete, but its stale result will not be published to the new target.

## User Acceptance

- Open the editor in the 1024×700 main window and check whether the password and private-key modes in light/dark themes show regular content without scrolling.
- The reveal button fills the value back into the original field; modifying, hiding and revealing again all keep the input, and cancelling the form does not save.
- Check photo selection, choosing another photo and avatar cropping, and confirm that the button text is not truncated.
- Click the test button at the bottom and confirm that the result appears only below the photo button; a long fingerprint can be viewed in full and a test failure does not crowd the form.
- While a test is running, change the target, cancel editing or switch the authentication method, and confirm that no stale result, incorrect read-back or save crash occurs.

The pages and system authentication are accepted by the user; automation uses only mock authentication, test credentials and handshake results, and does not launch the user's app or read real secrets.

## Automation and Delivery Record

- 2026-09-12: 29 tests related to credentials and handshake state passed; of 91 total, 88 passed, 2 local-service integration tests were skipped, and 1 pre-existing mount test failed with `invalidMapping` because it did not bind a session. This round does not modify the mount logic.
- Built `.build/session-editor-compact-app/Snake.app`; awaiting the user's acceptance of the pages described above.
