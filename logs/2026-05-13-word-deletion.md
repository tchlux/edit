# Word Deletion

- Added `M-d` delete-next-word and `M-DEL` delete-previous-word commands.
- Reused the existing `M-f`/`M-b` word skip logic, including punctuation skips,
  underscore/digit word bytes, and camelCase boundaries.
- Kept word deletes undoable as normal delete edits without adding them to the
  kill ring.
- Decoded macOS Option-d UTF-8 bytes `e2 88 82` as `M-d`, matching the
  existing Option mappings for Meta movement keys.
- Updated help/readme text and added render/pty regressions for forward delete,
  previous delete, undo, camelCase, `Esc DEL`, and macOS Option-d input.
