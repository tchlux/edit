# Goals

Completed work:

- First editor baseline: gap buffer, Emacs-like movement/editing, batch edit
  commands, pty-backed TUI tests, and simple grammar highlighting.
- Editing safety: rendered status messages, temp-file save flow, dirty-file
  quit protection, and regression coverage.
- Regex-backed search: explicit byte cursor semantics, batch `--search`,
  interactive `C-s` forward search, and render/debug coverage.

Outstanding work for `edit`:

- Expand syntax highlighting through `grammar.c`, including a small default
  grammar and color config.
- Add multiple buffers and Emacs-style buffer switching.
- Add split panes with shared buffers and independent cursors/viewports.
- Add undo/redo after the buffer mutation model is stable.
- Improve large-file handling beyond a whole-file gap buffer, likely with a
  piece table or paged backing store.
- Keep language-model usability first-class through reliable batch commands and
  render/debug commands.
