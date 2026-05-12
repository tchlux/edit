# Large Paste Handling

- Enabled bracketed paste in the TUI and decode `ESC[200~` / `ESC[201~`
  markers as paste boundaries.
- Added a buffered paste path that inserts the whole paste once, normalizes
  carriage returns to newlines, preserves UTF-8 bytes, and makes the paste one
  undo group.
- Added a small plain-text burst fallback for terminals that do not send
  bracketed paste, while leaving prompts, prefixes, debug recording, and command
  bytes alone.
- Extended `tui_view.py` with bracketed paste tokens and added pty regressions
  for 400-word paste order, newline conversion, undo, and UTF-8 preservation.
