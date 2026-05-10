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
- Added `--render-keys-color` to regression-test color output after simulated
  key input.
- Updated README and goals to document the completed behavior.

Current verification:

```
sh ./test.sh
git diff --check
```
