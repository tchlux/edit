A minimal and highly customizable text editor written in C.

Build:

```
sh ./build.sh
```

Interactive use:

```
./edit file.txt
```

The modeline shows the file name and current `line:column`; the row below it
shows built-in key reminders.

Keys: `C-l` recenter, `C-s` search forward, `C-r` search backward,
repeated `C-s`/`C-r` next/previous match, `C-g` cancel,
`Esc %` query replace,
`Esc f`/`Esc b` word movement,
`Esc d`/`Esc Delete` word deletion,
`C-v`/`Esc v` page movement, `Esc n`/`Esc p` move 10 lines,
`Esc <`/`Esc >` file start/end, `Esc q` fill paragraph,
`Tab` insert spaces, `C-q` quote the next key for literal insertion,
`C-k` cut to end of line, `C-o` open a new line after point,
`C-space` mark, `C-w` cut region, `Esc w` copy region, `C-y` paste clipboard/kill,
`Esc y` cycle paste,
`C-/` / `C-_` / `C-x u` undo, `C-x 2` split below, `C-x 3` split right,
`C-x o` other pane, `C-x 0` close pane, `C-x 1` one pane, `C-x C-f` find file,
`C-x b` rotate buffers, `C-x k` kill the current virtual buffer,
`C-x C-b` show session buffers,
`C-c C-r` toggle read-only, `C-x C-s` save, `C-x C-c` quit. `Esc r` records a debug log until the next
plain `Esc`, then prompts for a note.

Search and query replace use regexes, with invalid regex input searched as
literal text, so `*` finds literal asterisks. `Esc %` prompts for a search term and replacement, then reviews matches from
point to the end of the file. In the replacement loop, `Space` replaces the
current match, `n` skips it, and `!` replaces the current and remaining
matches. Replacement highlights clear when the scan finishes.

`C-x C-f` starts at the current file's parent directory and stores opened files
in `$HOME/.edit/recent`; set `EDIT_RECENT` to override that path. Open files
are tracked as virtual session buffers; killing the last file switches to an
in-memory `*scratch*` buffer.

Literal tabs display at width 3 by default; set `EDIT_TAB_WIDTH` to another
positive integer. Pressing `Tab` inserts spaces, using 2 spaces for JavaScript
and CSS files; press `C-q Tab` for a literal tab byte.

Clean file buffers auto-reload when the file changes on disk. `Esc q` fills the
current paragraph to column 70.

Large terminal pastes use bracketed paste when available, so pasted text is
buffered and inserted as one undoable edit instead of many per-key edits.

On macOS, Option may enter Unicode or dead-key accents instead of Meta commands.
`edit` decodes known Option bytes for `f`, `b`, `d`, `w`, `v`, `n`, `p`, `r`, `<`,
`>`, and `%`; use the literal `Esc` prefix for reliable command input.

Batch use:

```
./edit --print 1:1..2:1 file.txt
./edit --insert 1:1 "text" file.txt
./edit --delete 1:1..1:5 file.txt
./edit --replace 1:1..1:5 "text" file.txt
./edit --search 1:1 "regex" file.txt
./edit --render 10:80 file.txt
./edit --render-at 10:80 2:1 file.txt
./edit --render-keys 10:80 nf file.txt
./edit --render-keys-color 10:80 nf file.txt
./edit --render-color 10:80 file.txt
```

TUI debug:

```
python3 ./tui_view.py 10:80 '<down><right>' file.txt
./keydump.sh
```

`Esc r` starts a detailed UI recording and saves a local debug log after the
next plain `Esc` and note prompt. `./keydump.sh` prints raw key bytes from the
terminal for modifier/debugging work.

Highlighting:

`edit` has default highlighting for C, shell, Python-ish text, Markdown, and
plain text. Code files color comments, strings, numbers, keywords, types,
builtins, constants, preprocessor lines, decorators, variables, operators, shell
command substitutions, and Python triple-quoted strings and f-string
expressions. `.md`, `.markdown`, and `.txt` files use document colors for
headings, links, URLs, lists, blockquotes, code spans/fences, emphasis markers,
and TODO-style labels. See `color-tests/` for sample files.
Set `EDIT_GRAMMAR=path` to fully override it with a line based grammar:

```
style comment 90
rule comment //.*
word keyword int return static
```
