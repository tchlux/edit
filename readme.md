<p align="center">
  <h1 align="center"><code>edit</code></h1>
</p>

<p align="center">
A tiny terminal text editor written in C.
<br>
Emacs-like keys, friendly batch commands, and just enough UI to stay out of the way.
</p>

`edit` is a small nano-like editor built directly on C11, libc, and termios.
It is meant to be easy to understand, easy to script, and comfortable for
basic source editing. The interactive editor uses familiar Emacs movement and
editing keys, while the command line interface makes it easy to render, search,
insert, replace, and test files without opening a terminal UI.


## INSTALLATION

Install or update the macOS app in `~/Applications`:

```sh
curl -fsSL https://github.com/tchlux/edit/raw/HEAD/install.sh | sh
```

This builds in a temporary directory, replaces `~/Applications/Edit.app`, and
opens it. If prompted to install Apple's Command Line Tools, finish that
installation and run the command again.

Build the terminal editor and the macOS app bundle:

```sh
sh ./build.sh
```

This produces:

- `./edit`, the terminal editor.
- `Edit.app`, a native macOS wrapper around the same editor.


## QUICK START

Open a file in the terminal:

```sh
./edit file.txt
```

Open the macOS app:

```sh
open Edit.app
```

Opening `Edit.app` without a document starts an unsaved `*scratch*` buffer in
the current directory. You can drag files or directories onto the app, or use
`File > Open...` to open them in app-owned windows. The app is an AppKit shell
with its own Dock icon and menu bar, but
the editor itself still runs in an embedded pseudo-terminal.

The modeline shows the file name and current `line:column`. The row below it
shows built-in key reminders. While help has focus, `Esc` or `C-g` returns
to the buffer it replaced.


## EVERYDAY KEYS

In the key descriptions below, `C-x` means Control-x. Press plain `Esc` before a
key when your terminal does not send Meta or Option key sequences reliably.

### Movement

- `C-l` recenter.
- `C-a` / `C-e` move to line start/end, using the visible row when wrapped.
- `C-v` / `Esc v` move by page.
- `Esc n` / `Esc p` move 10 lines.
- `Esc f` / `Esc b` move by word.
- `Esc <` / `Esc >` move to file start or end.
- `Esc g g` go to a line.

### Search and Replace

- `C-s` search forward.
- `C-r` search backward.
- Repeated `C-s` / `C-r` move to the next or previous match.
- `C-g` cancel the active prompt or search.
- `Esc %` query replace from point to the end of the file.

Search and query replace use regexes. Invalid regex input is searched as
literal text, so `*` finds literal asterisks. During query replace, `Space`
replaces the current match, `n` skips it, and `!` replaces the current and
remaining matches.

### Editing

- `Tab` inserts spaces.
- `C-q` quotes the next key for literal insertion.
- `C-k` cuts to the end of the line.
- `C-o` opens a new line after point.
- `C-t` transposes characters, swapping the preceding pair at line end.
- `C-space` sets the mark.
- `C-x C-p` selects the whole buffer.
- `M-Shift-u` (or `Esc U`) uppercases the word forward from point.
- `C-w` cuts the region.
- `Esc w` copies the region.
- `C-y` pastes the clipboard or kill.
- `Esc y` cycles the previous paste.
- `Esc d` / `Esc Delete` deletes a word.
- `Esc q` fills the current paragraph to column 70.

Large terminal pastes use bracketed paste when available, so pasted text is
inserted as one undoable edit.

### Files, Buffers, and Panes

- `C-x C-f` finds a file.
- `C-x b` rotates buffers.
- `C-x k` kills the current virtual buffer.
- `C-x C-b` shows session buffers.
- `C-x C-s` saves.
- `C-x C-c` quits.
- `C-x 2` splits below.
- `C-x 3` splits right.
- `C-x o` moves to the other pane.
- `C-x 0` closes the current pane.
- `C-x 1` keeps one pane.

In `C-x C-f`, `Tab` shows sorted candidate names while keeping the cursor in
the find prompt. Typing filters the list immediately. Directories appear in
blue with a trailing `/`. When space permits, directories occupy the left
column and files the right; wider panes use two columns for each group, sorted
down each column. `C-x o` or a click focuses the candidates. Move with the usual
keys and press `Enter` to select, or click an entry while the pane is focused.
Selecting a directory refreshes the same pane with its contents and keeps
focus there. Typing returns to the prompt.
`C-g` cancels the find prompt and closes its temporary pane.

`C-x C-f` starts in the current file's parent directory and stores opened files
in `$HOME/.edit/recent`. Set `EDIT_RECENT` to override that path. Clean file
buffers auto-reload when the file changes on disk.

### Undo and Toggles

- `C-/`, `C-_`, or `C-x u` undo.
- `C-x r` redo.
- `C-c C-r` toggles read-only mode.
- `C-c C-w` cycles overflow, character wrap, and word wrap. `.md` and `.txt` files open with word wrap; other files default to overflow.
- In `Edit.app`, `C-x +` increases font size, `C-x _` (Shift-minus) decreases it,
  and `C-x )` (Shift-zero) resets it to 14 points. `C-x =` and `C-x -` also work.
  In a separate terminal, use that terminal’s font controls.
- `C-c x` runs a remembered shell command for the current file.

### Suggested Changes

