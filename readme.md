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
`Esc f`/`Esc b` word movement,
`C-v`/`Esc v` page movement, `Esc n`/`Esc p` move 10 lines,
`C-/` / `C-_` / `C-x u` undo, `C-x 2` split below, `C-x 3` split right,
`C-x o` other pane, `C-x 0` close pane, `C-x 1` one pane, `C-x C-f` find file,
`C-x C-s` save, `C-x C-c` quit. `Esc r` records a debug log until the next
plain `Esc`, then prompts for a note.

`C-x C-f` stores recent files in `$HOME/.edit/recent`; set `EDIT_RECENT` to
override that path.

On macOS, Option may enter Unicode or dead-key accents instead of Meta commands.
Use the literal `Esc` prefix for reliable command input.

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

`edit` has default C-like highlighting for comments, strings, numbers, and a
small keyword set. Set `EDIT_GRAMMAR=path` to fully override it with a line
based grammar:

```
style comment 90
rule comment //.*
word keyword int return static
```
