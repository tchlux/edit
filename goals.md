# Goals

Completed work:

- First editor baseline: gap buffer, Emacs-like movement/editing, batch edit
  commands, pty-backed TUI tests, and simple grammar highlighting.
- Editing safety: rendered status messages, temp-file save flow, dirty-file
  quit protection, and regression coverage.

Outstanding work for `edit`:

- Keep cursor semantics explicit: cursor positions are between bytes, not on
  character cells.
- Add search using the local regex engine.
- Expand syntax highlighting through `grammar.c`, including a small default
  grammar and color config.
- Add multiple buffers and Emacs-style buffer switching.
- Add split panes with shared buffers and independent cursors/viewports.
- Add undo/redo after the buffer mutation model is stable.
- Improve large-file handling beyond a whole-file gap buffer, likely with a
  piece table or paged backing store.
- Keep language-model usability first-class through reliable batch commands and
  render/debug commands.
