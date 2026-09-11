# Snake fork notes

Base commit: `77b9ccebf1c6e6533c3df1030b5efa9a3db2f351`.

## 2026-09-10 — trailing tab-bar double click

- Added `onTabBarTrailingDoubleClick(PaneID)` for host-owned new-page actions.
- Measure the tab group separately and fill the remaining scroll viewport with a trailing drop/click view, retaining a 30-point tail when tabs overflow. No click overlay covers existing tabs or empty-pane close controls.
- Only the trailing view recognizes double clicks. Snake opens a chooser in the reported pane; tab dragging and split-tree ownership are unchanged.
- Added width/resize/overflow regression tests. Native mouse interaction acceptance remains with the user. MIT license unchanged.

## 2026-08-27 — external tab drop callback

- Added `BonsplitController.onExternalTabDrop`.
- Added `BonsplitController.onTabContextAction` and a native tab context menu for split, close, close-others, and detach commands. Runtime ownership remains in Snake.
- Added `BonsplitController.onActivePaneChange` so the host can track focus changes produced by tab clicks, content clicks, splits, and internal drag/drop operations.
- The internal tab bar starts a short-lived local/global mouse-up observer when a tab drag begins, then reports the source `TabID`, `PaneID`, and screen coordinate.
- Snake's `WorkspaceWindowCoordinator` performs the two-phase runtime hand-off. Bonsplit retains its unmodified in-window reorder, cross-pane move, split tree, selection, and animation behavior.

The addition is intentionally small and isolated. It is a candidate for an upstream API proposal after interaction testing across displays and Spaces. Bonsplit remains MIT licensed; this file records Snake-specific changes.

## 2026-09-06 — Finder upload coexistence

- Replaced plain-text tab drag payload registration with the process-local `com.snake.workspace-tab` data type. Finder file URLs and Snake remote-file references are not tab payloads.
- Mount the content-edge tab drop layer only while this controller is dragging a tab. The previous permanent transparent layer could intercept embedded AppKit content and external file gestures.
- Keep normal pane focus via a simultaneous content tap gesture; clear the visual drop placeholder when a tab drag ends.
- Clear tab drag state after external drop and Escape cancellation so the edge layer cannot remain over the terminal after a window hand-off.
- Preserve existing split-tree ownership and runtime hand-off behavior. Native Finder receiving/routing remains in Snake, not Bonsplit.
- Added a regression test asserting tab types do not conform to text or file URLs. The original MIT LICENSE remains unchanged.

## 2026-09-08 — host-managed native workspace dragging

- Added opt-in `usesNativeDragRouting`. In this mode tab items, tab bars and pane content expose non-interactive `BonsplitDragRegionView` geometry; the legacy SwiftUI drag/drop layer is disabled. Default upstream-style mode remains available.
- Snake uses AppKit dragging sessions for both existing tabs and sidebar profiles, with its own process-bound transaction validation, destination previews and window hand-off. No sidebar/profile or credential model is added to Bonsplit.
- Added explicit insertion positions to `createTab`, `relocateTab` without changing tab identity, and an `insertFirst` option for left/top splits. A self-edge move can retain the original empty pane.
- Original split node and animation implementation is retained, extending its existing first/second placement behavior. Original MIT license and attribution remain unchanged.
