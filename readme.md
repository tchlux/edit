A minimal and highly customizable text editor written in C.

Build:

```
sh ./build.sh
```

Interactive use:

```
./edit file.txt
```

Keys: `C-s` search, `C-v` page down, `M-v` page up, `C-/` / `C-_` /
`C-x u` undo, `C-x C-s` save, `C-x C-c` quit.

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
```

Highlighting:

`edit` has default C-like highlighting for comments, strings, numbers, and a
small keyword set. Set `EDIT_GRAMMAR=path` to fully override it with a line
based grammar:

```
style comment 90
rule comment //.*
word keyword int return static
```
