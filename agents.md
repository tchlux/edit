A minimal and highly customizable text editor written in C.

# style

Build a tiny nano-like editor in C with Emacs keybindings. First scope is
basic character movement only.

Follow `/Users/thomaslux/Git/regex/regex/regex.c`:

- Keep the project small, preferably one clear C file until complexity proves
  otherwise.
- Start C files with a plain comment banner that documents purpose, behavior,
  compilation, and examples when useful.
- Use C11 and libc/termios directly. Avoid frameworks, generated code, and
  portability scaffolding until needed.
- Prefer `#define` constants, simple `typedef struct` records, and direct
  functions over abstractions.
- Use lowercase `snake_case` names. Internal helpers may start with `_`.
- Keep state explicit in local variables or a single editor state struct.
- Put concise comments before non-obvious blocks; make comments describe the
  action that follows.
- Use compact control flow and early returns for errors. Do not add broad edge
  case handling before the editor needs it.
