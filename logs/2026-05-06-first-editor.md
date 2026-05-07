# First Editor Baseline

Date: 2026-05-06

Built the first material version of `edit`, a small C11 terminal editor with:

- `edit.c`: gap-buffer core, Emacs-like movement/edit command table, raw TUI,
  batch edit commands, and debug render commands.
- `grammar.c` / `grammar.h`: simple native grammar loader that uses the local
  regex engine for visible-line highlighting.
- `regex.c`: symlink to `/Users/thomaslux/Git/regex/regex/regex.c`.
- `build.sh`: C11 warning-clean build command.
- `test.sh`: CLI, render snapshot, escape-sequence, and pty TUI regression tests.
- `tui_view.py`: pty-backed terminal screen decoder for seeing real TUI output
  and cursor position.

Important fixes made during this baseline:

- Cursor state is separate from gap-buffer storage; navigation does not move the
  gap.
- Arrow-key parsing supports normal, application-cursor, and longer CSI forms.
- Rendering avoids terminal autowrap by not writing body/status text into the
  final terminal column.
- Vertical movement preserves cursor positions correctly, including end-of-line
  positions.

Current verification:

```
sh ./build.sh
sh ./test.sh
```
