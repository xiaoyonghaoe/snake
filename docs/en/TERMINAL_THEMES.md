[简体中文](../TERMINAL_THEMES.md) · **English**

# Terminal Themes and Log Keyword Highlighting

> This document records the first implementation. On 2026-09-13 Tokyo Night, output fields and remote file-type colors were expanded; the current settings, defaults and boundaries are governed by [Tokyo Night and Terminal Color Hints](TOKYO_NIGHT_COLORS.md).

## Usage

In "Settings → Terminal", choose "Classic/Vivid", log keyword highlighting and the font and size. The default is Vivid with highlighting on; the color scheme follows the app's light/dark appearance and does not add a follow-system mode. UserDefaults stores the theme and toggles, and existing windows sync immediately.

Classic fully preserves the original ANSI 16 colors. Vivid is based on dark text on a white background and legible text on a dark background, widening the differences among blue, cyan, purple and green. The settings preview uses the same palette and keyword rules and shows directories, ordinary text and the seven levels; it scrolls at large font sizes.

| Level (case-insensitive) | Color |
| --- | --- |
| ERROR, FATAL | Red |
| WARN, WARNING | Orange |
| INFO | Blue |
| DEBUG, TRACE | Purple |

Only complete keywords are matched, so `[ERROR]` and `level=warn` match, while `errorCount`, `information` or fragments joined to Unicode letters/digits/combining marks/underscores do not. Body text is not colored. Command echo on the normal screen may also hit the rules; no remote Shell syntax highlighting is performed.

## Implementation

- `TerminalTheme` = preset + light/dark + highlight toggle. The equality check in `TerminalRuntime.applyTheme` avoids repeated application, and it still uses the original `TerminalView`, SSH handle, screen buffer, selection and scroll position.
- `TerminalLogHighlighter` uses a fixed rule version and caches UTF-16 ranges and levels for the complete text to be drawn; each terminal caches at most 512 lines with FIFO eviction. Changing the theme/toggle creates a new rule instance; content changes, batched arrival, zooming and soft-wrap context changes produce a new cache key, and the historical log is not scanned.
- SwiftTerm's optional drawing callback first builds a UTF-16→column mapping from character widths, then decorates colors in the shared CoreGraphics/Metal line construction. Limited soft-wrap context on both sides prevents false matches of words spanning lines. See `Vendor/SwiftTerm/LOCAL_CHANGES.md`.
- Only the default foreground color can be decorated; remotely specified ANSI/True Color, selection, reverse video and hidden attributes take precedence. The alternate screen (Vim, top, etc.) does not invoke the matcher.
- A settings change triggers a full-screen refresh and Metal dirty-line updates, and existing output is redrawn immediately. Font, cursor and selection colors still go through the original SwiftTerm interfaces.
- Copied content, terminal input/output and the SSH protocol are unchanged; the Rust API, database and remote configuration are not changed, and no dependency is added.

Persistence keys: `com.snake.terminal.theme` (classic/vivid), `com.snake.terminal.log-highlight` (Bool). An unknown preset falls back to Vivid, a missing toggle defaults to on, and an explicit off is restored.

## Automation and Acceptance

Run:

```sh
swift test --disable-sandbox
GITHUB_ACTIONS=true swift test --disable-sandbox --package-path Vendor/SwiftTerm
```

The app tests cover theme completeness, 4.5:1 contrast for body/keywords, settings persistence, boundary/case/Unicode cases, wide and combining characters, batched output, soft wrapping, remote color precedence, selection, the alternate screen, buffer/copy invariance and view identity preservation. The performance test feeds 5,000 log lines, rebuilds ten rounds of visible lines and uses a lenient 15-second regression threshold.

Known independent failure: `MountOperationsTests.testQuitIsCancelledWhenMountIsBusyOrMountTableCannotBeRead`. The new mapping created by the test is not bound to a valid SSH configuration, so `ApplicationStore.preparedMappings` throws `invalidMapping` and the quit check for a busy mount is never reached; this round does not modify that test or the mount logic. The real mount/Finder upload integration tests are skipped under their original conditions.

Results for this round: of 100 app tests, 97 passed, 2 were skipped and the 1 above failed; all 9 new theme-highlighting tests passed. SwiftTerm's 41 XCTest and 376 Swift Testing tests all passed (including 3 new drawing-callback tests). With 5,000 log lines plus ten rounds of visible-line redraw, about 0.16 seconds on this machine; this number is not an actual GUI frame rate or GPU benchmark.

The pages are accepted by the user and were not executed on their behalf: light/dark, Classic/Vivid switching, old output restoration after highlighting is turned off, colored ls, Vim, top, selection copy, scrolling and multiple splits. A side-effect-free example can be run in a connected terminal:

```sh
printf '[ERROR] failed\nlevel=warn retry\nINFO ready\nDEBUG trace\nerrorCount information\n'
printf '\033[32mERROR remote green\033[0m\n'
```

The second ERROR must stay the green specified by the remote. While verifying, switching the color scheme or the toggle should not reconnect, clear output or jump back to the bottom of the scroll. Real GUI/GPU presentation still requires page acceptance; automated line-construction tests are not equivalent to screenshot acceptance.
