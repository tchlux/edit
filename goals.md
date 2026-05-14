# Goals

Completed work:

- First editor baseline: gap buffer, Emacs-like movement/editing, batch edit
  commands, pty-backed TUI tests, and simple grammar highlighting.
- Editing safety: rendered status messages, temp-file save flow, dirty-file
  quit protection, and regression coverage.
- Regex-backed search: explicit byte cursor semantics, batch `--search`,
  interactive `C-s` forward search, `C-r` reverse search, repeated next/previous
  match navigation, `C-g` cancel, and render/debug coverage.
- Syntax highlighting: default C-like grammar, custom grammar override, word
  rules, multi-span line rendering, and raw color render coverage.
- Page navigation: Emacs-style `C-v` page down and `M-v` page up, with batch
  and pty regression coverage.
- Emacs-style undo: append-only edit history, undoable inserts/deletes, no
  discarded redo branch after typing following undo, and regression coverage.
- Split panes: Emacs-style stacked/side-by-side panes sharing one buffer,
  independent cursors/viewports, pane switching/closing, and regression
  coverage.
- Modeline and movement polish: filename plus cursor `line:column`, separate
  keymap reminder row, `M-n`/`M-p` 10-line movement, and regex-backed
  `M-f`/`M-b` word movement plus `M-d`/`M-DEL` word deletion.
- Debug tooling: `Esc r` TUI recording with terminal size, raw key bytes,
  decoded keys, state snapshots, ANSI render bytes, and final user note; plus a
  standalone `keydump.sh` terminal byte inspector for macOS Option diagnosis.
- Recent files: `C-x C-f` find-file prompt, fast reopen of the most recent
  different file, and global `$HOME/.edit/recent` history with `EDIT_RECENT`
  override for tests/debugging.
- Configurable tab display and insertion: literal tabs render at
  `EDIT_TAB_WIDTH` columns with a default of 3, `Tab` inserts spaces, and
  `C-q Tab` inserts a literal tab.
- Search highlighting: visible forward/reverse search matches are highlighted
  in the current view, with the current match emphasized.
- Query replace and open-line: `M-%` prompts for search/replacement text,
  supports per-match approve/skip/replace-all from point to EOF, clears
  highlights when done, and `C-o` opens a line without moving point.
- Robust large paste handling: bracketed paste is buffered into one insert and
  one undo group, with newline normalization, UTF-8 preservation, and pty
  regression coverage.
- Document highlighting: extension-aware Markdown and plain-text default colors
  for headings, links, URLs, lists, quotes, code spans/fences, emphasis markers,
  and TODO-style labels, with demo files and render-color coverage.
- Customization polish: read-only toggle, dark interactive theme with solid
  cursor, clean-buffer auto-reload, JavaScript/CSS two-space Tab insertion,
  camelCase word movement, and `M-q` paragraph filling to column 70.

Outstanding work for `edit`:

- Improve large-file handling beyond a whole-file gap buffer, likely with a
  piece table or paged backing store.
- Keep language-model usability first-class through reliable batch commands and
  render/debug commands.

Preferred customization goals:

- Line display: `C-c C-w` toggles visual line wrapping.
- Sessions: save and restore open buffers, cursor state, and window state
  across restarts; remove stale session locks automatically.
- `C-c C-a`: toggle auto-fill mode.
- `C-c C-s`: toggle spellcheck.
- `C-c x`: prompt for a compile command; default to `python3 `; remember the
  command per source filename.
- Compilation output: auto-scroll to the bottom and strip `^[[J` / `^[[K`
  escape junk.
- `C-c s`: open an integrated ANSI shell using the current shell.
- Shell commands: run through interactive shells so aliases work.
- Environment: support explicit `PATH` and `PYTHONPATH` settings. Initial
  values from `.emacs` are `PATH=/Users/thomaslux/Sync/bin:/Users/thomaslux/.local/bin:/opt/homebrew/bin:/opt/homebrew/opt/binutils/bin:/usr/local/bin:/System/Cryptexes/App/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/local/bin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/bin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/appleinternal/bin:/Library/Apple/usr/bin:/usr/local/sbin`
  and `PYTHONPATH=/Users/thomaslux/Sync/bin/python:/Users/thomaslux/Library/Python/3.12/lib/python/site-packages`.
- Mouse wheel up/down: move the cursor line-by-line.
- Mouse wheel left/right: move the cursor by characters.
- Scrolling: gradually recenter once the cursor crosses half the window.
- `C-c c`: prompt for buffer-local `comment-start` and `comment-end`.
- `C-c i`: insert an empty language-aware print statement.
- `C-c e`: insert a language-aware debug/error print with file and line
  context.
- `C-c v`: prompt for a variable and insert a language-aware variable print.
- Print helpers: support Python, JavaScript, C, C++, and Fortran forms.
- Spelling: use right-click (`mouse-3`) for corrections.
- Spelling: use local aspell binaries at
  `~/Sync/bin/aspell/aspell-<system-name>`.
- macOS modifiers: map Command to Super and improve terminal-level Meta
  behavior where the terminal actually sends Meta bytes.
- `C-c C-c`: stream AI completion into the buffer at the cursor.
- AI completion: cancel on any user action.
- AI completion: build prompts from nearby file context and the current file
  name.
- AI completion: treat an active region as replacement input.
- AI completion: request minimal code only, with no explanation or formatting.
