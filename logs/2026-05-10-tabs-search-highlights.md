# Configurable Tabs And Search Highlights

Date: 2026-05-10

Implemented editor polish for tab handling and search visibility:

- Added `EDIT_TAB_WIDTH`, defaulting to 3, for visual literal-tab rendering.
- Changed normal `Tab` input to insert spaces while preserving find-file
  completion behavior in `C-x C-f`.
- Added `C-q` quoted insertion, including `C-q Tab` for inserting a literal tab
  byte.
- Updated cursor visual-column math so literal tabs occupy configurable screen
  width but still behave as one byte for left/right movement and modeline
  positions.
- Highlighted all visible search matches during forward/reverse search, with a
  brighter style for the current match at the active cursor.
- Made forward/reverse repeated search wrap around the file when no match
  remains in the current direction.
- Added `M-<` and `M->` movement to jump to the beginning and end of the file.
- Added macOS Option byte decoding for `Opt+<` (`c2 af`) and `Opt+>`
  (`cb 98`) after local terminal capture.
- Clamped near-EOF viewports so jumping to the end backfills the window with
  real file lines instead of blank rows.
- Preserved the real EOF cursor position after a trailing newline without
  drawing it on top of the previous line.
- Tuned search highlight colors to use grey backgrounds and clear all search
  highlighting on `C-g` cancel.
- Made the current search match blink between subtle and active styles while
  the TUI is idle, so it draws attention without a harsher static color.
- Added `--render-keys-color` to regression-test color output after simulated
  key input.
- Updated README and goals to document the completed behavior.

Current verification:

```
sh ./test.sh
git diff --check
```