- `C-c e` starts Suggested Changes mode. The original file is left untouched.
- `C-x C-s` saves the proposed document and comments to `file.edits`.
- `C-c c` comments on the selection, or the current line without a selection.
- `C-c d` deletes the comment nearest the cursor.
- `C-c ]` shows or hides the read-only Suggested Changes buffer on the right.
- `C-x o` focuses it for normal navigation and search. The focused pane controls
  the other pane's scroll position and active change/comment highlight.
- `C-c a` accepts all changes and writes the proposal to the original file.
- `C-c r` rejects all changes and restores the original file.

An existing `file.edits` resumes automatically when its recorded base exactly
matches the original. If the original changed externally, the sidecar is kept
untouched and the editor reports a conflict instead of applying it.


## BATCH USE

`edit` can also work as a tiny file-editing and rendering command:

```sh
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

These commands are useful for tests, debugging, and language-model workflows
where the important thing is to see exactly what the editor would show.


## HIGHLIGHTING

`edit` includes default highlighting for C, shell, Python-ish text, Markdown,
and plain text. Code files color comments, strings, numbers, keywords, types,
builtins, constants, preprocessor lines, decorators, variables, operators,
shell command substitutions, Python triple-quoted strings, and f-string
expressions.

Markdown (`.md`, `.markdown`) and `.txt` files use Markdown highlighting by
default, with document colors for headings, links, URLs,
lists, blockquotes, code spans, code fences, emphasis markers, and TODO-style
labels. See `color-tests/` for sample files.

Use `M-x toggle-syntax-highlighting` and Enter to turn highlighting off or on
for the current buffer. `Esc x` also opens `M-x`. Type a command name, use Tab
to complete it, or press Tab twice to list all matching commands (an empty
prompt lists everything). `C-v` / `M-v` scroll the list; `Esc` or `C-g` cancels
and restores the file. The toggle lasts while the buffer is open.

Set `EDIT_GRAMMAR=path` to fully override highlighting with a line-based
grammar:

```txt
style comment 90
rule comment //.*
word keyword int return static
```


## CUSTOMIZATION

### Spelling

Interactive Edit checks visible prose automatically using an installed `aspell`
binary. It checks `.txt`, `.md`, and `.markdown` prose and source comments and
strings, skipping Markdown code, link destinations, URLs, paths, and technical
tokens containing digits or underscores. Checks run asynchronously after a
250 ms typing pause. The word being edited stays unmarked until the cursor
leaves it. Spelling remains active when syntax colors are disabled.

Misspellings have red underlines in the Mac app. Other terminals display an
underline; separate underline color depends on terminal support.

- `M-x toggle-spell-checking` toggles checking for the current buffer.
- `M-$` (`M-x spell-correct-word`) offers up to nine suggestions for the word at or
  immediately before the cursor in a temporary bottom pane. Choose with arrows and Enter, or a number;
  `i` permanently adds the word to your personal dictionary, as in Emacs;
  `Esc`/`C-g` cancels. Corrections are undoable and respect Suggested mode.
- `M-x spell-add-word` accepts the word permanently and verifies it was saved
  to the personal dictionary. Existing dictionary symlinks are preserved.

Right-click a word in the Mac app to choose an Aspell correction from the
native context menu, or choose **Add word** to save it to your personal
dictionary. Add word is also available when there are no suggestions. Existing comment actions remain available below it.
In terminals that forward mouse events, right-click opens the numbered
bottom preview while keeping the source visible. `C-x o` or a click switches
between panes; `Esc`/`C-g` or a replacement closes the preview and restores
the original layout. `M-x spell-correct-word` uses the same preview in both
interfaces.

Edit looks for Aspell on `PATH`, then `/opt/homebrew/bin/aspell` and
`/usr/local/bin/aspell`. Install it separately, for example with
`brew install aspell`. If unavailable, editing continues; toggle checking off
and on to retry after fixing a checker or dictionary error.

The default language is `en_US`. For English, Edit reuses `~/.aspell.en.pws`
when readable, including an existing Emacs dictionary; otherwise it uses
Aspell's configured personal dictionary. Optional environment overrides:

```sh
EDIT_ASPELL=/path/to/aspell
EDIT_SPELL_LANGUAGE=en_GB
EDIT_SPELL_DICTIONARY=/absolute/path/to/personal.pws
```

Custom grammar rules with scope `comment` or `string` identify prose too.
The built-in lexical scanner handles C-style block comments, Python multiline
strings, shell substitutions, and Fortran comments; it is not a full language
parser. Batch rendering commands do not start a spell checker.

### Editing

Literal tabs display at width 3 by default. Set `EDIT_TAB_WIDTH` to another
positive integer to change that. Pressing `Tab` inserts spaces, using 2 spaces
for JavaScript and CSS files; press `C-q Tab` for a literal tab byte.

On macOS, Option may enter Unicode or dead-key accents instead of Meta
commands. `edit` decodes known Option bytes for `f`, `b`, `d`, `w`, `v`, `n`,
`p`, `r`, `<`, `>`, and `%`, but plain `Esc` is the most reliable command
prefix.


## DEBUGGING

Record a UI log from inside the editor:

```txt
Esc r
```

Recording continues until the next plain `Esc`, then prompts for a note.

Render a terminal view without opening the editor:

```sh
python3 ./tui_view.py 10:80 '<down><right>' file.txt
```

Inspect raw key bytes from your terminal:

```sh
./keydump.sh
```
