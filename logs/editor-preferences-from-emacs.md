# Editor Preferences

Extracted from `~/Sync/.emacs`. This lists active preferred behaviors, not old commented-out experiments.

## Core Behavior

- Hide the startup screen.
- Keep personal keybindings in a high-priority minor mode so major modes rarely override them.
- Disable that custom keybinding mode in the minibuffer.
- Use MELPA Stable as the package archive.
- Load personal Emacs Lisp files from `~/Sync/bin/emacs`.
- On macOS, map Option to Meta and Command to Super.
- Use interactive shells for shell commands so aliases and shell startup files are available.
- Prefer `zsh` on macOS and `bash` elsewhere.
- Set Emacs `PATH` and `PYTHONPATH` explicitly on macOS.

## Editing Defaults

- Truncate long lines by default instead of wrapping them.
- Use spaces for indentation, never tabs.
- Display tabs as width 3.
- Show the current column number.
- Treat camelCase subwords as separate words for movement.
- Enable `narrow-to-region`.
- Automatically reload buffers when files change on disk.
- Store backups in one flat directory: `~/.emacs.d/auto-save-list`.
- Save and restore the editing session across restarts using desktop files in `~/Sync/logs`.
- Ignore transient modes such as LSP and Flycheck when saving desktop sessions.
- Remove stale desktop locks automatically.

## Display

- Use a dark theme: foreground `#E0E0E0`, background `#202020`.
- Use a solid cursor.
- Disable cursor blinking.
- Hide scroll bars, tool bar, and menu bar.
- Show fringe indicators for visually wrapped lines.

## Language And File Modes

- Use `yaml-mode` for `.yml` files.
- Use document editing settings for `.txt` and `.md` files.
- Use TeX document settings for `.tex` files.
- For documents and TeX, enable spelling and visual line mode, and disable auto-fill.
- In document buffers, use `%%` as the comment start marker.
- Use JavaScript indentation level 2.
- Use CSS indentation level 2.
- Keep Python function body indentation at the normal level.

## Diagnostics

- Enable Flycheck globally on macOS.
- Use LSP for Python and Fortran buffers.
- Prefer Flycheck over Flymake for LSP diagnostics.
- Use `pyright` for Python when available.
- Add `~/Sync/bin/python` to Pyright's extra paths.
- Use `python3` as the Pyright Python executable.
- Use Fortran 2008 for gfortran checks.
- Disable the Fortran LSP Flycheck checker.
- Show LSP diagnostics, hover info, code actions, peek, imenu, and doc UI.

## Compilation And Shells

- Default compile command is `python3 `.
- Prompt for compile commands and keep compile history.
- Save compile commands per source filename under `~/.emacs.d/compile-history/`.
- Auto-scroll compilation output.
- Strip problematic `^[[J` and `^[[K` escape sequences from compilation buffers.
- Open `C-c s` shells as `ansi-term` using the current shell.

## Spelling

- Use a machine-specific local aspell binary at `~/Sync/bin/aspell/aspell-<system-name>`.
- Warn if that aspell binary is missing.
- In Flyspell, use right-click for corrections instead of middle-click.

## Movement And Scrolling

- `M-n` moves down 10 lines.
- `M-p` moves up 10 lines.
- Mouse wheel scrolling moves the cursor line-by-line or column-by-column.
- Scrolling recenters gradually once the cursor crosses half the window.
- Horizontal wheel scrolling moves by characters when lines are truncated.

## AI Completion

- `C-c C-c` calls the external `complete` program.
- Completion uses the current file name, top of file, nearby context, cursor marker, and active region if present.
- If a region is active, completion is treated as a replacement for that region.
- Generated text streams directly into the buffer.
- Any user action cancels generation.
- The prompt asks for minimal code that matches local style and returns code only.

## Code Insertion Helpers

- `C-c i` inserts an empty language-aware print statement.
- `C-c e` inserts a language-aware error/debug print with buffer name and line number.
- `C-c v` prompts for a variable and inserts a language-aware variable print.
- `C-c b` inserts `import pdb; pdb.set_trace()`.
- `C-c p` inserts a Python `pprofile` timing scaffold.
- Print helpers support Python, JavaScript, C, C++, and Fortran.

## Region And Text Helpers

- `C-c h` hides the selected region.
- `C-c u` unhides the most recent hidden region.
- `C-c d` moves the selected region to the end of the file inside a dated comment box.
- `C-c k` deletes text between adjacent words and replaces it with one space.
- `C-c a` runs `align-regexp`.
- `C-c c` prompts for buffer-local comment start and end strings.

## Toggles And Commands

| Key | Behavior |
| --- | --- |
| `C-c C-r` | Toggle read-only mode. |
| `C-c C-i` | Toggle `comint-mode`. |
| `C-c C-f` | Open file literally. |
| `C-c C-s` | Toggle Flyspell. |
| `C-c C-w` | Toggle visual line mode. |
| `C-c C-a` | Toggle auto-fill mode. |
| `C-c x` | Compile with per-file command history. |
| `C-c f` | Run `frex` in a compilation buffer. |
| `C-c r` | Reload `~/Sync/.emacs`. |
