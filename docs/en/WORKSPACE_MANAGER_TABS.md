[简体中文](../WORKSPACE_MANAGER_TABS.md) · **English**

# SSH Session Cards and Disk-Mapping Tabs

## Behavior

- Starting a new workspace opens one SSH session tab. Double-clicking the empty tail of the tab bar adds a session page in that pane; the disk-mapping entry at the top right adds a mapping tab.
- The top bar keeps only the Snake logo and disk mapping; new configurations are created on the SSH card page, and standalone windows use the tab context menu or drag-and-drop.
- The "Appearance" page in Settings offers light and dark choices, defaults to light, stores the choice in UserDefaults and syncs it across all windows.
- Search and multi-selected tags belong to the current session tab; Command-T adds a new session page to the current split by default and can be changed in Settings. A newly opened session page focuses search automatically; switching back to an existing tab does not steal focus.
- A card's button, double-click and context-menu connect actions convert the current tab in place. The Bonsplit TabID, WorkspaceTabID, tab order and pane stay unchanged, and repeated clicks do not create a second connection.
- Dragging a card still creates a new connection: a normal drag gives a terminal and Option gives SFTP. Management tabs also support splitting and moving to another window; queries and selection follow the runtime.
- Mapping state and configuration are shared globally, and closing a management tab does not unmount the disk. The management page does not register a Finder upload surface.
- Closing the last tab keeps an empty pane; the red button still keeps the workspace for Dock restoration. Dragging a tab out to create a window does not add an extra session page.

## Implementation Boundaries

The management runtime is not bound to an SSHProfile. connectChooser performs a single in-place conversion with an explicit TabID and the latest configuration, then updates the title and icon with Bonsplit updateTab.
Configuration editing and the disk-mapping sheet belong to the window of the page that initiated the action, and the data still uses the existing storage. Rust, credentials and transfer protocols are unchanged.

## Verification

Automation covers in-place conversion, ID preservation, duplicate-connection rejection, missing configuration, pane targets, management-tab cross-window state, independent search and tab-filter state, the close-empty-pane rule, and regresses the existing drag-and-drop tests.

Additional coverage includes the target pane of a tail double-click, empty-pane and invalid-pane callbacks, dynamic tail width and scroll position after overflow, and appearance saving and reloading. Real mouse double-clicks, dragging and Settings page interaction are still left to the user for acceptance.

As requested by the user, page testing is performed by the user. This round does not automatically operate the app GUI; the key manual checks are: card layout and search focus, both in-place connection conversions, management-page splitting/moving to another window, Finder upload, mapping horizontal scrolling, light/dark themes, closing windows and Dock restoration.
