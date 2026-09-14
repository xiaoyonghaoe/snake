[简体中文](../SFTP_SELECTION.md) · **English**

# SFTP Multi-Selection and the Delete Key

- A single click selects one item, a Command-click adds or removes an item from the selection, and a Shift-click selects the contiguous range from the anchor to the target in the currently displayed order; Command-Shift adds that range to the existing selection.
- Clicking empty space clears the selection. Deleting the selected items from the context menu deletes the whole selected group, whereas the delete action on an unselected item applies only to that item. Other context-menu operations such as Rename and Permissions still target the clicked item.
- Clicking a file row or empty space moves input focus to the file list, and the path field restores the current directory when it loses focus. Delete/Forward Delete requests deletion only when the file list has focus; while the path field is being edited it still deletes text normally.
- The delete dialog captures a snapshot of the targets, shows their count and names together, and warns that the action is unrecoverable. After confirmation the items are deleted serially one by one; directories reuse the existing rm -rf interface, and symbolic links delete only the link itself.
- A failure on one item does not stop the remaining items; when finished the original directory is refreshed, and if the user has already navigated to another directory it does not force a jump back. The failure summary stays visible and is cleared by clicking "OK", and destructive operations are not retried automatically.
- Automation covers selection sets, range anchors, context targets, duplicate/dangerous path filtering and the symbolic-link deletion policy. Real mouse multi-selection, input-field focus and Delete-key interaction are accepted by the user as requested.
