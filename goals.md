# Goals

Outstanding work for `edit`:

- Stabilize the terminal UI around the pty test harness before adding features.
- Keep cursor semantics explicit: cursor positions are between bytes, not on
  character cells.
- Add full file editing basics: safer save flow, dirty-file quit protection, and
  simple status messages that are actually rendered.
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
