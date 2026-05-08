# Split Panes Milestone

Date: 2026-05-08

Implemented Emacs-style panes:

- Added `C-x 2` to split the current pane below.
- Added `C-x 3` to split panes side by side.
- Added `C-x o` to cycle panes, `C-x 0` to close one pane, and `C-x 1` to keep
  only the active pane.
- Added `C-l` to cycle the active pane view between centered, top, and bottom
  cursor placement.
- Kept panes on the same buffer while preserving independent cursors and
  viewports.
- Adjusted sibling pane cursors/viewports when shared-buffer edits move byte
  offsets.
- Extended render-key regressions for split, switch, edit, undo, close, and
  one-pane behavior.

Current verification:

```
sh ./test.sh
```
