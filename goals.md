# Goals

Completed work:

- First editor baseline: gap buffer, Emacs-like movement/editing, batch edit
  commands, pty-backed TUI tests, and simple grammar highlighting.
- Editing safety: rendered status messages, temp-file save flow, dirty-file
  quit protection, and regression coverage.
- Regex-backed search: explicit byte cursor semantics, batch `--search`,
  interactive `C-s` forward search, and render/debug coverage.
- Syntax highlighting: default C-like grammar, custom grammar override, word
  rules, multi-span line rendering, and raw color render coverage.
- Page navigation: Emacs-style `C-v` page down and `M-v` page up, with batch
  and pty regression coverage.
- Emacs-style undo: append-only edit history, undoable inserts/deletes, no
  discarded redo branch after typing following undo, and regression coverage.
- Split panes: Emacs-style stacked/side-by-side panes sharing one buffer,
  independent cursors/viewports, pane switching/closing, and regression
  coverage.

Outstanding work for `edit`:

- Add recent-file history and fast file reopening.
- Improve large-file handling beyond a whole-file gap buffer, likely with a
  piece table or paged backing store.
- Keep language-model usability first-class through reliable batch commands and
  render/debug commands.
