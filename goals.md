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

Preferred customization goals:

- Indentation: use spaces instead of tabs; display literal tabs at width 3.
- Line display: truncate long lines by default; `C-c C-w` toggles visual line
  wrapping.
- Status display: show the current cursor column.
- Theme: dark palette with foreground `#E0E0E0` and background `#202020`.
- Cursor: solid and non-blinking.
- JavaScript: indent width 2.
- CSS: indent width 2.
- Files: auto-reload buffers when the file changes on disk.
- Sessions: save and restore open buffers, cursor state, and window state
  across restarts; remove stale session locks automatically.
- `C-c C-r`: toggle read-only mode.
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
- `M-n`: move down 10 lines.
- `M-p`: move up 10 lines.
- Mouse wheel up/down: move the cursor line-by-line.
- Mouse wheel left/right: move the cursor by characters.
- Scrolling: gradually recenter once the cursor crosses half the window.
- Word movement: treat camelCase subwords as separate movement units.
- `C-c c`: prompt for buffer-local `comment-start` and `comment-end`.
- `C-c i`: insert an empty language-aware print statement.
- `C-c e`: insert a language-aware debug/error print with file and line
  context.
- `C-c v`: prompt for a variable and insert a language-aware variable print.
- Print helpers: support Python, JavaScript, C, C++, and Fortran forms.
- Spelling: use right-click (`mouse-3`) for corrections.
- Spelling: use local aspell binaries at
  `~/Sync/bin/aspell/aspell-<system-name>`.
- macOS modifiers: map Option to Meta and Command to Super.
- `C-c C-c`: stream AI completion into the buffer at the cursor.
- AI completion: cancel on any user action.
- AI completion: build prompts from nearby file context and the current file
  name.
- AI completion: treat an active region as replacement input.
- AI completion: request minimal code only, with no explanation or formatting.
