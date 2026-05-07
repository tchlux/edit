# Syntax Highlighting And Page Navigation

Date: 2026-05-07

Implemented the syntax highlighting milestone:

- Added a default C-like grammar for comments, strings, numbers, and a compact
  keyword set.
- Extended grammar files with `word scope word...` keyword rules.
- Changed line rendering to apply multiple ordered syntax spans.
- Kept `EDIT_GRAMMAR` as a full custom grammar override.
- Added `--render-color` so tests can assert raw ANSI SGR output without
  changing plain render snapshots.

Added Emacs-style page navigation:

- `C-v` pages down by the visible body height.
- `M-v` / `Esc v` pages up by the visible body height.
- Extended `--render-keys` and `tui_view.py` coverage for page movement and
  Meta-v decoding.

Current verification:

```
sh ./test.sh
```
