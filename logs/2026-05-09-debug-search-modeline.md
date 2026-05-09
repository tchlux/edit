# Debug, Search, And Modeline Milestone

Date: 2026-05-09

Implemented the latest editor polish and debugging work:

- Added filename plus `line:column` cursor position to the modeline.
- Moved built-in key reminders to a separate gray footer row.
- Added `M-n` and `M-p` 10-line movement.
- Added regex-backed `M-f` and `M-b` word movement.
- Added macOS Option-byte decoding for the common Option sequences discovered
  during local terminal testing.
- Added `Esc r` debug recording with raw key bytes, decoded keys, state before
  and after dispatch, terminal dimensions, ANSI render bytes, readable
  snapshots, and a final note prompt.
- Added `keydump.sh` and `keydump.c` to inspect exactly what bytes the terminal
  sends for key combinations.
- Added `C-g` cancellation for partial commands and active search prompts.
- Added repeated `C-s`/`C-r` search navigation, including reverse search with
  `C-r`.
- Updated pty-backed and render-key regression coverage for the new UI,
  movement, debug, and search behavior.

Current verification:

```
sh ./test.sh
git diff --check
```
