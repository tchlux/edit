# Query Replace And Open Line

Date: 2026-05-14

Implemented Emacs-style open-line and query replace:

- Added `C-o` to insert a newline at point while leaving point before the new
  line.
- Added `M-%` query replace from point to EOF, with separate search and
  replacement prompts.
- Supported replacement loop commands: `Space` accepts the current replacement,
  `n` skips to the next match, and `!` replaces the current and remaining
  matches.
- Reused the existing regex search engine and undo-aware edit history, with
  one undo group per accepted replacement and one group for replace-all.
- Decoded macOS Option `%` UTF-8 bytes `ef ac 81` as `M-%` after keydump
  capture.
- Cleared replacement search highlights when the replacement scan finishes or
  replacement mode is cancelled.
- Updated readme/help/goals and added render/pty regressions for open-line,
  approve, skip, replace-all, read-only rejection, macOS Option `%`, and
  highlight cleanup.

Current verification:

```
./build.sh
sh ./test.sh
```
