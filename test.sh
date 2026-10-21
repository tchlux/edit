#!/bin/sh
set -eu

sh ./build.sh

tmp=$(mktemp)
base=${tmp##*/}
out=$(mktemp)
recent=$(mktemp)
dir=$(mktemp -d)
spell_dir=$(mktemp -d)
export EDIT_RECENT="$recent"
clip_has=0
clip_saved=
if command -v pbcopy >/dev/null 2>&1 && command -v pbpaste >/dev/null 2>&1; then
  clip_saved=$(pbpaste 2>/dev/null || true)
  if printf __edit_clip_probe | pbcopy 2>/dev/null &&
     [ "$(pbpaste 2>/dev/null || true)" = "__edit_clip_probe" ]; then
    clip_has=1
  else
    printf '%s' "$clip_saved" | pbcopy 2>/dev/null || true
  fi
fi
cleanup() {
  if [ "$clip_has" = 1 ]; then printf '%s' "$clip_saved" | pbcopy; fi
  rm -rf "$dir" "$spell_dir"
  rm -f "$tmp" "$out" "$recent" "$tmp.grammar" "$tmp.expected" "$tmp.head" "$tmp.debug" "$tmp.debug2" "$tmp.debug3"
}
trap cleanup EXIT

# Exercise native menus without registering a freshly rebuilt app bundle with Launch Services.
cp Edit.app/Contents/MacOS/Edit "$spell_dir/Edit"
"$spell_dir/Edit" --ansi-self-test

# Spelling uses a controllable pipe checker; no test writes the user's dictionaries.
cat > "$spell_dir/fake-aspell" <<'PY'
#!/usr/bin/env python3
import os
import sys
import time

personal = os.environ['EDIT_SPELL_DICTIONARY']
accepted = {'hello', 'spelling', 'don’t', 'café'}
if os.path.exists(personal):
    accepted.update(open(personal, encoding='utf-8').read().splitlines()[1:])
print('@(#) fake Aspell', flush=True)
for line in sys.stdin:
    line = line.rstrip('\n')
    if line == '$$cr personal':
        print(personal, flush=True)
    elif line == '$$cr home-dir':
        print(os.environ['HOME'], flush=True)
    elif line.startswith('*'):
        accepted.add(line[1:])
    elif line == '#':
        if os.environ.get('EDIT_TEST_SAVE_FAIL'):
            print('Error: dictionary cannot be saved', flush=True)
        else:
            with open(personal, 'w', encoding='utf-8') as target:
                target.write('personal_ws-1.1 en 0 utf-8\n' + '\n'.join(sorted(accepted)) + '\n')
    elif line.startswith('^'):
        word = line[1:]
        if word == 'crashword':
            sys.exit(1)
        with open(os.environ['EDIT_TEST_SPELL_LOG'], 'a', encoding='utf-8') as log:
            log.write(word + '\n')
        # Split every response and delay its final bytes to exercise partial reads.
        result = '*\n\n' if word in accepted else ('# ' + word + ' 1\n\n' if word == 'newpersonalword' else '& ' + word + ' 2 1: spelling, spilling\n\n')
        sys.stdout.write(result[:2])
        sys.stdout.flush()
        time.sleep(0.04)
        sys.stdout.write(result[2:])
        sys.stdout.flush()
PY
chmod +x "$spell_dir/fake-aspell"
cat > "$spell_dir/spell-check.c" <<'EOF'
#define main edit_program_main
#include "edit.c"
#undef main
#include <assert.h>

// Drive asynchronous work without making a checker response part of editing.
static void pump(edit_state * e) {
  long long until = now_ms() + 4000;
  do {
    spell_service(e, true);
    if (e->spell.failed) break;
    if (e->spell.header && e->spell.config_stage == 2 && e->spell.pending < 0 &&
        !e->spell.send.len && !e->spell.adding && (!e->spell.choosing || e->spell.preview_pane >= 0)) break;
    nanosleep(&(struct timespec){0, 1000000}, NULL);
  } while (now_ms() < until);
  assert(now_ms() < until);
}

// Compare semantic prose coverage with the same lexical checkpoints used for scrolling.
static void prose(const char * path, const char * text, const char * word, int expected) {
  edit_state e;
  init_state(&e);
  load_grammar(&e);
  e.n_buffers = e.n_panes = 1;
  assert(buffer_set_text(&e.buffers[0], path, BUFFER_FILE, text) == 0);
  const char * at = strstr(text, word);
  assert(at);
  e.panes[0].cursor = (size_t)(at - text);
  assert(spell_target(&e) == expected);
  if (expected) assert(!strcmp(e.spell.word, word));
  buffers_free(&e);
}

// Buffer snapshots contain bytes without a trailing NUL.
static void assert_text(buffer * b, const char * expected) {
  size_t n;
  char * text = buffer_text(b, &n);
  assert(n == strlen(expected) && !memcmp(text, expected, n));
  free(text);
}

static void paint(edit_state * e, output * o) {
  size_t pos = 0;
  e->spell.frame++;
  render_buffer_line(e, o, &e->buffers[0], &e->panes[0], &pos, 0, 100);
}

int main(int argc, char ** argv) {
  assert(argc == 3 || argc == 4);
  assert(setenv("EDIT_ASPELL", argv[1], 1) == 0);
  assert(setenv("EDIT_SPELL_DICTIONARY", argv[2], 1) == 0);
  if (argc == 4) {
    edit_state real;
    init_state(&real); real.spell.live = true; real.n_buffers = real.n_panes = 1;
    real.rows = 24; real.cols = 80; load_grammar(&real);
    buffer_set_text(&real.buffers[0], "notes.txt", BUFFER_FILE, "speling");
    cmd_spell_correct_word(&real, 0); pump(&real);
    assert(!real.spell.failed && real.spell.n_choices && !strcmp(real.spell.choices[0], "spelling"));
    dispatch(&real, '1');
    assert_text(&real.buffers[0], "spelling");
    buffer_set_text(&real.buffers[0], "notes.txt", BUFFER_FILE, "editzzpersonalterm");
    real.panes[0].cursor = 0;
    cmd_spell_add_word(&real, 0); pump(&real);
    assert(!real.spell.failed && strstr(real.status, "saved"));
    struct stat info;
    assert(!lstat(argv[2], &info) && S_ISLNK(info.st_mode));
    buffers_free(&real);
    init_state(&real); real.spell.live = true;
    spell_word * known = spell_lookup(&real, "editzzpersonalterm", strlen("editzzpersonalterm"));
    known->seen = real.spell.frame;
    spell_start(&real); pump(&real); assert(!real.spell.failed && known->result == 1);
    buffers_free(&real);
    puts("real Aspell corrections and dictionary restart ok");
    return 0;
  }
  prose("notes.txt", "speling", "speling", 1);
  prose("notes.md", "# speling", "speling", 1);
  prose("notes.md", "`speling`", "speling", 0);
  prose("notes.md", "```c\nspeling\n```", "speling", 0);
  prose("notes.md", "[speling](url)", "speling", 1);
  prose("notes.md", "[label](speling)", "speling", 0);
  prose("notes.md", "https://speling.example", "speling", 0);
  prose("notes.txt", "/tmp/speling.txt", "speling", 0);
  prose("notes.txt", "speling_42", "speling_42", 0);
  prose("notes.txt", "café—don’t", "café", 1);
  prose("notes.txt", "café—don’t", "don’t", 1);
  prose("x.py", "x = value // speling", "speling", 0);
  prose("x.c", "int speling;", "speling", 0);
  prose("x.c", "// speling", "speling", 1);
  prose("x.c", "//speling", "speling", 1);
  prose("x.c", "/*speling*/", "speling", 1);
  prose("x.py", "#speling", "speling", 1);
  prose("x.c", "/*\nspeling\n*/", "speling", 1);
  prose("x.c", "char *x = \"/*\";\nint speling;", "speling", 0);
  prose("x.py", "# speling", "speling", 1);
  prose("x.py", "x = \"\"\"\nspeling\n\"\"\"", "speling", 1);
  prose("x.py", "x = f\"hello {speling}\"", "speling", 0);
  prose("x.py", "x = f\"speling {value}\"", "speling", 1);
  prose("x.sh", "echo \"speling $(cmd)\"", "speling", 1);
  prose("x.sh", "echo \"hello ${speling}\"", "speling", 0);
  prose("x.f90", "! speling", "speling", 1);
  prose("x.f90", "x = 'speling'", "speling", 1);

  edit_state custom;
  init_state(&custom); custom.n_buffers = custom.n_panes = 1;
  custom.has_grammar = true;
  custom.grammar.n_rules = 2;
  strcpy(custom.grammar.rules[0].scope, "keyword");
  strcpy(custom.grammar.rules[0].regex, "identifier"); custom.grammar.rules[0].word = 1;
  strcpy(custom.grammar.rules[1].scope, "comment");
  strcpy(custom.grammar.rules[1].regex, "speling"); custom.grammar.rules[1].word = 1;
  buffer_set_text(&custom.buffers[0], "custom", BUFFER_FILE, "identifier speling");
  assert(!spell_target(&custom));
  custom.panes[0].cursor = 11;
  assert(spell_target(&custom));
  buffers_free(&custom);

  edit_state e;
  init_state(&e);
  e.rows = 24; e.cols = 80;
  e.n_buffers = e.n_panes = 1;
  e.panes[0].preferred_col = SIZE_MAX;
  e.spell.live = true;
  load_grammar(&e);
  assert(buffer_set_text(&e.buffers[0], "notes.txt", BUFFER_FILE, "speling speling hello") == 0);
  e.buffers[0].edited_ms = 0;
  output o = {0};
  long long begin = now_ms();
  paint(&e, &o);
  assert(now_ms() - begin < 100);
  free(o.data);
  pump(&e);
  assert(!e.spell.failed);
  spell_word * w = spell_lookup(&e, "speling", 7);
  assert(w && w->result == 2 && w->suggestions);
  // Typing hides only the edited word, while other cached misspellings remain visible.
  e.buffers[0].edited_ms = now_ms();
  e.buffers[0].spelling_editing = true;
  e.buffers[0].spelling_start = 0; e.buffers[0].spelling_end = 7;
  e.panes[0].cursor = 3;
  o = (output){0}; paint(&e, &o);
  assert(!strncmp(o.data, "speling ", 8));
  assert(strstr(o.data + 8, "4;58;2;235;85;85")); free(o.data);
  e.buffers[0].edited_ms = 0;
  e.buffers[0].spelling_editing = false;
  e.panes[0].cursor = 0;
  for (int wrap = 0; wrap < 3; wrap++) {
    e.panes[0].wrap = wrap;
    for (int off = 0; off < 2; off++) {
      e.buffers[0].highlighting_off = off;
      o = (output){0}; paint(&e, &o);
      assert(strstr(o.data, "4;58;2;235;85;85"));
      free(o.data);
    }
  }
  e.panes[0].mark = 1; e.panes[0].mark_active = true;
  pane origin = e.panes[0];
  cmd_spell_correct_word(&e, 0);
  assert(e.spell.n_choices == 2 && active_buffer(&e)->kind == BUFFER_SPELL);
  assert(e.n_panes == 2 && e.panes[0].buffer == 0 && e.spell.preview_pane == 1);
  dispatch(&e, KEY_ESC);
  assert(!e.spell.choosing && !memcmp(&e.panes[0], &origin, sizeof(origin)));
  // Preview cancellation preserves unrelated panes and ordinary C-x o navigation.
  split_pane(&e, LAYOUT_COLS);
  pane saved_panes[PANE_MAX];
  pane_rect before[PANE_MAX], after[PANE_MAX];
  memcpy(saved_panes, e.panes, sizeof(saved_panes));
  pane_rects(&e, before);
  cmd_spell_correct_word(&e, 0);
  assert(e.n_panes == 3 && e.spell.preview_pane == 2);
  dispatch(&e, KEY_CTRL('x')); dispatch(&e, 'o');
  assert(e.active_pane == 0);
  dispatch(&e, KEY_CTRL('g'));
  assert(e.n_panes == 2 && !memcmp(e.panes, saved_panes, 2 * sizeof(pane)));
  pane_rects(&e, after);
  assert(!memcmp(before, after, sizeof(before)));
  e.active_pane = 1; cmd_close_pane(&e, 0); e.active_pane = 0;

  cmd_spell_correct_word(&e, 0);
  e.rows = 5;
  dispatch(&e, KEY_DOWN);
  ensure_visible(&e);
  assert(pane_cursor_row(&e, active_pane(&e), pane_body_rows(&e, e.active_pane)) < 3);
  e.rows = 24;
  dispatch(&e, KEY_UP);
  dispatch(&e, KEY_ENTER);
  assert_text(&e.buffers[0], "spelling speling hello");
  cmd_undo(&e, 0);
  assert_text(&e.buffers[0], "speling speling hello");
  e.panes[0].cursor = 0;
  cmd_spell_correct_word(&e, 0);
  buffer_insert(&e.buffers[0], 0, "X", 1);
  dispatch(&e, '1');
  assert_text(&e.buffers[0], "Xspeling speling hello");

  // Both SGR and classic terminal right-button presses are decoded without treating release as a click.
  const char * events[] = {"\033[<2;4;3M", "\033[M\042\044\043", "\033[<2;4;3m",
                           "\033[778;7;3;4~", "\033[779;7;2~", "\033[779;7;0~"};
  for (int i = 0; i < 6; i++) {
    out_s(&e.input, events[i]);
    key_event event = read_key_event(&e, 0);
    if (i < 2) assert(event.key == KEY_MOUSE && event.mouse_button == 2 && event.mouse_col == 3 && event.mouse_row == 2);
    if (i == 2) assert(event.key != KEY_MOUSE);
    if (i == 3) assert(event.key == KEY_SPELL_MENU && event.spell_request == 7 && event.mouse_col == 3 && event.mouse_row == 2);
    if (i == 4) assert(event.key == KEY_SPELL_PICK && event.spell_request == 7 && event.spell_choice == 2);
    if (i == 5) assert(event.key == KEY_SPELL_PICK && event.spell_request == 7 && event.spell_choice == 0);
  }

  // A missing checker fails once; the per-buffer toggle allows an explicit retry.
  spell_close(&e);
  setenv("EDIT_ASPELL", "/no/such/edit-spell-checker", 1);
  spell_start(&e); pump(&e);
  assert(e.spell.failed && !e.spell.pid);
  cmd_toggle_spell_checking(&e, 0);
  cmd_toggle_spell_checking(&e, 0);
  assert(!e.spell.failed && !e.buffers[0].spelling_off);
  setenv("EDIT_ASPELL", argv[1], 1);

  // Only current-frame candidates are queued; a delayed reply cannot mark new text.
  spell_close(&e);
  for (int i = 0; i < SPELL_CACHE_SIZE; i++) if (e.spell.cache[i].word) e.spell.cache[i].result = 0;
  e.spell.frame++;
  w = spell_lookup(&e, "invisibleword", 13); assert(w); w->seen = e.spell.frame;
  e.spell.frame++;
  w = spell_lookup(&e, "visibleword", 11); assert(w); w->seen = e.spell.frame;
  spell_start(&e); pump(&e);
  assert(w->result == 2);
  assert(spell_lookup(&e, "invisibleword", 13)->result == 0);
  buffers_free(&e);

  // Spelling corrections use the same edit operations in Suggested mode.
  init_state(&e); e.spell.live = true; e.n_buffers = e.n_panes = 1;
  e.rows = 24; e.cols = 80; load_grammar(&e);
  buffer_set_text(&e.buffers[0], "notes.txt", BUFFER_FILE, "speling");
  cmd_suggested(&e, 0);
  assert(e.buffers[0].suggested);
  cmd_spell_correct_word(&e, 0); pump(&e); dispatch(&e, '1');
  assert_text(&e.buffers[0], "spelling");
  assert(e.buffers[0].suggested && e.buffers[0].base_len == 7 &&
         !memcmp(e.buffers[0].base, "speling", 7));
  cmd_undo(&e, 0); assert_text(&e.buffers[0], "speling");
  buffers_free(&e);

  // Dictionary writes follow symlinks, are confirmed on disk, and survive restart.
  init_state(&e); e.spell.live = true; e.n_buffers = e.n_panes = 1; load_grammar(&e);
  buffer_set_text(&e.buffers[0], "notes.txt", BUFFER_FILE, "newpersonalword");
  e.rows = 24; e.cols = 80;
  dispatch(&e, KEY_META('$')); pump(&e);
  assert(e.spell.choosing && e.spell.n_choices == 0 && e.n_panes == 2);
  dispatch(&e, 'i'); pump(&e);
  assert(e.n_panes == 1 && e.active_pane == 0);
  assert_text(&e.buffers[0], "newpersonalword");
  assert(!e.spell.failed && strstr(e.status, "saved"));
  struct stat info;
  assert(!lstat(argv[2], &info) && S_ISLNK(info.st_mode));
  buffers_free(&e);
  init_state(&e); e.spell.live = true;
  w = spell_lookup(&e, "newpersonalword", 15); w->seen = e.spell.frame;
  spell_start(&e); pump(&e); assert(w->result == 1); buffers_free(&e);

  // Native Add word uses the clicked target and rejects a changed source.
  init_state(&e); e.spell.live = true; e.n_buffers = e.n_panes = 1; load_grammar(&e);
  buffer_set_text(&e.buffers[0], "notes.txt", BUFFER_FILE, "nativepersonalword hello");
  cmd_spell_correct_word(&e, KEY_SPELL_MENU); pump(&e);
  assert(!e.spell.choosing && e.spell.n_choices);
  e.panes[0].cursor = 22;
  spell_choice_key(&e, 'i'); pump(&e);
  assert(strstr(e.status, "saved nativepersonalword"));
  e.panes[0].cursor = 0;
  buffer_set_text(&e.buffers[0], "notes.txt", BUFFER_FILE, "stalepersonalword");
  cmd_spell_correct_word(&e, KEY_SPELL_MENU); pump(&e);
  e.buffers[0].revision++;
  spell_choice_key(&e, 'i');
  assert(!e.spell.adding && strstr(e.status, "word changed"));
  buffers_free(&e);

  init_state(&e); e.spell.live = true;
  w = spell_lookup(&e, "crashword", 9); w->seen = e.spell.frame;
  spell_start(&e); pump(&e); assert(e.spell.failed && !e.spell.pid);
  buffers_free(&e);
  init_state(&e); e.spell.live = true; e.n_buffers = e.n_panes = 1; load_grammar(&e);
  setenv("EDIT_TEST_SAVE_FAIL", "1", 1);
  buffer_set_text(&e.buffers[0], "notes.txt", BUFFER_FILE, "unsavedword");
  cmd_spell_add_word(&e, 0); pump(&e);
  assert(e.spell.failed && !strstr(e.status, "saved unsavedword"));
  unsetenv("EDIT_TEST_SAVE_FAIL"); buffers_free(&e);
  puts("spelling checks ok");
  return 0;
}
EOF
printf 'personal_ws-1.1 en 0 utf-8\n' > "$spell_dir/words.pws"
ln -s "$spell_dir/words.pws" "$spell_dir/words-link.pws"
export EDIT_TEST_SPELL_LOG="$spell_dir/spell.log"
cc -std=c11 -Wall -Wextra -pedantic -O2 -I "$PWD" -o "$spell_dir/spell-check" "$spell_dir/spell-check.c" grammar.c regex.c
"$spell_dir/spell-check" "$spell_dir/fake-aspell" "$spell_dir/words-link.pws"
[ "$(grep -c '^speling$' "$spell_dir/spell.log")" = 2 ]
! grep -q '^invisibleword$' "$spell_dir/spell.log"
unset EDIT_TEST_SPELL_LOG

# Right-click keeps the source above a numbered preview, applies a choice, and restores split layouts.
printf 'hello speling\nsecond line\n' > "$spell_dir/right-click.txt"
export EDIT_TEST_SPELL_LOG="$spell_dir/terminal-spell.log"
EDIT_ASPELL="$spell_dir/fake-aspell" EDIT_SPELL_DICTIONARY="$spell_dir/words-link.pws" \
  python3 ./tui_view.py 14:60 '<right-click:8:1><wait-status>' "$spell_dir/right-click.txt" > "$out"
grep -q 'hello.speling' "$out"
grep -q '\*spelling\*' "$out"
grep -q '1..spelling' "$out"
EDIT_ASPELL="$spell_dir/fake-aspell" EDIT_SPELL_DICTIONARY="$spell_dir/words-link.pws" \
  python3 ./tui_view.py 14:60 '<right-click:8:1><wait-status>2^x^s' "$spell_dir/right-click.txt" > "$out"
printf 'hello spilling\nsecond line\n' | cmp -s - "$spell_dir/right-click.txt"
if grep -q '\*spelling\*' "$out"; then exit 1; fi
printf 'hello speling\nsecond line\n' > "$spell_dir/right-click.txt"
EDIT_ASPELL="$spell_dir/fake-aspell" EDIT_SPELL_DICTIONARY="$spell_dir/words-link.pws" \
  python3 ./tui_view.py 14:60 '^x3<right-click:8:1><wait-status><esc>' "$spell_dir/right-click.txt" > "$out"
[ "$(grep -o 'right-click.txt' "$out" | wc -l)" -eq 2 ]
if grep -q '\*spelling\*' "$out"; then exit 1; fi
EDIT_ASPELL="$spell_dir/fake-aspell" EDIT_SPELL_DICTIONARY="$spell_dir/words-link.pws" \
  python3 ./tui_view.py 14:8 '<right-click:2:2><wait-status>1^x^s' "$spell_dir/right-click.txt" > "$out"
printf 'hello spelling\nsecond line\n' | cmp -s - "$spell_dir/right-click.txt"
# The Emacs cursor shortcut opens the preview; i saves without changing the document.
printf 'terminalpersonalword\n' > "$spell_dir/add-word.txt"
EDIT_ASPELL="$spell_dir/fake-aspell" EDIT_SPELL_DICTIONARY="$spell_dir/words-link.pws" \
  python3 ./tui_view.py 14:60 '<esc>$<wait-status>i<wait-status>' "$spell_dir/add-word.txt" > "$out"
grep -q '^terminalpersonalword$' "$spell_dir/words.pws"
printf 'terminalpersonalword\n' | cmp -s - "$spell_dir/add-word.txt"
if grep -q '\*spelling\*' "$out"; then exit 1; fi
unset EDIT_TEST_SPELL_LOG
if command -v aspell >/dev/null 2>&1; then
  printf 'personal_ws-1.1 en 0 utf-8\n' > "$spell_dir/real-words.pws"
  ln -s "$spell_dir/real-words.pws" "$spell_dir/real-words-link.pws"
  "$spell_dir/spell-check" "$(command -v aspell)" "$spell_dir/real-words-link.pws" real
fi

# A selected empty line fills only its pane and clears when the newline is unselected.
cat > "$dir/empty-selection-check.c" <<EOF
#define main edit_program_main
#include "$PWD/edit.c"
#undef main
#include <assert.h>
int main(void) {
  edit_state e;
  init_state(&e);
  e.n_buffers = e.n_panes = 1;
  buffer * b = &e.buffers[0];
  pane * p = &e.panes[0];
  assert(buffer_set_text(b, "selection.txt", BUFFER_FILE, "a\\n\\nb\\n") == 0);
  for (int raw = 0; raw < 2; raw++)
    for (int wrap = 0; wrap < 3; wrap++)
      for (int reverse = 0; reverse < 2; reverse++) {
        e.raw = raw;
        p->wrap = wrap;
        p->mark_active = true;
        p->mark = reverse ? 3 : 0;
        p->cursor = reverse ? 0 : 3;
        for (size_t width = 1; width <= 12; width += 11) {
          output actual = {0}, expected = {0};
          size_t pos = 2;
          render_span_sgr(&e, &expected, REGION_SGR, 0);
          for (size_t i = 0; i < width; i++) out_s(&expected, " ");
          render_base_sgr(&e, &expected);
          assert(render_buffer_line(&e, &actual, b, p, &pos, 8, width) == width);
          assert(pos == 3 && actual.len == expected.len);
          assert(!memcmp(actual.data, expected.data, expected.len));
          free(actual.data); free(expected.data);
        }
        // Ending before the newline or cancelling the mark leaves the row unpainted.
        p->mark = 0; p->cursor = 2;
        for (int active = 0; active < 2; active++) {
          p->mark_active = active;
          output o = {0};
          size_t pos = 2;
          assert(render_buffer_line(&e, &o, b, p, &pos, 0, 12) == 0);
          assert(o.len == 0 && pos == 3);
          free(o.data);
        }
      }
  buffer_free(b);
  return 0;
}
EOF
cc -std=c11 -Wall -Wextra -pedantic -O2 -o "$dir/empty-selection-check" "$dir/empty-selection-check.c" grammar.c regex.c
"$dir/empty-selection-check"

# Named commands complete, list, cancel, and toggle cached Markdown colors per buffer.
cat > "$dir/command-check.c" <<EOF
#define main edit_program_main
#include "$PWD/edit.c"
#undef main
#include <assert.h>
int main(void) {
  edit_state e;
  init_state(&e);
  e.rows = 24; e.cols = 100;
  e.n_buffers = e.n_panes = 1;
  e.panes[0].preferred_col = SIZE_MAX;
  load_grammar(&e);
  assert(buffer_set_text(&e.buffers[0], "notes.txt", BUFFER_FILE,
                         "# Heading\\n**bold** and \`code\`\\n\`\`\`\\ninside\\n\`\`\`\\n") == 0);
  grammar_span txt[128], md[128];
  const char * heading = "# Heading";
  int nt = grammar_highlight(&e.grammar, "notes.txt", heading, strlen(heading), txt, 128);
  int nm = grammar_highlight(&e.grammar, "notes.md", heading, strlen(heading), md, 128);
  assert(nt > 0 && nt == nm);
  for (int i = 0; i < nt; i++) {
    assert(txt[i].start == md[i].start && txt[i].end == md[i].end);
    assert(txt[i].attr == md[i].attr && !strcmp(txt[i].sgr, md[i].sgr));
  }
  output colored = {0}, plain = {0}, restored = {0};
  size_t pos = 0;
  render_buffer_line(&e, &colored, &e.buffers[0], &e.panes[0], &pos, 0, 100);
  assert(e.buffers[0].render_n_spans > 0);
  e.panes[0].cursor = 3;
  e.panes[0].mark = 1;
  e.panes[0].mark_active = true;
  dispatch(&e, KEY_META('x'));
  dispatch(&e, KEY_CTRL('i'));
  assert(e.command_prompt && active_buffer(&e)->kind == BUFFER_FILE);
  dispatch(&e, KEY_CTRL('i'));
  assert(active_buffer(&e)->kind == BUFFER_HELP);
  assert(prompt_footer_cursor(&e));
  char * commands = buffer_text(active_buffer(&e), &(size_t){0});
  assert(strstr(commands, "toggle-syntax-highlighting"));
  free(commands);
  dispatch(&e, KEY_ESC);
  assert(!e.command_prompt && active_pane(&e)->buffer == 0);
  assert(e.panes[0].cursor == 3 && e.panes[0].mark == 1 && e.panes[0].mark_active);
  dispatch(&e, KEY_META('x'));
  const char * prefix = "toggle-syntax";
  for (const char * c = prefix; *c; c++) dispatch(&e, *c);
  dispatch(&e, KEY_CTRL('i'));
  assert(!strcmp(e.command, "toggle-syntax-highlighting"));
  dispatch(&e, KEY_CTRL('i'));
  dispatch(&e, KEY_ENTER);
  assert(!e.command_prompt && active_pane(&e)->buffer == 0);
  assert(e.buffers[0].highlighting_off && !e.buffers[0].dirty);
  assert(e.panes[0].cursor == 3 && e.panes[0].mark == 1 && e.panes[0].mark_active);
  e.panes[0].mark_active = false;
  e.panes[0].cursor = 0;
  pos = 0;
  render_buffer_line(&e, &plain, &e.buffers[0], &e.panes[0], &pos, 0, 100);
  assert(e.buffers[0].render_n_spans && strcmp(colored.data, plain.data));
  dispatch(&e, KEY_META('x'));
  for (const char * c = "toggle-syntax-highlighting"; *c; c++) dispatch(&e, *c);
  dispatch(&e, KEY_ENTER);
  pos = 0;
  render_buffer_line(&e, &restored, &e.buffers[0], &e.panes[0], &pos, 0, 100);
  assert(!e.buffers[0].highlighting_off && !strcmp(colored.data, restored.data));
  dispatch(&e, KEY_META('x'));
  for (const char * c = "not-a-command"; *c; c++) dispatch(&e, *c);
  dispatch(&e, KEY_ENTER);
  assert(e.command_prompt);
  dispatch(&e, KEY_CTRL('g'));
  assert(!e.command_prompt && !e.buffers[0].dirty);
  dispatch(&e, KEY_META('x'));
  for (const char * c = "end-of-buffer"; *c; c++) dispatch(&e, *c);
  dispatch(&e, KEY_ENTER);
  assert(e.panes[0].cursor == buffer_len(&e.buffers[0]));
  for (int i = 0; i < e.n_buffers; i++) buffer_free(&e.buffers[i]);
  free(colored.data); free(plain.data); free(restored.data);
  return 0;
}
EOF
cc -std=c11 -Wall -Wextra -pedantic -O2 -o "$dir/command-check" "$dir/command-check.c" grammar.c regex.c
"$dir/command-check"

# A resize just before waiting must redraw before consuming queued input.
cat > "$dir/resize-check.c" <<EOF
#define main edit_program_main
#include "$PWD/edit.c"
#undef main
#include <assert.h>
int main(void) {
  edit_state e;
  init_state(&e);
  out_s(&e.input, "X");
  window_resized(SIGWINCH);
  assert(read_key_event(&e, -1).key == -1 && e.input.len == 1);
  window_changed = 0;
  assert(read_key_event(&e, -1).key == 'X' && e.input.len == 0);
  free(e.input.data);
  return 0;
}
EOF
cc -std=c11 -Wall -Wextra -pedantic -O2 -o "$dir/resize-check" "$dir/resize-check.c" grammar.c regex.c
"$dir/resize-check"


# Scrolling work stays local, and cached highlighting matches a fresh render after edits.
cat > "$dir/scroll-check.c" <<EOF
#define main edit_program_main
#include "$PWD/edit.c"
#undef main
#include <assert.h>

static void frame(edit_state * e, output * o) {
  size_t pos = e->panes[0].top;
  ensure_visible(e);
  pos = e->panes[0].top;
  for (int row = 0; row < 28 && pos < buffer_len(&e->buffers[0]); row++)
    render_buffer_line(e, o, &e->buffers[0], &e->panes[0], &pos, 0, 100);
}

int main(void) {
  edit_state e;
  init_state(&e);
  e.rows = 30;
  e.cols = 100;
  e.n_buffers = e.n_panes = 1;
  e.panes[0].wrap = 2;
  e.panes[0].preferred_col = SIZE_MAX;
  load_grammar(&e);
  size_t n = 2 * 1024 * 1024;
  char * text = malloc(n + 1);
  assert(text);
  for (size_t i = 0; i < n; i++) text[i] = i % 6 == 5 ? ' ' : 'a';
  text[n] = 0;
  for (int long_line = 0; long_line < 2; long_line++) {
    for (size_t i = 32767; i < n; i += 32768) text[i] = long_line ? ' ' : '\n';
    assert(buffer_set_text(&e.buffers[0], "scroll.md", BUFFER_FILE, text) == 0);
    e.panes[0].cursor = e.panes[0].top = 0;
    output o = {0};
    frame(&e, &o);
    free(o.data);
    long long begin = now_ms();
    for (int step = 0; step < 100; step++) {
      cmd_down(&e, 0);
      o = (output){0};
      frame(&e, &o);
      free(o.data);
    }
    // This generous gate catches document-wide rescans without depending on frame scheduling.
    assert(now_ms() - begin < 500);
    if (long_line) {
      e.panes[0].cursor = n / 2;
      e.panes[0].top = 0;
      o = (output){0};
      begin = now_ms();
      frame(&e, &o);
      assert(now_ms() - begin < 500);
      free(o.data);
    }
  }
  assert(buffer_insert(&e.buffers[0], 0, "\x60\x60\x60\n", 4) == 0);
  for (int change = 0; change < 2; change++) {
    if (change) buffer_delete(&e.buffers[0], 0, 4);
    e.panes[0].cursor = 700;
    e.panes[0].top = 100;
    output cached = {0}, fresh = {0};
    frame(&e, &cached);
    // Discard only derived state and require identical source text, wrapping, and styles.
    buffer_invalidate_render(&e.buffers[0]);
    frame(&e, &fresh);
    assert(cached.len == fresh.len && memcmp(cached.data, fresh.data, fresh.len) == 0);
    free(cached.data);
    free(fresh.data);
  }
  free(text);
  buffers_free(&e);
  return 0;
}
EOF
cc -std=c11 -Wall -Wextra -pedantic -O2 -o "$dir/scroll-check" "$dir/scroll-check.c" grammar.c regex.c
"$dir/scroll-check"

foot() {
  width=$1
  msg=$2
  hint='C-h help'
  limit=$width
  left=$((limit - ${#hint}))
  if [ "$left" -le 0 ]; then
    printf '%.*s' "$limit" "$hint"
    return
  fi
  printf '%.*s' "$left" "$msg"
  used=${#msg}
  [ "$used" -gt "$left" ] && used=$left
  while [ "$used" -lt "$left" ]; do
    printf ' '
    used=$((used + 1))
  done
  printf '%s' "$hint"
}

printf 'one\ntwo\nthree\n' > "$tmp"
./edit --print 2:1..3:1 "$tmp" > "$out"
printf 'two\n' | cmp -s - "$out"

./edit --search 1:1 one "$tmp" > "$out"
printf '1:1..1:4\n' | cmp -s - "$out"

./edit --search 1:1 wo "$tmp" > "$out"
printf '2:2..2:4\n' | cmp -s - "$out"

./edit --search 3:5 e "$tmp" > "$out"
printf '3:5..3:6\n' | cmp -s - "$out"

if ./edit --search 1:1 zzz "$tmp" > "$out" 2>&1; then exit 1; fi

printf '* item\naXXb\na.*b\n' > "$tmp"
./edit --search 1:1 '*' "$tmp" > "$out"
printf '1:1..1:2\n' | cmp -s - "$out"

./edit --search 1:1 '[*]' "$tmp" > "$out"
printf '1:1..1:2\n' | cmp -s - "$out"

./edit --search 1:2 '[*]' "$tmp" > "$out"
printf '3:3..3:4\n' | cmp -s - "$out"

./edit --search 1:1 'a.*b' "$tmp" > "$out"
printf '2:1..2:5\n' | cmp -s - "$out"

printf 'abc\n' > "$tmp"
if ./edit --search 1:1 '*' "$tmp" > "$out" 2>&1; then exit 1; fi

printf 'one\ntwo\nthree\n' > "$tmp"
./edit --insert 2:1 'X' "$tmp" > "$out"
printf 'one\nXtwo\nthree\n' | cmp -s - "$tmp"

./edit --delete 2:1..2:2 "$tmp" > "$out"
printf 'one\ntwo\nthree\n' | cmp -s - "$tmp"

printf 'middle' | ./edit --replace 2:1..2:4 - "$tmp" > "$out"
printf 'one\nmiddle\nthree\n' | cmp -s - "$tmp"

printf 'style comment 90\nrule comment //.*\n' > "$tmp.grammar"
EDIT_GRAMMAR="$tmp.grammar" ./edit --print 1:1..1:4 "$tmp" > "$out"
printf 'one' | cmp -s - "$out"

esc=$(printf '\033')
printf 'int tint = 42; // return 7\nchar *s = "hi";\n' > "$tmp"
./edit --render-color 4:80 "$tmp" > "$out"
printf '%s[38;2;150;190;255mint%s[0m %s[38;2;255;215;95mtint%s[0m %s[38;2;224;224;224m=%s[0m %s[38;2;120;220;255m42%s[0m%s[38;2;224;224;224m;%s[0m %s[38;2;255;166;102m// return 7%s[0m\n%s[38;2;150;190;255mchar%s[0m %s[38;2;224;224;224m*%s[0m%s[38;2;255;215;95ms%s[0m %s[38;2;224;224;224m=%s[0m %s[38;2;170;255;170m"hi"%s[0m%s[38;2;224;224;224m;%s[0m\n\n' \
  "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" \
  "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" \
  "$esc" "$esc" "$esc" "$esc" |
  cmp -s - "$out"

printf 'style comment 31\nrule comment //.*\n' > "$tmp.grammar"
EDIT_GRAMMAR="$tmp.grammar" ./edit --render-color 3:80 "$tmp" > "$out"
printf 'int tint = 42; %s[31m// return 7%s[0m\nchar *s = "hi";\n' \
  "$esc" "$esc" | cmp -s - "$out"

printf 'style keyword 33\nword keyword int return\n' > "$tmp.grammar"
printf 'int tint return\n' > "$tmp"
EDIT_GRAMMAR="$tmp.grammar" ./edit --render-color 3:80 "$tmp" > "$out"
printf '%s[33mint%s[0m tint %s[33mreturn%s[0m\n\n' \
  "$esc" "$esc" "$esc" "$esc" | cmp -s - "$out"

printf '#include <stdio.h>\n#define LIMIT 16\n' > "$tmp"
./edit --render-color 4:80 "$tmp" > "$out"
grep -F -q "$(printf '%s[38;2;255;215;95m#include%s[0m%s[38;2;116;150;200m <stdio.h>%s[0m' "$esc" "$esc" "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;255;215;95m#define%s[0m%s[38;2;116;150;200m LIMIT 16%s[0m' "$esc" "$esc" "$esc" "$esc")" "$out"

printf 'printf "$(date +%%S)"\n' > "$tmp"
./edit --render-color 3:80 "$tmp" > "$out"
grep -F -q "$(printf '%s[38;2;120;220;255mdate%s[0m' "$esc" "$esc")" "$out"

printf 'x = """\nline\n"""\n' > "$tmp"
./edit --render-color 5:80 "$tmp" > "$out"
grep -F -q "$(printf '%s[38;2;170;255;170mline%s[0m' "$esc" "$esc")" "$out"

printf 'print(f"{value + 1}")\n' > "$tmp"
./edit --render-color 3:80 "$tmp" > "$out"
grep -F -q "$(printf '%s[38;2;255;150;170mf%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;120;220;255m1%s[0m' "$esc" "$esc")" "$out"

printf 'x = r"raw"\n' > "$tmp"
./edit --render-color 3:80 "$tmp" > "$out"
grep -F -q "$(printf '%s[38;2;255;150;170mr%s[0m' "$esc" "$esc")" "$out"

printf 'def foo():\n    return list()\n' > "$tmp"
./edit --render-color 4:80 "$tmp" > "$out"
grep -F -q "$(printf '%s[38;2;120;255;255mdef%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;80;190;255mfoo%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;232;232;232mlist%s[0m' "$esc" "$esc")" "$out"
if grep -F -q "$(printf '%s[38;2;80;190;255mlist%s[0m' "$esc" "$esc")" "$out"; then exit 1; fi

printf 'value: list = []\n' > "$tmp"
./edit --render-color 3:80 "$tmp" > "$out"
grep -F -q "$(printf '%s[38;2;150;190;255mlist%s[0m' "$esc" "$esc")" "$out"

printf 'class Foo:\n    pass\nvalue = Path("x")\n' > "$tmp"
./edit --render-color 3:80 "$tmp" > "$out"
grep -F -q "$(printf '%s[38;2;210;255;90mFoo%s[0m' "$esc" "$esc")" "$out"
if grep -F -q "$(printf '%s[38;2;210;255;90mPath%s[0m' "$esc" "$esc")" "$out"; then exit 1; fi

printf 'answer: int = 42\nif answer == 42:\n    obj.answer = 1\ndef f(limit: int = 0): pass\n' > "$tmp"
./edit --render-color 6:80 "$tmp" > "$out"
grep -F -q "$(printf '%s[38;2;255;215;95manswer%s[0m' "$esc" "$esc")" "$out"
if grep -F -q "$(printf 'obj.%s[38;2;255;215;95manswer%s[0m' "$esc" "$esc")" "$out"; then exit 1; fi
if grep -F -q "$(printf '%s[38;2;255;215;95mint%s[0m' "$esc" "$esc")" "$out"; then exit 1; fi
if grep -F -q "$(printf '%s[38;2;255;215;95mlimit%s[0m' "$esc" "$esc")" "$out"; then exit 1; fi

f90="$dir/sample.f90"
printf 'MODULE demo\nUSE iso_fortran_env, ONLY: INT32\nIMPLICIT NONE\nINTEGER(KIND=INT32) :: value = SELECTED_INT_KIND(19)\nINTEGER(KIND=INT32) :: DO      ! dimension output\nTYPE, BIND(C) :: PROFILE_ENTRY\nREAL(KIND=REAL64) :: WALL_TIME\nEND TYPE PROFILE_ENTRY\nTYPE(PROFILE_ENTRY) :: PROFILE\nFUNCTION f(x) RESULT(y)\nREAL :: y\nIF (0.0_REAL32 .LT. 1.0_REAL32) y = x\nMASK = .FALSE.\nCALL g(MODEL(CONFIG%ASEV:CONFIG%AEEV), RANDOM_LENGTHS=.TRUE._C_BOOL)\nDO i = 1, 3\nEND DO\nEND FUNCTION f\n! this is and for prose\n' > "$f90"
./edit --render-color 20:100 "$f90" > "$out"
grep -F -q "$(printf '%s[38;2;120;255;255mMODULE%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;120;255;255mUSE%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;120;255;255mIMPLICIT%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;150;190;255mINTEGER%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;120;255;255mFUNCTION%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;120;255;255mEND%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;232;232;232mSELECTED_INT_KIND%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;120;220;255m0.0_REAL32%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;120;255;255m.LT.%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;120;220;255m.FALSE.%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;120;220;255m.TRUE._C_BOOL%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;255;166;102m! this is and for prose%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;224;224;224m::%s[0m %s[38;2;120;255;175mDO%s[0m      %s[38;2;255;166;102m! dimension output%s[0m' "$esc" "$esc" "$esc" "$esc" "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;210;255;90mPROFILE_ENTRY%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;120;255;175mWALL_TIME%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;120;255;175mPROFILE%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;120;255;255mDO%s[0m i %s[38;2;224;224;224m=%s[0m' "$esc" "$esc" "$esc" "$esc")" "$out"
if grep -F -q "$(printf '%s[38;2;120;255;255mis%s[0m' "$esc" "$esc")" "$out"; then exit 1; fi
if grep -F -q "$(printf '%s[38;2;120;255;255mand%s[0m' "$esc" "$esc")" "$out"; then exit 1; fi
if grep -F -q "$(printf '%s[38;2;120;255;255mfor%s[0m' "$esc" "$esc")" "$out"; then exit 1; fi
if grep -F -q "$(printf ':: %s[38;2;120;255;255mDO%s[0m' "$esc" "$esc")" "$out"; then exit 1; fi
if grep -F -q "$(printf 'CONFIG%%ASEV:%s[38;2;120;220;255mCONFIG%%AEEV%s[0m' "$esc" "$esc")" "$out"; then exit 1; fi

md="$dir/sample.md"
printf '# Title\n- item\n> quote\nSee [guide](https://example.com) and `code`.\n```\nreturn 0;\n```\nTODO: write docs\n' > "$md"
./edit --render-color 10:80 "$md" > "$out"
grep -F -q "$(printf '%s[38;2;80;190;255m# Title%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;224;224;224m-%s[0m item' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;255;166;102m>%s[0m quote' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;80;190;255mhttps://example.com%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;170;255;170m`code`%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;170;255;170mreturn 0;%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;255;150;170mTODO%s[0m' "$esc" "$esc")" "$out"

printf '*word*\n**word**\n***word***\n*TODO*\n*open\n' > "$md"
./edit --render-color 7:80 "$md" > "$out"
grep -F -q "$(printf '%s[38;2;255;140;255m*%s[0m%s[3mword%s[0m%s[38;2;255;140;255m*' "$esc" "$esc" "$esc" "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;255;140;255m**%s[0m%s[1mword%s[0m%s[38;2;255;140;255m**' "$esc" "$esc" "$esc" "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;255;140;255m***%s[0m%s[1;3mword%s[0m%s[38;2;255;140;255m***' "$esc" "$esc" "$esc" "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[3;38;2;255;150;170mTODO%s[0m' "$esc" "$esc")" "$out"
if grep -F -q "$(printf '%s[3mopen' "$esc")" "$out"; then exit 1; fi

txt="$dir/sample.txt"
printf 'for class return\n- item\n> quote\nTODO: see https://example.com\n' > "$txt"
./edit --render-color 6:80 "$txt" > "$out"
grep -F -q "$(printf '%s[38;2;224;224;224m-%s[0m item' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;255;166;102m>%s[0m quote' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;255;150;170mTODO%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;80;190;255mhttps://example.com%s[0m' "$esc" "$esc")" "$out"
if grep -F -q "$(printf '%s[38;2;120;255;255mfor%s[0m' "$esc" "$esc")" "$out"; then exit 1; fi
if grep -F -q "$(printf '%s[38;2;120;255;255mreturn%s[0m' "$esc" "$esc")" "$out"; then exit 1; fi
if grep -F -q "$(printf '%s[38;2;210;255;90mclass%s[0m' "$esc" "$esc")" "$out"; then exit 1; fi

printf 'abc\n  def\n\tghi\n' > "$tmp"
./edit --render 5:12 "$tmp" > "$out"
printf '|abc\n..def\n>..ghi\n%s 1:1\n%s\n' "$base" "$(foot 12 "")" | cmp -s - "$out"

./edit --render-at 5:12 2:2 "$tmp" > "$out"
printf 'abc\n.|.def\n>..ghi\n%s 2:2\n%s\n' "$base" "$(foot 12 "")" | cmp -s - "$out"

./edit --render-keys 5:12 nf "$tmp" > "$out"
printf 'abc\n.|.def\n>..ghi\n%s 2:2\n%s\n' "$base" "$(foot 12 "")" | cmp -s - "$out"

./edit --render-at 5:12 3:2 "$tmp" > "$out"
printf 'abc\n..def\n>..|ghi\n%s 3:2\n%s\n' "$base" "$(foot 12 "")" | cmp -s - "$out"

EDIT_TAB_WIDTH=4 ./edit --render 5:12 "$tmp" > "$out"
printf '|abc\n..def\n>...ghi\n%s 1:1\n%s\n' "$base" "$(foot 12 "")" | cmp -s - "$out"

printf 'abc\n' > "$tmp"
./edit --render-keys 4:20 "$(printf '\t')" "$tmp" > "$out"
printf '...|abc\n\n%s* 1:4\n%s\n' "$base" "$(foot 20 "")" | cmp -s - "$out"

EDIT_TAB_WIDTH=2 ./edit --render-keys 4:20 "$(printf '\t')" "$tmp" > "$out"
printf '..|abc\n\n%s* 1:3\n%s\n' "$base" "$(foot 20 "")" | cmp -s - "$out"

js="$dir/sample.js"
css="$dir/sample.css"
printf 'abc\n' > "$js"
printf 'abc\n' > "$css"
EDIT_TAB_WIDTH=5 ./edit --render-keys 4:20 "$(printf '\t')" "$js" > "$out"
printf '..|abc\n\nsample.js* 1:3\n%s\n' "$(foot 20 "")" | cmp -s - "$out"

EDIT_TAB_WIDTH=5 ./edit --render-keys 4:20 "$(printf '\t')" "$css" > "$out"
printf '..|abc\n\nsample.css* 1:3\n%s\n' "$(foot 20 "")" | cmp -s - "$out"

./edit --render-keys 4:20 "$(printf '\t')_" "$tmp" > "$out"
printf '|abc\n\n%s 1:1\n%s\n' "$base" "$(foot 20 "undo")" | cmp -s - "$out"

./edit --render-keys 4:20 "q$(printf '\t')" "$tmp" > "$out"
printf '>..|abc\n\n%s* 1:2\n%s\n' "$base" "$(foot 20 "C-q")" | cmp -s - "$out"

./edit --render-keys 4:20 "q$(printf '\t')_" "$tmp" > "$out"
printf '|abc\n\n%s 1:1\n%s\n' "$base" "$(foot 20 "undo")" | cmp -s - "$out"

printf 'abcdef\nabc\n' > "$tmp"
./edit --render-keys 5:12 fffn "$tmp" > "$out"
printf 'abcdef\nabc|\n\n%s 2:4\n%s\n' "$base" "$(foot 12 "")" | cmp -s - "$out"

printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n' > "$tmp"
./edit --render-keys 5:12 v "$tmp" > "$out"
printf 'l3\n|l4\nl5\n%s 4:1\n%s\n' "$base" "$(foot 12 "")" | cmp -s - "$out"

./edit --render-keys 5:12 vV "$tmp" > "$out"
printf '|l1\nl2\nl3\n%s 1:1\n%s\n' "$base" "$(foot 12 "")" | cmp -s - "$out"

./edit --render-keys 5:20 nnnnnl "$tmp" > "$out"
printf 'l5\n|l6\nl7\n%s 6:1\n%s\n' "$base" "$(foot 20 "")" | cmp -s - "$out"

./edit --render-keys 5:20 nnnnnll "$tmp" > "$out"
printf '|l6\nl7\nl8\n%s 6:1\n%s\n' "$base" "$(foot 20 "")" | cmp -s - "$out"

./edit --render-keys 5:20 nnnnnlll "$tmp" > "$out"
printf 'l4\nl5\n|l6\n%s 6:1\n%s\n' "$base" "$(foot 20 "")" | cmp -s - "$out"

printf 'l01xx\nl02xx\nl03xx\nl04xx\nl05xx\nl06xx\nl07xx\nl08xx\nl09xx\nl10xx\nl11xx\nl12xx\n' > "$tmp"
./edit --render-keys 6:20 ffN "$tmp" > "$out"
printf 'l09xx\nl10xx\nl1|1xx\nl12xx\n%s 11:3\n%s\n' "$base" "$(foot 20 "")" | cmp -s - "$out"

./edit --render-keys 6:20 ffNP "$tmp" > "$out"
printf 'l0|1xx\nl02xx\nl03xx\nl04xx\n%s 1:3\n%s\n' "$base" "$(foot 20 "")" | cmp -s - "$out"

./edit --render-keys 6:20 ">>" "$tmp" > "$out"
printf 'l10xx\nl11xx\nl12xx\n|\n%s 13:1\n%s\n' "$base" "$(foot 20 "")" | cmp -s - "$out"

./edit --render-keys 6:20 ">>nf" "$tmp" > "$out"
printf 'l10xx\nl11xx\nl12xx\n|\n%s 13:1\n%s\n' "$base" "$(foot 20 "")" | cmp -s - "$out"

printf 'l01xx\nl02xx\nl03xx\nl04xx\nl05xx\nl06xx\nl07xx\nl08xx\nl09xx\nl10xx\nl11xx\nl12xx' > "$tmp"
./edit --render-keys 6:20 ">>nf" "$tmp" > "$out"
printf 'l09xx\nl10xx\nl11xx\nl12xx|\n%s 12:6\n%s\n' "$base" "$(foot 20 "")" | cmp -s - "$out"

printf 'l01xx\nl02xx\nl03xx\nl04xx\nl05xx\nl06xx\nl07xx\nl08xx\nl09xx\nl10xx\nl11xx\nl12xx\n' > "$tmp"

./edit --render-keys 6:20 ">>><" "$tmp" > "$out"
printf '|l01xx\nl02xx\nl03xx\nl04xx\n%s 1:1\n%s\n' "$base" "$(foot 20 "")" | cmp -s - "$out"

python3 ./tui_view.py 6:30 '<opt-gt>' "$tmp" > "$out"
sed -n '5p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *13:1*) ;; *) exit 1;; esac

python3 ./tui_view.py 6:30 '<opt-gt><opt-lt>' "$tmp" > "$out"
sed -n '5p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *1:1*) ;; *) exit 1;; esac

python3 ./tui_view.py 6:30 '<right><right><m-g>g7
' "$tmp" > "$out"
sed -n '5p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *7:1*) ;; *) exit 1;; esac
case "$(tail -n 1 "$out")" in cursor:*:1) ;; *) exit 1;; esac

python3 ./tui_view.py 6:30 '<m-g>g99
' "$tmp" > "$out"
sed -n '5p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *13:1*) ;; *) exit 1;; esac

python3 ./tui_view.py 6:30 '<right><right><down><m-g>gabc
' "$tmp" > "$out"
sed -n '5p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *2:3*) ;; *) exit 1;; esac
grep -q 'bad.line' "$out"

printf 'one, two_three 9x\n' > "$tmp"
./edit --render-keys 4:30 F "$tmp" > "$out"
printf 'one|,.two_three.9x\n\n%s 1:4\n%s\n' "$base" "$(foot 30 "")" | cmp -s - "$out"

./edit --render-keys 4:30 FF "$tmp" > "$out"
printf 'one,.two|_three.9x\n\n%s 1:9\n%s\n' "$base" "$(foot 30 "")" | cmp -s - "$out"

./edit --render-keys 4:30 FFB "$tmp" > "$out"
printf 'one,.|two_three.9x\n\n%s 1:6\n%s\n' "$base" "$(foot 30 "")" | cmp -s - "$out"

./edit --render-keys 4:30 FffB "$tmp" > "$out"
printf '|one,.two_three.9x\n\n%s 1:1\n%s\n' "$base" "$(foot 30 "")" | cmp -s - "$out"

printf 'camelCaseWord other\n' > "$tmp"
./edit --render-keys 4:40 F "$tmp" > "$out"
printf 'camel|CaseWord.other\n\n%s 1:6\n%s\n' "$base" "$(foot 40 "")" | cmp -s - "$out"

./edit --render-keys 4:40 FF "$tmp" > "$out"
printf 'camelCase|Word.other\n\n%s 1:10\n%s\n' "$base" "$(foot 40 "")" | cmp -s - "$out"

./edit --render-keys 4:40 FFFB "$tmp" > "$out"
printf 'camelCase|Word.other\n\n%s 1:10\n%s\n' "$base" "$(foot 40 "")" | cmp -s - "$out"

printf 'snake_case other\n' > "$tmp"
./edit --render-keys 4:40 F "$tmp" > "$out"
printf 'snake|_case.other\n\n%s 1:6\n%s\n' "$base" "$(foot 40 "")" | cmp -s - "$out"

./edit --render-keys 4:40 FF "$tmp" > "$out"
printf 'snake_case|.other\n\n%s 1:11\n%s\n' "$base" "$(foot 40 "")" | cmp -s - "$out"

./edit --render-keys 4:40 FFB "$tmp" > "$out"
printf 'snake_|case.other\n\n%s 1:7\n%s\n' "$base" "$(foot 40 "")" | cmp -s - "$out"

./edit --render-keys 4:40 FFBB "$tmp" > "$out"
printf '|snake_case.other\n\n%s 1:1\n%s\n' "$base" "$(foot 40 "")" | cmp -s - "$out"

printf 'one, two_three 9x\n' > "$tmp"
./edit --render-keys 4:30 D "$tmp" > "$out"
printf '|,.two_three.9x\n\n%s* 1:1\n%s\n' "$base" "$(foot 30 "")" | cmp -s - "$out"

./edit --render-keys 4:30 FD "$tmp" > "$out"
printf 'one|_three.9x\n\n%s* 1:4\n%s\n' "$base" "$(foot 30 "")" | cmp -s - "$out"

./edit --render-keys 4:30 DDD "$tmp" > "$out"
printf '|.9x\n\n%s* 1:1\n%s\n' "$base" "$(foot 30 "")" | cmp -s - "$out"

./edit --render-keys 4:30 D_ "$tmp" > "$out"
printf 'one|,.two_three.9x\n\n%s 1:4\n%s\n' "$base" "$(foot 30 "undo")" | cmp -s - "$out"

printf 'camelCaseWord other\n' > "$tmp"
./edit --render-keys 4:40 DD "$tmp" > "$out"
printf '|Word.other\n\n%s* 1:1\n%s\n' "$base" "$(foot 40 "")" | cmp -s - "$out"

printf 'snake_case other\n' > "$tmp"
./edit --render-keys 4:40 DD "$tmp" > "$out"
printf '|.other\n\n%s* 1:1\n%s\n' "$base" "$(foot 40 "")" | cmp -s - "$out"

printf 'one, two_three 9x\n' > "$tmp"
python3 ./tui_view.py 4:40 '<opt-f>' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:4\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 4:40 '<opt-f><opt-f><opt-b>' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:6\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 4:40 '<esc>f' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:4\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 4:40 '<m-f>ff' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:15\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 4:40 '<mac-f><mac-f><mac-b>' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:6\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 4:50 '<opt-d>' "$tmp" > "$out"
grep -q '^>01:,.two_three.9x$' "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:1\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 4:50 '<mac-d><mac-d>' "$tmp" > "$out"
grep -q '^>01:_three.9x$' "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:1\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 4:50 '<m-f><m-f><m-del>' "$tmp" > "$out"
grep -q '^>01:one,._three.9x$' "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:6\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 4:50 '<m-f><m-f><m-del><m-del>' "$tmp" > "$out"
grep -q '^>01:_three.9x$' "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:1\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 4:50 '<m-f><m-f><m-del><c-slash>' "$tmp" > "$out"
grep -q '^>01:one,.two_three.9x$' "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:9\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

printf 'camelCaseWord other\n' > "$tmp"
python3 ./tui_view.py 4:50 '<m-f><m-f><m-f><m-del>' "$tmp" > "$out"
grep -q '^>01:camelCase.other$' "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:10\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

printf 'snake_case other\n' > "$tmp"
python3 ./tui_view.py 4:40 '<m-f><m-f><m-b>' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:7\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 4:50 '<m-f><m-f><m-del>' "$tmp" > "$out"
grep -q '^>01:snake_.other$' "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:7\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

printf 'one, two_three 9x\n' > "$tmp"
EDIT_DEBUG_LOG="$tmp.debug" python3 ./tui_view.py 4:40 '<m-r><opt-f><esc>meta failed
' "$tmp" > "$out"
test -s "$tmp.debug"
grep -q 'rows=4 cols=40' "$tmp.debug"
grep -q 'kind=mac-option key=M-f raw=c6 92' "$tmp.debug"
grep -q 'state after .*cursor=3.*line=1.*col=4' "$tmp.debug"
grep -q '^ansi_hex=' "$tmp.debug"
grep -q '^snapshot:' "$tmp.debug"
grep -q '^note=meta failed' "$tmp.debug"

EDIT_DEBUG_LOG="$tmp.debug2" python3 ./tui_view.py 4:40 '<m-r><m-f><esc>ok
' "$tmp" > "$out"
test -s "$tmp.debug2"
grep -q 'kind=esc-meta key=M-f raw=1b 66' "$tmp.debug2"
grep -q 'kind=plain-esc key=ESC raw=1b' "$tmp.debug2"
grep -q '^note=ok' "$tmp.debug2"

EDIT_DEBUG_LOG="$tmp.debug3" python3 ./tui_view.py 4:40 '<esc>r<opt-f><esc>delayed
' "$tmp" > "$out"
test -s "$tmp.debug3"
grep -q 'action=debug-start' "$tmp.debug3"
grep -q 'kind=mac-option key=M-f raw=c6 92' "$tmp.debug3"
grep -q 'state after .*cursor=3.*line=1.*col=4' "$tmp.debug3"
grep -q '^note=delayed' "$tmp.debug3"

EDIT_DEBUG_LOG="$tmp.debug3" python3 ./tui_view.py 4:40 '<mac-r><mac-f><esc>mac option
' "$tmp" > "$out"
test -s "$tmp.debug3"
grep -q 'kind=mac-option key=M-f raw=c6 92' "$tmp.debug3"
grep -q 'state after .*cursor=3.*line=1.*col=4' "$tmp.debug3"
grep -q '^note=mac option' "$tmp.debug3"

EDIT_DEBUG_LOG="$tmp.debug3" python3 ./tui_view.py 4:60 '<m-r><esc>foo bar^a<m-f>X
' "$tmp" > "$out"
grep -q '^note=fooX bar' "$tmp.debug3"

printf 'l01xx\nl02xx\nl03xx\nl04xx\nl05xx\nl06xx\nl07xx\nl08xx\nl09xx\nl10xx\nl11xx\nl12xx\n' > "$tmp"
python3 ./tui_view.py 6:20 '<right><right><opt-n>' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:3:3\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 6:20 '<right><right><mac-n><mac-p>' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:3\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 6:20 '<right><right><opt-n><opt-p>' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:3\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

./edit --render-keys 6:20 nnn "$tmp" > "$out"
printf 'l02xx\nl03xx\n|l04xx\nl05xx\n%s 4:1\n%s\n' "$base" "$(foot 20 "")" | cmp -s - "$out"

./edit --render-keys 6:20 nnnnnp "$tmp" > "$out"
printf 'l03xx\nl04xx\n|l05xx\nl06xx\n%s 5:1\n%s\n' "$base" "$(foot 20 "")" | cmp -s - "$out"

printf 'one\ntwo\nthree\nfour\n' > "$tmp"
./edit --render-keys 6:20 x2 "$tmp" > "$out"
printf '|one\ntwo\n%s 1:1>\n|one\n%s 1:1\n%s\n' "$base" "$base" "$(foot 20 "split")" | cmp -s - "$out"

./edit --render-keys 6:20 x2nxof "$tmp" > "$out"
printf 'one\n|two\n%s 2:1\no|ne\n%s 1:2>\n%s\n' "$base" "$base" "$(foot 20 "other pane")" | cmp -s - "$out"

./edit --render-keys 6:20 x2Xxo "$tmp" > "$out"
printf 'X|one\ntwo\n%s* 1:2\nX|one\n%s* 1:2>\n%s\n' "$base" "$base" "$(foot 20 "other pane")" | cmp -s - "$out"

./edit --render-keys 6:20 x2X_xo "$tmp" > "$out"
printf '|one\ntwo\n%s 1:1\n|one\n%s 1:1>\n%s\n' "$base" "$base" "$(foot 20 "other pane")" | cmp -s - "$out"

./edit --render-keys 6:20 x2x0 "$tmp" > "$out"
printf '|one\ntwo\nthree\nfour\n%s 1:1\n%s\n' "$base" "$(foot 20 "close pane")" | cmp -s - "$out"

./edit --render-keys 6:20 x2x1 "$tmp" > "$out"
printf '|one\ntwo\nthree\nfour\n%s 1:1\n%s\n' "$base" "$(foot 20 "one pane")" | cmp -s - "$out"

./edit --render-keys 5:23 x3 "$tmp" > "$out"
head=$(printf '%s' "$base" | cut -c 1-11)
printf '|one       │|one       \ntwo        │two        \nthree      │three      \n%s│%s\n%s\n' "$head" "$head" "$(foot 23 "split")" | cmp -s - "$out"

./edit --render-keys 5:23 x3nxof "$tmp" > "$out"
printf 'one        │o|ne       \n|two       │two        \nthree      │three      \n%s│%s\n%s\n' "$head" "$head" "$(foot 23 "other pane")" | cmp -s - "$out"

cell15() {
  printf '%-15.15s' "$1"
}

pane=$(cell15 "$base 1:1")
pane_active=$(cell15 "$base 1:1>")
blank=$(cell15 "")
./edit --render-keys 8:31 x3x2 "$tmp" > "$out"
printf '%s│%s\n%s│%s\n%s│%s\n%s│%s\n%s│%s\n%s│%s\n%s│%s\n%s\n' \
  "$(cell15 "|one")" "$(cell15 "|one")" \
  "$(cell15 "two")" "$(cell15 "two")" \
  "$(cell15 "three")" "$(cell15 "three")" \
  "$pane_active" "$(cell15 "four")" \
  "$(cell15 "|one")" "$blank" \
  "$(cell15 "two")" "$blank" \
  "$pane" "$pane" \
  "$(foot 31 "split")" | cmp -s - "$out"

./edit --render-keys 8:31 x3xox2 "$tmp" > "$out"
printf '%s│%s\n%s│%s\n%s│%s\n%s│%s\n%s│%s\n%s│%s\n%s│%s\n%s\n' \
  "$(cell15 "|one")" "$(cell15 "|one")" \
  "$(cell15 "two")" "$(cell15 "two")" \
  "$(cell15 "three")" "$(cell15 "three")" \
  "$(cell15 "four")" "$pane_active" \
  "$blank" "$(cell15 "|one")" \
  "$blank" "$(cell15 "two")" \
  "$pane" "$pane" \
  "$(foot 31 "split")" | cmp -s - "$out"

./edit --render-keys 8:31 x3x2x0 "$tmp" > "$out"
printf '%s│%s\n%s│%s\n%s│%s\n%s│%s\n%s│%s\n%s│%s\n%s│%s\n%s\n' \
  "$(cell15 "|one")" "$(cell15 "|one")" \
  "$(cell15 "two")" "$(cell15 "two")" \
  "$(cell15 "three")" "$(cell15 "three")" \
  "$(cell15 "four")" "$(cell15 "four")" \
  "$blank" "$blank" \
  "$blank" "$blank" \
  "$pane_active" "$pane" \
  "$(foot 31 "close pane")" | cmp -s - "$out"

./edit --render-keys 8:31 x3x2x1 "$tmp" > "$out"
printf '|one\ntwo\nthree\nfour\n\n\n%s 1:1\n%s\n' "$base" "$(foot 31 "one pane")" | cmp -s - "$out"

python3 ./tui_view.py 6:30 '<c-x>2<c-x>o' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:4:1\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 5:30 '<c-x>3<c-x>o' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:16\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 5:20 '^v<m-v>' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:1\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

enter=$(printf '\r')
del=$(printf '\177')
printf 'one\ntwo\nthree\n' > "$tmp"
./edit --render-keys 5:12 "stwo$enter" "$tmp" > "$out"
printf 'one\n|two\nthree\n%s 2:1\n%s\n' "$base" "$(foot 12 "match two")" | cmp -s - "$out"

printf 'one two one two\n' > "$tmp"
./edit --render-keys 4:40 "stwo${enter}ss" "$tmp" > "$out"
printf 'one.two.one.|two\n\n%s 1:13\n%s\n' "$base" "$(foot 40 "match two")" | cmp -s - "$out"

./edit --render-keys 4:40 "stwo${enter}ssr" "$tmp" > "$out"
printf 'one.|two.one.two\n\n%s 1:5\n%s\n' "$base" "$(foot 40 "match two")" | cmp -s - "$out"

./edit --render-keys 4:40 "stwosf" "$tmp" > "$out"
printf 'one.t|wo.one.two\n\n%s 1:6\n%s\n' "$base" "$(foot 40 "match two")" | cmp -s - "$out"

./edit --render-keys 4:40 "stwo${enter}sss" "$tmp" > "$out"
printf 'one.|two.one.two\n\n%s 1:5\n%s\n' "$base" "$(foot 40 "match two")" | cmp -s - "$out"

./edit --render-keys 4:40 "stwo${enter}rr" "$tmp" > "$out"
printf 'one.two.one.|two\n\n%s 1:13\n%s\n' "$base" "$(foot 40 "match two")" | cmp -s - "$out"

./edit --render-keys-color 4:40 "stwo${enter}" "$tmp" > "$out"
printf 'one two one two\n\n\n' | cmp -s - "$out"

./edit --render-keys-color 4:40 "stwo${enter}ss" "$tmp" > "$out"
printf 'one %s[48;2;68;68;68mtwo%s[0m one %s[48;2;98;98;98mtwo%s[0m\n\n\n' \
  "$esc" "$esc" "$esc" "$esc" | cmp -s - "$out"

./edit --render-keys-color 4:40 "stwo${enter}ssr" "$tmp" > "$out"
printf 'one %s[48;2;98;98;98mtwo%s[0m one %s[48;2;68;68;68mtwo%s[0m\n\n\n' \
  "$esc" "$esc" "$esc" "$esc" | cmp -s - "$out"

./edit --render-keys-color 4:40 "stwosf" "$tmp" > "$out"
printf 'one two one two\n\n\n' | cmp -s - "$out"

printf '42 42\n' > "$tmp"
./edit --render-keys-color 3:40 "s42${enter}" "$tmp" > "$out"
printf '%s[38;2;120;220;255m42%s[0m %s[38;2;120;220;255m42%s[0m\n\n' \
  "$esc" "$esc" "$esc" "$esc" | cmp -s - "$out"

printf 'one\ntwo\nthree\n' > "$tmp"
./edit --render-keys 6:20 "stwosn" "$tmp" > "$out"
printf 'one\ntwo\n|three\n\n%s 3:1\n%s\n' "$base" "$(foot 20 "match two")" | cmp -s - "$out"

printf 'one two one two\n' > "$tmp"
./edit --render-keys-color 4:40 "stwo${enter}g" "$tmp" > "$out"
printf 'one two one two\n\n\n' | cmp -s - "$out"

printf 'two two\n' > "$tmp"
./edit --render-keys-color 4:40 "%two${enter}TWO${enter}!" "$tmp" > "$out"
printf 'TWO TWO\n\n\n' | cmp -s - "$out"

printf 'ab\n' > "$tmp"
python3 ./tui_view.py 4:30 '<right>^o^x^s' "$tmp" > "$out"
printf 'a\nb\n' | cmp -s - "$tmp"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:2\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

printf 'one one one\n' > "$tmp"
python3 ./tui_view.py 4:40 '<esc>%one
ONE
 ^g^x^s' "$tmp" > "$out"
printf 'ONE one one\n' | cmp -s - "$tmp"

printf 'one one one\n' > "$tmp"
python3 ./tui_view.py 4:40 '<esc>%one
ONE
n ^g^x^s' "$tmp" > "$out"
printf 'one ONE one\n' | cmp -s - "$tmp"

printf 'one one one\n' > "$tmp"
python3 ./tui_view.py 4:40 '<esc>%one
ONE
!^x^s' "$tmp" > "$out"
printf 'ONE ONE ONE\n' | cmp -s - "$tmp"

printf 'one one\n' > "$tmp"
python3 ./tui_view.py 4:40 '<opt-%>one
ONE
!^x^s' "$tmp" > "$out"
printf 'ONE ONE\n' | cmp -s - "$tmp"

printf 'foo bar\n' > "$tmp"
python3 ./tui_view.py 4:50 '<opt-%>foo bar^a<m-f>X' "$tmp" > "$out"
grep -q 'replace:.fooX.bar' "$out"

printf 'foo bar\n' > "$tmp"
python3 ./tui_view.py 4:50 '<opt-%>foo
bar baz^a<m-f>X' "$tmp" > "$out"
grep -q 'with:.barX.baz' "$out"

printf '* one *\n' > "$tmp"
python3 ./tui_view.py 4:40 '<esc>%*
X
!^x^s' "$tmp" > "$out"
printf 'X one X\n' | cmp -s - "$tmp"

printf '* one * two *\n' > "$tmp"
python3 ./tui_view.py 4:40 '<esc>%[*]
-
!^x^s' "$tmp" > "$out"
printf -- '- one - two -\n' | cmp -s - "$tmp"

i=0
: > "$tmp"
while [ "$i" -lt 1130 ]; do
  printf '* item\n' >> "$tmp"
  i=$((i + 1))
done
python3 ./tui_view.py 5:40 '<esc>%*
-
!<c-slash>^x^s' "$tmp" > "$out"
test "$(grep -c '^\* item$' "$tmp")" = 1130
if grep -q '^- item$' "$tmp"; then exit 1; fi

printf 'one one\n' > "$tmp"
python3 ./tui_view.py 4:40 '<c-c>^r<esc>%' "$tmp" > "$out"
grep -q 'read.only' "$out"

printf 'one two one two\n' > "$tmp"
./edit --render-keys 4:40 "stwogA" "$tmp" > "$out"
printf 'A|one.two.one.two\n\n%s* 1:2\n%s\n' "$base" "$(foot 40 "cancel")" | cmp -s - "$out"

printf 'abc\n' > "$tmp"
./edit --render-keys 4:40 xgA "$tmp" > "$out"
printf 'A|abc\n\n%s* 1:2\n%s\n' "$base" "$(foot 40 "cancel")" | cmp -s - "$out"

python3 ./tui_view.py 4:40 '^g<wait-status>' "$tmp" > "$out"
grep -q 'C-s/C-r.search,.C-g.cancel,.Esc.C-h.help' "$out"
if grep -q 'cancel\.\{10,\}C-h.help' "$out"; then exit 1; fi

printf 'abc\n' > "$tmp"
./edit --render-keys 4:20 X "$tmp" > "$out"
printf 'X|abc\n\n%s* 1:2\n%s\n' "$base" "$(foot 20 "")" | cmp -s - "$out"

printf 'abc\n' > "$tmp"
./edit --render-keys 4:20 X_ "$tmp" > "$out"
printf '|abc\n\n%s 1:1\n%s\n' "$base" "$(foot 20 "undo")" | cmp -s - "$out"

./edit --render-keys 4:20 X/ "$tmp" > "$out"
printf '|abc\n\n%s 1:1\n%s\n' "$base" "$(foot 20 "undo")" | cmp -s - "$out"

printf 'abc\n' > "$tmp"
python3 ./tui_view.py 4:40 'X<c-slash>^x^s' "$tmp" > "$out"
printf 'abc\n' | cmp -s - "$tmp"

./edit --render-keys 4:20 Xxu "$tmp" > "$out"
printf '|abc\n\n%s 1:1\n%s\n' "$base" "$(foot 20 "undo")" | cmp -s - "$out"

printf 'abc\n' > "$tmp"
python3 ./tui_view.py 4:40 'X^_^xr^x^s' "$tmp" > "$out"
printf 'Xabc\n' | cmp -s - "$tmp"
grep -q 'cursor:1:2' "$out"

printf 'abc\n' > "$tmp"
python3 ./tui_view.py 4:40 'XY^_^_^xr^xr^x^s' "$tmp" > "$out"
printf 'XYabc\n' | cmp -s - "$tmp"
grep -q 'cursor:1:3' "$out"

printf 'abc\n' > "$tmp"
python3 ./tui_view.py 4:40 '^xr' "$tmp" > "$out"
grep -q 'no.redo' "$out"

printf 'abc\n' > "$tmp"
python3 ./tui_view.py 4:40 'X^_Y^xr' "$tmp" > "$out"
grep -q 'Yabc' "$out"
grep -q 'no.redo' "$out"

printf 'abc\n' > "$tmp"
python3 ./tui_view.py 4:40 'X^_<c-c>^r^xr' "$tmp" > "$out"
grep -q 'read.only' "$out"

./edit --render-keys 4:20 "f${del}" "$tmp" > "$out"
printf '|bc\n\n%s* 1:1\n%s\n' "$base" "$(foot 20 "")" | cmp -s - "$out"

printf 'abcdef\nzz\n' > "$tmp"
python3 ./tui_view.py 5:30 '<right><right><right>^k^x^s' "$tmp" > "$out"
printf 'abc\nzz\n' | cmp -s - "$tmp"

printf 'abcdef\nzz\n' > "$tmp"
python3 ./tui_view.py 5:30 '^e^k^x^s' "$tmp" > "$out"
printf 'abcdefzz\n' | cmp -s - "$tmp"

printf 'abcdef\nzz\n' > "$tmp"
python3 ./tui_view.py 5:30 '<right><right><right>^k^y^x^s' "$tmp" > "$out"
printf 'abcdef\nzz\n' | cmp -s - "$tmp"

printf 'abcdef\nzz\n' > "$tmp"
python3 ./tui_view.py 5:30 '<right><right><right>^k^y^_^x^s' "$tmp" > "$out"
printf 'abc\nzz\n' | cmp -s - "$tmp"

printf 'abc\ndef\nzzz\n' > "$tmp"
python3 ./tui_view.py 5:40 '<right><right><right>^k^k^y^x^s' "$tmp" > "$out"
printf 'abc\ndef\nzzz\n' | cmp -s - "$tmp"

printf 'abc\ndef\n' > "$tmp"
python3 ./tui_view.py 5:40 '^k^n^k^y<m-y>^x^s' "$tmp" > "$out"
printf '\nabc\n' | cmp -s - "$tmp"

printf 'one\ntwo\nthree\n' > "$tmp"
python3 ./tui_view.py 6:40 '^k^n^k^n^k^y<m-y><m-y>^x^s' "$tmp" > "$out"
printf '\n\none\n' | cmp -s - "$tmp"

printf 'abc\ndef\n' > "$tmp"
python3 ./tui_view.py 5:40 '<right><right><right>^k^y<right><m-y>' "$tmp" > "$out"
grep -q 'no.yank' "$out"

printf 'aaa\nbb\n' > "$tmp"
python3 ./tui_view.py 5:40 '^k^n<c-space><right><right>^w^y<m-y>^x^s' "$tmp" > "$out"
printf '\naaa\n' | cmp -s - "$tmp"

printf 'abc\n' > "$tmp"
python3 ./tui_view.py 4:40 '<c-space><right><right>^w^x^s' "$tmp" > "$out"
printf 'c\n' | cmp -s - "$tmp"

printf 'abc\n' > "$tmp"
python3 ./tui_view.py 4:40 '<c-space><right><right>^w^y^x^s' "$tmp" > "$out"
printf 'abc\n' | cmp -s - "$tmp"

printf 'abc\n' > "$tmp"
python3 ./tui_view.py 4:40 '<c-space><right><right>^w^_^x^s' "$tmp" > "$out"
printf 'abc\n' | cmp -s - "$tmp"

if [ "$clip_has" = 1 ]; then
  printf 'abc\n' > "$tmp"
  python3 ./tui_view.py 4:40 '^k^x^s' "$tmp" > "$out"
  [ "$(pbpaste)" = "abc" ]

  printf 'abc\n' > "$tmp"
  python3 ./tui_view.py 4:40 '<c-space><right><right><m-w>^x^c' "$tmp" > "$out"
  printf 'abc\n' | cmp -s - "$tmp"
  [ "$(pbpaste)" = "ab" ]

  printf 'word next\n' > "$tmp"
  python3 ./tui_view.py 4:40 '<c-space><m-f><opt-w>^g^x^c' "$tmp" > "$out"
  printf 'word next\n' | cmp -s - "$tmp"
  [ "$(pbpaste)" = "word" ]

  printf 'abc\n' > "$tmp"
  printf 'CLIP' | pbcopy
  python3 ./tui_view.py 4:40 '^y^x^s' "$tmp" > "$out"
  printf 'CLIPabc\n' | cmp -s - "$tmp"

  printf 'abc\n' > "$tmp"
  printf 'CLIP' | pbcopy
  python3 ./tui_view.py 4:40 '^y^_^x^s' "$tmp" > "$out"
  printf 'abc\n' | cmp -s - "$tmp"

  printf 'abc\nCLIP\n' > "$tmp"
  printf 'CLIP' | pbcopy
  python3 ./tui_view.py 4:40 '^s^y
' "$tmp" > "$out"
  tail -n 1 "$out" > "$tmp.head"
  printf 'cursor:2:1\n' > "$tmp.expected"
  cmp -s "$tmp.expected" "$tmp.head"

  printf 'abc\n' > "$tmp"
  printf OLD | pbcopy
  python3 ./tui_view.py 4:80 '<c-x>^f^a^kabc<c-space><left><left><m-w>' "$tmp" > "$out"
  [ "$(pbpaste)" = "bc" ]

  printf 'abc\n' > "$tmp"
  printf OLD | pbcopy
  python3 ./tui_view.py 4:80 '<c-x>^f^a^kabc<c-space><left><left>^w' "$tmp" > "$out"
  [ "$(pbpaste)" = "bc" ]

  printf 'abc\n' > "$tmp"
  printf OLD | pbcopy
  python3 ./tui_view.py 4:80 '<c-x>^f^a^kabc^a^k' "$tmp" > "$out"
  [ "$(pbpaste)" = "abc" ]
fi

new_path="$dir/new-file.txt"
keys="<c-x>^f^a^k$new_path
^x^c"
python3 ./tui_view.py 4:80 "$keys" "$tmp" > "$out" || true
test ! -e "$new_path"

keys="<c-x>^f^a^k$new_path
^x^s"
python3 ./tui_view.py 4:80 "$keys" "$tmp" > "$out" || true
test -e "$new_path"

tree_path="$dir/missing/tree/new.txt"
keys="<c-x>^f^a^k$tree_path
n"
python3 ./tui_view.py 4:90 "$keys" "$tmp" > "$out"
grep -q 'create.canceled' "$out"
test ! -d "$dir/missing"

keys="<c-x>^f^a^k$tree_path
y"
python3 ./tui_view.py 4:90 "$keys" "$tmp" > "$out"
grep -q 'new.file.new.txt' "$out"
test -d "$dir/missing/tree"
rm -f "$new_path"
rm -rf "$dir/missing"

printf 'abc\n' > "$tmp"
python3 ./tui_view.py 4:80 '<c-x>^f^a^kabc<c-space><left><left>^w^y' "$tmp" > "$out"
grep -q 'find.file:.abc' "$out"

python3 ./tui_view.py 4:80 '<c-x>^f^a^kabc^a^k^y' "$tmp" > "$out"
grep -q 'find.file:.abc' "$out"

python3 ./tui_view.py 4:80 '^h<c-space><right><right>^w' "$tmp" > "$out"
grep -q 'copied' "$out"
grep -q '\*help\*' "$out"

i=0
while [ "$i" -lt 8 ]; do
  : > "$dir/aa_completion_$i"
  i=$((i + 1))
done
python3 ./tui_view.py 6:24 "<c-x>^f^a^k$dir/aa_completion_<tab><c-x>o<c-space><right><right>^w" "$tmp" > "$out"
grep -q 'copied' "$out"
grep -q '\*find.compl' "$out"
rm -f "$dir"/aa_completion_*

printf 'abc\nPASTE\n' > "$tmp"
python3 ./tui_view.py 4:40 '^s<paste>PASTE</paste>
' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:2:1\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

printf 'fooX bar\n' > "$tmp"
python3 ./tui_view.py 4:50 '^sfoo bar^a<m-f>X
' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:1\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

printf 'foo\n' > "$tmp"
python3 ./tui_view.py 4:50 '^sfoo bar<m-del>
' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:1\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

printf 'abc\n' > "$tmp"
python3 ./tui_view.py 4:40 '<raw><c-space><right>' "$tmp" > "$out"
grep -F -q "$(printf '\033[0;38;2;224;224;224;48;2;32;32;32;7m')" "$out"
grep -F -q "$(printf 'a\033[0;38;2;224;224;224;48;2;32;32;32mbc')" "$out"

printf 'multiline_str: str = """"\n' > "$tmp"
python3 ./tui_view.py 4:100 '<raw><c-space><right>' "$tmp" > "$out"
grep -F -q "$(printf '\033[0;38;2;224;224;224;48;2;32;32;32;7mm\033[0;38;2;224;224;224;48;2;32;32;32;38;2;255;215;95multiline_str')" "$out"

printf 'abc\n' > "$tmp"
./edit --render-keys 60:80 h "$tmp" > "$out"
grep -q '\*help\*' "$out"
grep -q 'C-c.x' "$out"
grep -q 'C-x.C-f' "$out"
grep -q 'C-s' "$out"
grep -q 'Esc.v' "$out"
grep -q 'Esc.w' "$out"
grep -q 'Esc.y' "$out"
grep -q 'C-/' "$out"
grep -q 'C-x.r' "$out"
grep -q 'C-x.C-c' "$out"

./edit --render-keys 4:20 hX "$tmp" > "$out"
printf '|edit.help\n\n*help* RO 1:1\n%s\n' "$(foot 20 "read only")" | cmp -s - "$out"

# Cancel leaves active help and restores the buffer and cursor it replaced.
for help_cancel in '^g' '<esc>'; do
  python3 ./tui_view.py 8:40 "<right>^h${help_cancel}" "$tmp" > "$out"
  grep -q 'cursor:1:2' "$out"
  if grep -q '\*help\*' "$out"; then exit 1; fi
done
python3 ./tui_view.py 8:40 '<right>^h^h^g' "$tmp" > "$out"
grep -q 'cursor:1:2' "$out"
python3 ./tui_view.py 8:40 '^h<c-x>3<c-x>o^g' "$tmp" > "$out"
[ "$(grep -c '\*help\*' "$out")" = 1 ]
grep -q 'cursor:1:21' "$out"

./edit --render-keys 4:20 fhxk "$tmp" > "$out"
printf 'a|bc\n\n%s 1:2\n%s\n' "$base" "$(foot 20 "killed")" | cmp -s - "$out"

./edit --render-keys 4:20 d_ "$tmp" > "$out"
printf 'a|bc\n\n%s 1:2\n%s\n' "$base" "$(foot 20 "undo")" | cmp -s - "$out"

./edit --render-keys 4:20 A_c__ "$tmp" > "$out"
printf '|abc\n\n%s 1:1\n%s\n' "$base" "$(foot 20 "no undo")" | cmp -s - "$out"

./edit --render-keys 4:20 Ac__ "$tmp" > "$out"
printf '|abc\n\n%s 1:1\n%s\n' "$base" "$(foot 20 "undo")" | cmp -s - "$out"

printf 'abcdefghijklmnopqrstuvwxyz\n' > "$tmp"
./edit --render-keys 4:12 fffffffffffff "$tmp" > "$out"
printf 'cdefghijklm|n\n\n%s 1:14\n%s\n' "$base" "$(foot 12 "")" | cmp -s - "$out"

./edit --render-keys 4:12 fffffffffffffbbbbbbbbbbbbb "$tmp" > "$out"
printf '|abcdefghijkl\n\n%s 1:1\n%s\n' "$base" "$(foot 12 "")" | cmp -s - "$out"

wrap="$dir/w"
printf 'abcdefghijklmnopqrstuvwxyz\n' > "$wrap"
python3 ./tui_view.py 5:12 '<c-c>^w' "$wrap" > "$out"
grep -q '02:mnopqrstuvwx' "$out"
grep -q '04:w.1:1.Wrap' "$out"

python3 ./tui_view.py 5:12 '<c-c>^w<c-c>^w<c-c>^w' "$wrap" > "$out"
grep -q '01:abcdefghijkl' "$out"
if grep -q 'Wrap' "$out"; then exit 1; fi

# Text files default to word wrapping at startup and through Find File.
for ext in md txt; do
  prose="$dir/prose.$ext"
  printf 'one two three four five\n' > "$prose"
  python3 ./tui_view.py 8:12 '' "$prose" > "$out"
  grep -q '02:three.four' "$out"
  ./edit --render 8:40 "$prose" > "$out"
  grep -q 'WordWrap' "$out"
  python3 ./tui_view.py 8:40 "^x^f^a^k$prose
" "$wrap" > "$out"
  grep -q 'WordWrap' "$out"
  python3 ./tui_view.py 8:40 '<c-c>^w' "$prose" > "$out"
  if grep -q 'Wrap' "$out"; then exit 1; fi
done

# Word wrapping preserves text and keeps movement on the displayed rows.
word_wrap="$dir/word-wrap"
printf 'one two three four five\n' > "$word_wrap"
python3 ./tui_view.py 8:12 '<c-c>^w<c-c>^w' "$word_wrap" > "$out"
grep -q '01:one.two' "$out"
grep -q '02:three.four' "$out"
grep -q '03:five' "$out"
python3 ./tui_view.py 8:12 '<c-c>^w<c-c>^w^n' "$word_wrap" > "$out"
grep -q 'cursor:2:1' "$out"
python3 ./tui_view.py 8:12 '<c-c>^w<c-c>^w<opt-gt><left>^e^p' "$word_wrap" > "$out"
grep -q 'cursor:2:5' "$out"
python3 ./tui_view.py 8:12 '<c-c>^w<c-c>^w<click:11:1>' "$word_wrap" > "$out"
grep -q 'cursor:1:8' "$out"
python3 ./tui_view.py 8:12 '<c-c>^w<c-c>^w<right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right><right>^n^p' "$word_wrap" > "$out"
grep -q 'cursor:2:10' "$out"

# Selection covers the whole buffer; uppercase is one undo group.
command_file="$dir/new-commands"
printf 'hello camelCase world\nsecond line\n' > "$command_file"
python3 ./tui_view.py 8:40 '<right><c-x>^p^w<c-x>^s' "$command_file" > "$out"
[ ! -s "$command_file" ]
printf 'hello camelCase world\n' > "$command_file"
python3 ./tui_view.py 8:40 '<right><esc>U<c-x>^s' "$command_file" > "$out"
printf 'hELLO camelCase world\n' | cmp -s - "$command_file"
python3 ./tui_view.py 8:40 '<right><right><right><right><right><right><esc>U<c-x>^s' "$command_file" > "$out"
printf 'hELLO CAMELCASE world\n' | cmp -s - "$command_file"
printf 'hello world\n' > "$command_file"
python3 ./tui_view.py 8:40 '<esc>U<c-x>u<c-x>^s' "$command_file" > "$out"
printf 'hello world\n' | cmp -s - "$command_file"
python3 ./tui_view.py 8:40 '<c-c>^r<esc>U' "$command_file" > "$out"
grep -q 'hello.world' "$out"

# Transposition handles point, line ends, UTF-8, undo, and read-only buffers.
transpose_file="$dir/transpose"
printf 'abcd\n' > "$transpose_file"
python3 ./tui_view.py 8:40 '<right>^t<c-x>^s' "$transpose_file" > "$out"
printf 'bacd\n' | cmp -s - "$transpose_file"
python3 ./tui_view.py 8:40 '^e^t<c-x>^s' "$transpose_file" > "$out"
printf 'badc\n' | cmp -s - "$transpose_file"
printf 'éλx' > "$transpose_file"
python3 ./tui_view.py 8:40 '<right>^t<c-x>^s' "$transpose_file" > "$out"
printf 'λéx' | cmp -s - "$transpose_file"
printf 'abcd\n' > "$transpose_file"
python3 ./tui_view.py 8:40 '<right>^t<c-slash><c-x>^s' "$transpose_file" > "$out"
printf 'abcd\n' | cmp -s - "$transpose_file"
python3 ./tui_view.py 8:40 '<right>^t<c-slash><c-x>r<c-x>^s' "$transpose_file" > "$out"
printf 'bacd\n' | cmp -s - "$transpose_file"
python3 ./tui_view.py 8:40 '<c-c>^r<right>^t' "$transpose_file" > "$out"
grep -q 'bacd' "$out"
printf 'x' > "$transpose_file"
python3 ./tui_view.py 8:40 '^e^t<c-x>^s' "$transpose_file" > "$out"
printf 'x' | cmp -s - "$transpose_file"

# Full-width rows keep a blank insertion point at EOF and before a newline.
wrap_edge="$dir/w-edge"
for wrap_keys in '<c-c>^w' '<c-c>^w<c-c>^w'; do
  printf 'abcdefghijklmnopqrstuvwx' > "$wrap_edge"
  python3 ./tui_view.py 5:12 "${wrap_keys}<opt-gt>" "$wrap_edge" > "$out"
  grep -q '^ 01:abcdefghijkl$' "$out"
  grep -q '^ 02:mnopqrstuvwx$' "$out"
  grep -q 'cursor:3:1' "$out"
  python3 ./tui_view.py 4:12 "${wrap_keys}<opt-gt>" "$wrap_edge" > "$out"
  grep -q '^ 01:mnopqrstuvwx$' "$out"
  grep -q 'cursor:2:1' "$out"
  printf '\n' >> "$wrap_edge"
  python3 ./tui_view.py 6:12 "${wrap_keys}<opt-gt><left>X" "$wrap_edge" > "$out"
  grep -q '^ 02:mnopqrstuvwx$' "$out"
  grep -q '^>03:X$' "$out"
  grep -q 'cursor:3:2' "$out"
done

# Wrapped line edges stay on the current display row in both wrap modes.
wrap_cursor="$dir/w-cursor"
printf 'abc defghi\n' > "$wrap_cursor"
for wrap_keys in '<c-c>^w' '<c-c>^w<c-c>^w'; do
  python3 ./tui_view.py 5:12 "${wrap_keys}<opt-gt><left>" "$wrap_cursor" > "$out"
  grep -q 'cursor:1:11' "$out"
  python3 ./tui_view.py 5:12 "${wrap_keys}<opt-gt><left>K" "$wrap_cursor" > "$out"
  grep -q '^>01:abc.defghiK$' "$out"
  grep -q 'cursor:1:12' "$out"
  python3 ./tui_view.py 5:12 "${wrap_keys}<opt-gt><left>KL" "$wrap_cursor" > "$out"
  grep -q 'cursor:2:' "$out"
done
for wrap_keys in '<c-c>^w' '<c-c>^w<c-c>^w'; do
  python3 ./tui_view.py 8:12 "${wrap_keys}^n^e" "$word_wrap" > "$out"
  edge_col=11
  if [ "$wrap_keys" = '<c-c>^w' ]; then edge_col=12; fi
  grep -q "cursor:2:$edge_col" "$out"
  python3 ./tui_view.py 8:12 "${wrap_keys}^n^e^a" "$word_wrap" > "$out"
  grep -q 'cursor:2:1' "$out"
done
python3 ./tui_view.py 8:12 '<c-c>^w<c-c>^w<opt-gt>^e' "$word_wrap" > "$out"
grep -q 'cursor:4:1' "$out"

# Font bindings emit the app command without modifying the document.
EDIT_APP=1 ./edit --render-keys 8:40 'x+x-x)' "$command_file" > "$out"
head -c 24 "$out" > "$tmp.head"
printf '\033[777;1t\033[777;2t\033[777;0t' | cmp -s - "$tmp.head"
./edit --render-keys 8:60 'x+' "$command_file" > "$out"
grep -q 'font.sizing.requires.Edit.app' "$out"

rights='<right><right><right><right><right><right><right><right><right><right><right><right><right>'
python3 ./tui_view.py 5:12 "<c-c>^w$rights" "$wrap" > "$out"
grep -q 'cursor:2:2' "$out"
grep -q '04:w.1:14.Wrap' "$out"

wrap_exact="$dir/w-exact"
printf 'abcdefghijklmnopqrstuvwx' > "$wrap_exact"
python3 ./tui_view.py 5:12 '<c-c>^w<opt-gt>' "$wrap_exact" > "$out"
grep -q 'cursor:3:1' "$out"
python3 ./tui_view.py 5:12 '<c-c>^w<opt-gt>X' "$wrap_exact" > "$out"
grep -q 'cursor:3:2' "$out"

wrap_partial="$dir/w-partial"
printf 'abcdefghijklmnopqrstuvwxy' > "$wrap_partial"
python3 ./tui_view.py 5:12 '<c-c>^w<opt-gt>' "$wrap_partial" > "$out"
grep -q 'cursor:3:2' "$out"
python3 ./tui_view.py 5:12 '<c-c>^w<opt-gt>X' "$wrap_partial" > "$out"
grep -q 'cursor:3:3' "$out"

printf '  alpha   beta gamma\ndelta epsilon zeta eta theta iota kappa lambda mu nu xi\n\nnext\n' > "$tmp"
./edit --render-keys 6:90 Q "$tmp" > "$out"
printf '..alpha.beta.gamma.delta.epsilon.zeta.eta.theta.iota.kappa.lambda.mu\n..nu.xi|\n\nnext\n%s* 2:8\n%s\n' \
  "$base" "$(foot 90 "fill paragraph")" | cmp -s - "$out"

md="$dir/plan.md"
printf '  alpha   beta gamma\ndelta epsilon zeta eta theta iota kappa lambda mu nu xi\n\nnext\n' > "$md"
./edit --render-keys 6:90 Q "$md" > "$out"
printf '..alpha.beta.gamma.delta.epsilon.zeta.eta.theta.iota.kappa.lambda.mu\n..nu.xi|\n\nnext\nplan.md* WordWrap 2:8\n%s\n' \
  "$(foot 90 "fill paragraph")" | cmp -s - "$out"

printf '# Title\n\n## Summary\n  alpha   beta gamma\ndelta epsilon zeta eta theta iota kappa lambda mu nu xi\n\nnext\n' > "$md"
./edit --render-keys 8:90 nnnQ "$md" > "$out"
printf '#.Title\n\n##.Summary\n..alpha.beta.gamma.delta.epsilon.zeta.eta.theta.iota.kappa.lambda.mu\n..nu.xi|\n\nplan.md* WordWrap 5:8\n%s\n' \
  "$(foot 90 "fill paragraph")" | cmp -s - "$out"

./edit --render-keys 6:90 Q_ "$tmp" > "$out"
printf '..alpha...beta.gamma\ndelta.epsilon.zeta.eta.theta.iota.kappa.lambda.mu.nu.xi|\n\nnext\n%s 2:56\n%s\n' \
  "$base" "$(foot 90 "undo")" | cmp -s - "$out"

python3 ./tui_view.py 6:80 '<c-c>^r<m-q>' "$tmp" > "$out"
grep -q 'read.only' "$out"

printf 'abc\n' > "$tmp"
python3 ./tui_view.py 4:40 '<c-c>^rX' "$tmp" > "$out"
grep -q '1:1.RO' "$out"
grep -q 'read.only' "$out"

python3 ./tui_view.py 4:40 '<c-c>^r<c-c>^rX' "$tmp" > "$out"
grep -q 'Xabc' "$out"

python3 ./tui_view.py 4:40 '<raw>' "$tmp" > "$out"
grep -F -q "$(printf '\033[?1007h')" "$out"
grep -F -q "$(printf '\033[?1000h')" "$out"
grep -F -q "$(printf '\033[?1006h')" "$out"
grep -F -q "$(printf '\033[38;2;224;224;224;48;2;32;32;32m')" "$out"
grep -F -q "$(printf '\033[2 q')" "$out"
grep -F -q "$(printf '\033[?12l')" "$out"

python3 ./tui_view.py 4:40 '<raw><c-x>^c' "$tmp" > "$out"
grep -F -q "$(printf '\033[?1006l')" "$out"
grep -F -q "$(printf '\033[?1000l')" "$out"
grep -F -q "$(printf '\033[?1007l')" "$out"

printf 'one\ntwo\nthree\n' > "$tmp"
python3 ./tui_view.py 4:40 '<wheel-down>' "$tmp" > "$out"
grep -q 'cursor:2:1' "$out"

python3 ./tui_view.py 4:40 '<down><wheel-up>' "$tmp" > "$out"
grep -q 'cursor:1:1' "$out"

python3 ./tui_view.py 4:40 '<wheel-x10-down>' "$tmp" > "$out"
grep -q 'cursor:2:1' "$out"

python3 ./tui_view.py 4:40 '<wheel-right>' "$tmp" > "$out"
grep -q 'cursor:1:2' "$out"

python3 ./tui_view.py 4:40 '<right><wheel-left>' "$tmp" > "$out"
grep -q 'cursor:1:1' "$out"

python3 ./tui_view.py 4:40 '<wheel-x10-right>' "$tmp" > "$out"
grep -q 'cursor:1:2' "$out"

python3 ./tui_view.py 4:40 '<right><wheel-shift-up>' "$tmp" > "$out"
grep -q 'cursor:1:1' "$out"

python3 ./tui_view.py 4:40 '<wheel-shift-down>' "$tmp" > "$out"
grep -q 'cursor:1:2' "$out"

python3 ./tui_view.py 4:40 '<wheel-x10-shift-down>' "$tmp" > "$out"
grep -q 'cursor:1:2' "$out"

printf 'abc\ndef\n' > "$tmp"
python3 ./tui_view.py 5:40 '<click:3:2>' "$tmp" > "$out"
grep -q 'cursor:2:3' "$out"

python3 ./tui_view.py 5:40 '<click-x10:2:1>' "$tmp" > "$out"
grep -q 'cursor:1:2' "$out"

printf 'abcdefghijklmnopqrstuvwxyz\n' > "$tmp"
python3 ./tui_view.py 5:25 '<c-c>^w<click:2:2>' "$tmp" > "$out"
grep -q 'cursor:2:2' "$out"
grep -q '1:27.Wrap' "$out"

printf 'int x\n' > "$tmp"
python3 ./tui_view.py 4:40 '<raw>' "$tmp" > "$out"
grep -F -q "$(printf '\033[0;38;2;224;224;224;48;2;32;32;32;38;2;150;190;255m')" "$out"

printf 'alpha\n' > "$tmp"
python3 ./tui_view.py 5:40 '<rewrite><right>' "$tmp" > "$out"
grep -q 'external.reload' "$out"

printf 'alpha\n' > "$tmp"
python3 ./tui_view.py 5:40 'X<rewrite><right>' "$tmp" > "$out"
grep -q 'Xalpha' "$out"
if grep -q 'external.reload' "$out"; then exit 1; fi

printf 'abc\n' > "$tmp"
python3 ./tui_view.py 5:50 'X^x^s' "$tmp" > "$out"
grep -q saved "$out"
printf 'Xabc\n' | cmp -s - "$tmp"

printf 'abc\n' > "$tmp"
python3 ./tui_view.py 5:50 '^x^c' "$tmp" > "$out"

python3 ./tui_view.py 5:50 'X^x^c' "$tmp" > "$out"
grep -q modified "$out"
grep -q again "$out"
printf 'abc\n' | cmp -s - "$tmp"

python3 ./tui_view.py 5:50 'X^_^x^c' "$tmp" > "$out"
if grep -q modified "$out"; then exit 1; fi

awk 'BEGIN { for (i = 1; i <= 400; i++) { printf "word%03d", i; if (i < 400) printf " " } }' > "$tmp.expected"
printf '' > "$tmp"
python3 ./tui_view.py 5:80 "<paste>$(cat "$tmp.expected")</paste>^x^s" "$tmp" > "$out"
cmp -s "$tmp.expected" "$tmp"

printf '' > "$tmp"
python3 ./tui_view.py 5:40 '<paste>a
b</paste>^x^s' "$tmp" > "$out"
printf 'a\nb' | cmp -s - "$tmp"

printf '' > "$tmp"
python3 ./tui_view.py 5:80 "<paste>$(cat "$tmp.expected")</paste>^_^x^s" "$tmp" > "$out"
printf '' | cmp -s - "$tmp"

printf 'caf\303\251 \342\230\203' > "$tmp.expected"
printf '' > "$tmp"
python3 ./tui_view.py 5:40 "<paste>$(cat "$tmp.expected")</paste>^x^s" "$tmp" > "$out"
cmp -s "$tmp.expected" "$tmp"

printf 'ab\342\200\234\342\200\235' > "$tmp"
python3 ./tui_view.py 5:40 '<opt-gt>' "$tmp" > "$out"
grep -q 'cursor:1:5' "$out"

printf 'ab\342\200\234\342\200\235X' > "$tmp.expected"
printf 'ab\342\200\234\342\200\235' > "$tmp"
python3 ./tui_view.py 5:40 '<opt-gt>X^x^s' "$tmp" > "$out"
cmp -s "$tmp.expected" "$tmp"

printf 'ab\342\200\234X\342\200\235' > "$tmp.expected"
printf 'ab\342\200\234\342\200\235' > "$tmp"
python3 ./tui_view.py 5:40 '<right><right><right>X^x^s' "$tmp" > "$out"
cmp -s "$tmp.expected" "$tmp"

printf 'ab\342\200\234X\342\200\235' > "$tmp.expected"
printf 'ab\342\200\234\342\200\235' > "$tmp"
python3 ./tui_view.py 5:40 '<opt-gt><left>X^x^s' "$tmp" > "$out"
cmp -s "$tmp.expected" "$tmp"

printf 'alpha\n' > "$dir/a"
printf 'beta\n' > "$dir/b"
printf 'gamma\n' > "$dir/gamma"
mkdir "$dir/sub"
printf 'child\n' > "$dir/sub/child"

python3 ./tui_view.py 5:200 '^x^f' "$dir/a" > "$out"
grep -Fq "find.file:.$dir/" "$out"
grep -q 'cursor:5:' "$out"

python3 ./tui_view.py 5:120 '^x^f' > "$out"
grep -q '\*scratch\*' "$out"
grep -Fq "find.file:.~/" "$out"

printf '' > "$recent"
launch_dir=$(cd "$dir" && pwd -P)
python3 ./tui_view.py 5:120 '^x^f' "$dir" > "$out"
grep -q '\*scratch\*' "$out"
grep -Fq "find.file:.$launch_dir/" "$out"
test ! -s "$recent"

python3 ./tui_view.py 5:80 '^x^f^a^kfoo bar^a<m-f>' "$dir/a" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:5:15\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 5:80 '^x^f^a^kfoo bar<m-del>' "$dir/a" > "$out"
grep -q 'find.file:.foo' "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:5:16\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

./edit --render-keys 5:30 xk "$dir/a" > "$out"
grep -q '\*scratch\*' "$out"

printf '%s\n' "$dir/b" > "$recent"
./edit --render-keys 5:50 "xf
" "$dir/a" > "$out"
sed -n '1p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *alpha*) ;; *) exit 1;; esac
grep -q 'open failed' "$out"

printf 'alpha\n' > "$dir/a"
./edit --render-keys 5:30 Xxk "$dir/a" > "$out"
printf 'Xalpha\n' | cmp -s - "$dir/a"

./edit --render-keys 5:160 xb "$dir/a" > "$out"
grep -q '\*buffers\*' "$out"
grep -Fq "$dir/a" "$out"

printf '%s\n' "$dir/b" > "$recent"
./edit --render-keys 5:160 "xf
xb
" "$dir/a" > "$out"
sed -n '1p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *alpha*) ;; *) exit 1;; esac

python3 ./tui_view.py 5:120 "^x^b^x^f$dir/gamma
" "$dir/a" > "$out"
sed -n '1p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *alpha*gamma*) ;; *) exit 1;; esac

printf 'gamut\n' > "$dir/gamut"
python3 ./tui_view.py 5:120 "^x^b^x^f$dir/ga<tab>" "$dir/a" > "$out"
grep -q 'gamma' "$out"
grep -q 'gamut' "$out"
rm -f "$dir/gamut"

printf '%s\n' "$dir/b" > "$recent"
python3 ./tui_view.py 5:80 '^x^f
<c-x>b' "$dir/a" > "$out"
sed -n '1p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *alpha*) ;; *) exit 1;; esac

python3 ./tui_view.py 5:100 "^x^fb
^x^fgamma
<c-x>b<c-x>3<c-x>o<c-x>b<c-x>b<c-x>o<c-x>b" "$dir/a" > "$out"
sed -n '1p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *beta*gamma*) ;; *) exit 1;; esac

printf 'alpha\n' > "$dir/a"
printf '%s\n' "$dir/b" > "$recent"
python3 ./tui_view.py 5:80 '<right>X^x^f
<c-x>b^_' "$dir/a" > "$out"
sed -n '1p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *alpha*) ;; *) exit 1;; esac
grep -q undo "$out"

test ! -e '*scratch*'
./edit --render-keys 5:40 "xkXxs" "$dir/a" > "$out"
grep -q 'scratch not saved' "$out"
test ! -e '*scratch*'

printf 'alpha\n' > "$dir/a"
printf '%s\n' "$dir/b" > "$recent"
python3 ./tui_view.py 5:50 '^x^f
' "$dir/a" > "$out"
sed -n '1p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *alpha*) ;; *) exit 1;; esac
grep -q "^$dir/a$" "$recent"
grep -q "^$dir/b$" "$recent"

printf '' > "$recent"
python3 ./tui_view.py 5:50 "^x^fb
" "$dir/a" > "$out"
sed -n '1p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *beta*) ;; *) exit 1;; esac

python3 ./tui_view.py 5:50 "^x^fga<tab>
" "$dir/a" > "$out"
sed -n '1p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *gamma*) ;; *) exit 1;; esac

printf 'source\n' > "$dir/alpha.c"
printf 'header\n' > "$dir/beta.c"
python3 ./tui_view.py 5:80 "^x^f.*[.]c<tab>" "$dir/a" > "$out"
grep -q 'alpha.c' "$out"
grep -q 'beta.c' "$out"

python3 ./tui_view.py 5:50 "^x^fg.*a
" "$dir/a" > "$out"
sed -n '1p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *gamma*) ;; *) exit 1;; esac

printf 'gamut\n' > "$dir/gamut"
python3 ./tui_view.py 5:80 "^x^fg.*
" "$dir/a" > "$out"
sed -n '1p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *alpha*) ;; *) exit 1;; esac
grep -q 'gamma' "$out"
grep -q 'gamut' "$out"
rm -f "$dir/gamut"

special_dir="$dir/a[bc]*"
mkdir "$special_dir"
printf 'start\n' > "$special_dir/start"
printf 'matched\n' > "$special_dir/only.c"
python3 ./tui_view.py 5:100 "^x^f.*[.]c
" "$special_dir/start" > "$out"
sed -n '1p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *matched*) ;; *) exit 1;; esac

python3 ./tui_view.py 5:50 "^x^fsu<tab>child
" "$dir/a" > "$out"
sed -n '1p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *child*) ;; *) exit 1;; esac

python3 ./tui_view.py 12:100 "^x^f<tab>" "$dir/a" > "$out"
grep -q 'gamma' "$out"
grep -q 'sub/' "$out"

for n in 1 2 3 4; do printf 'long-open\n' > "$dir/long_completion_name_$n"; done
python3 ./tui_view.py 8:60 "^x^flong_completion<tab>" "$dir/a" > "$out"
grep -q '\*find.completions\*' "$out"
grep -q 'long_completion_name_' "$out"
python3 ./tui_view.py 8:60 "^x^flong_completion<tab><c-x>o
" "$dir/a" > "$out"
grep -q 'long-open' "$out"
python3 ./tui_view.py 8:60 "^x^flong_completion<tab>^g^xb" "$dir/a" > "$out"
grep -q '\*find.completions\*' "$out"

# Completion keeps prompt focus, filters on edits, and preserves candidate selection.
# Long prompts scroll with the cursor in the real terminal footer.
python3 ./tui_view.py 5:40 '^x^f^a^kabcdefghijklmnopqrstuvwxyz0123456789' "$dir/a" > "$out"
grep -q 'find.file:.qrstuvwxyz0123456789.C-h.help' "$out"
grep -q '^cursor:5:32$' "$out"
python3 ./tui_view.py 5:40 '^x^f^a^kabcdefghijklmnopqrstuvwxyz0123456789^b^b^b' "$dir/a" > "$out"
grep -q 'find.file:.nopqrstuvwxyz01234567C-h.help' "$out"
python3 ./tui_view.py 5:40 '^x^f^a^kabcdefghijklmnopqrstuvwxyz0123456789^a' "$dir/a" > "$out"
grep -q 'find.file:.abcdefghijklmnopqrstuC-h.help' "$out"
grep -q '^cursor:5:12$' "$out"

# Open a completion whose full path exceeds the old 512-byte buffer.
long_dir="$dir/$(printf '%0200d' 1)/$(printf '%0200d' 2)"
long_name="$(printf '%0200d' 3).txt"
mkdir -p "$long_dir"
printf 'source\n' > "$long_dir/source"
printf 'complete long path\n' > "$long_dir/$long_name"
python3 ./tui_view.py 8:60 '^x^f<tab><c-x>o
' "$long_dir/source" > "$out"
grep -q 'complete.long.path' "$out"

find_dir="$dir/find-filter"
mkdir -p "$find_dir/alps" "$find_dir/zebra"
printf 'source\n' > "$find_dir/source"
printf 'alpha content\n' > "$find_dir/alpha.txt"
printf 'alpine content\n' > "$find_dir/alpine.txt"
: > "$find_dir/beta.txt"
# Narrow panes stack candidates; wider panes use two or four columns.
python3 ./tui_view.py 12:30 '^x^f<tab>' "$find_dir/source" > "$out"
grep -q '01:.*alps/' "$out"
grep -q '02:.*zebra/' "$out"
python3 ./tui_view.py 12:60 '^x^f<tab>' "$find_dir/source" > "$out"
grep -q '01:.*alps/.*alpha.txt' "$out"
grep -q '02:.*zebra/.*alpine.txt' "$out"
python3 ./tui_view.py 12:100 '^x^f<tab>' "$find_dir/source" > "$out"
grep -q '01:.*alps/.*zebra/.*alpha.txt.*beta.txt' "$out"
grep -q '02:.*alpine.txt.*source' "$out"
# First click focuses the list; a focused click opens the correct file column.
python3 ./tui_view.py 12:100 '^x^f<tab><click:67:1><click:67:1>' "$find_dir/source" > "$out"
grep -q 'alpha.content' "$out"
python3 ./tui_view.py 12:100 '^x^f<tab><c-x>o<click:79:1>' "$find_dir/source" > "$out"
grep -q 'opened.beta.txt' "$out"
python3 ./tui_view.py 12:100 '^x^f<tab><c-x>o^e
' "$find_dir/source" > "$out"
grep -q 'opened.beta.txt' "$out"
python3 ./tui_view.py 12:100 '^x^f<tab><c-x>o^e^n^a^p^a' "$find_dir/source" > "$out"
grep -q 'alps/' "$out"
grep -q 'alpha.txt' "$out"

python3 ./tui_view.py 12:100 '^x^f<tab><c-x>o<c-x>oal' "$find_dir/source" > "$out"
grep -q 'cursor:12:' "$out"

python3 ./tui_view.py 12:100 '^x^f<tab>al' "$find_dir/source" > "$out"
grep -q 'alps/' "$out"
grep -q 'alpha.txt' "$out"
grep -q 'alpine.txt' "$out"
if grep -q 'beta.txt\|zebra/\|read.only' "$out"; then exit 1; fi
grep -q 'cursor:12:' "$out"
# Paths appear only in the prompt, never beside candidate names.
if grep -q 'alpha.txt.*find-filter' "$out"; then exit 1; fi
python3 ./tui_view.py 12:100 '^x^f<tab>alpha.txt' "$find_dir/source" > "$out"
grep -q 'alpha.txt' "$out"
if grep -q 'alpine.txt\|alps/' "$out"; then exit 1; fi
python3 ./tui_view.py 12:100 '^x^f<tab>none' "$find_dir/source" > "$out"
if grep -q 'alpha.txt\|beta.txt\|zebra/' "$out"; then exit 1; fi
find_backspace=$(printf '\177')
python3 ./tui_view.py 12:100 "^x^f<tab>none${find_backspace}${find_backspace}${find_backspace}${find_backspace}" "$find_dir/source" > "$out"
grep -q 'beta.txt' "$out"
python3 ./tui_view.py 12:100 '^x^f<tab>alpha.txt
' "$find_dir/source" > "$out"
grep -q 'alpha.content' "$out"
python3 ./tui_view.py 12:100 '^x^f<tab>alpha<c-x>o
' "$find_dir/source" > "$out"
grep -q 'alpha.content' "$out"
python3 ./tui_view.py 12:100 '^x^f<tab><c-x>oal' "$find_dir/source" > "$out"
grep -q 'cursor:12:' "$out"
python3 ./tui_view.py 12:100 '^x^f<tab>al^g' "$find_dir/source" > "$out"
if grep -q '\*find.completions\*' "$out"; then exit 1; fi

# Directory selection refreshes the same pane and keeps its keyboard focus.
browse_dir="$dir/browse"
mkdir -p "$browse_dir/nested/deeper"
printf 'browse source\n' > "$browse_dir/source"
printf 'child content\n' > "$browse_dir/nested/child.txt"
printf 'leaf content\n' > "$browse_dir/nested/deeper/leaf.txt"
python3 ./tui_view.py 12:100 '^x^f<tab><c-x>o
' "$browse_dir/source" > "$out"
grep -q 'child.txt' "$out"
grep -q 'deeper/' "$out"
grep -q 'cursor:1:51' "$out"
[ "$(grep -c '\*find.completions\*' "$out")" = 1 ]
python3 ./tui_view.py 12:100 '^x^f<tab><click:51:1><click:51:1>' "$browse_dir/source" > "$out"
grep -q 'child.txt' "$out"
grep -q 'cursor:1:51' "$out"
python3 ./tui_view.py 12:100 '^x^f<tab><c-x>o

' "$browse_dir/source" > "$out"
grep -q 'leaf.txt' "$out"
grep -q 'cursor:1:51' "$out"
python3 ./tui_view.py 12:100 '^x^f<tab><c-x>o


' "$browse_dir/source" > "$out"
grep -q 'leaf.content' "$out"
python3 ./tui_view.py 12:100 '^x^f<tab><click:51:1><click:51:1><click:51:1><click:51:1>' "$browse_dir/source" > "$out"
grep -q 'leaf.content' "$out"
# Empty directories retain the candidate pane too.
mkdir "$browse_dir/nested/deeper/empty"
python3 ./tui_view.py 12:100 '^x^f<tab><c-x>o


' "$browse_dir/source" > "$out"
grep -q '\*find.completions\*' "$out"
grep -q 'cursor:1:51' "$out"
python3 ./tui_view.py 12:100 '^x^f<tab><c-x>o
^g' "$browse_dir/source" > "$out"
if grep -q '\*find.completions\*' "$out"; then exit 1; fi

printf '%s\n' "$dir/b" > "$recent"
printf 'alpha\n' > "$dir/a"
python3 ./tui_view.py 5:50 'X^x^f
' "$dir/a" > "$out"
sed -n '1p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *alpha*) ;; *) exit 1;; esac
printf 'alpha\n' | cmp -s - "$dir/a"

home="$dir/home"
mkdir "$home"
env -u EDIT_RECENT HOME="$home" python3 ./tui_view.py 5:50 '^x^f
' "$dir/a" > "$out"
test -s "$home/.edit/recent"
grep -q "^$dir/a$" "$home/.edit/recent"

run_home="$dir/run-home"
mkdir "$run_home"
mkdir "$run_home/.edit"
printf 'theme	dark\n' > "$run_home/.edit/config"
env SHELL=/bin/zsh HOME="$run_home" python3 ./tui_view.py 8:120 '^cxprintf command-output
' "$dir/a" > "$out"
grep -q 'command-output' "$out"
grep -q 'cursor:1:1' "$out"
grep -q "theme	dark" "$run_home/.edit/config"
grep -q "run	$dir/a	printf command-output" "$run_home/.edit/config"

run_prompt_home="$dir/run-prompt-home"
mkdir "$run_prompt_home"
env SHELL=/bin/zsh HOME="$run_prompt_home" python3 ./tui_view.py 8:120 '^cx^a^kecho two^a<m-f> one
' "$dir/a" > "$out"
grep -q 'one.two' "$out"

env SHELL=/bin/zsh HOME="$run_home" python3 ./tui_view.py 8:120 '^cx
' "$dir/a" > "$out"
grep -q 'cmd:.printf.command-output' "$out"

printf 'alpha\n' > "$dir/a"
dirty_home="$dir/dirty-home"
mkdir "$dirty_home"
env SHELL=/bin/zsh HOME="$dirty_home" python3 ./tui_view.py 8:120 'X^cxcat a
' "$dir/a" > "$out"
grep -q 'Xalpha' "$out"
printf 'Xalpha\n' | cmp -s - "$dir/a"

fail_home="$dir/fail-home"
mkdir "$fail_home"
env SHELL=/bin/zsh HOME="$fail_home" python3 ./tui_view.py 8:120 "^cxsh -c 'echo err >&2; exit 7'
" "$dir/a" > "$out"
grep -q 'err' "$out"
grep -q 'exit.7' "$out"

cap_home="$dir/cap-home"
mkdir "$cap_home"
env SHELL=/bin/zsh HOME="$cap_home" EDIT_RUN_OUTPUT_MAX=32 python3 ./tui_view.py 9:120 "^cxpython3 -c 'print(\"x\"*80)'
" "$dir/a" > "$out"
grep -q 'output.truncated' "$out"
grep -q 'exit.0' "$out"

cancel_run_home="$dir/cancel-run-home"
mkdir "$cancel_run_home"
env SHELL=/bin/zsh HOME="$cancel_run_home" python3 ./tui_view.py 9:120 "^cxpython3 -c 'import time; time.sleep(10)'
^g" "$dir/a" > "$out"
grep -q 'run.canceled' "$out"
grep -q 'exit.130' "$out"

cancel_home="$dir/cancel-home"
mkdir "$cancel_home"
env SHELL=/bin/zsh HOME="$cancel_home" python3 ./tui_view.py 5:80 '^cxprintf nope^g' "$dir/a" > "$out"
test ! -e "$cancel_home/.edit/config"

python3 ./tui_view.py 10:40 '<down><down><down><right><right>' test.sh > "$out"
printf ' 01:#!/bin/sh\n 02:set.-eu\n 03:\n>04:sh../build.sh\n 05:\n 06:tmp=$(mktemp)\n 07:base=${tmp##*/}\n' > "$tmp.expected"
head -n 7 "$out" > "$tmp.head"
cmp -s "$tmp.expected" "$tmp.head"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:4:3\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 10:40 '<down-o><down-o><down-o><right-o><right-o>' test.sh > "$out"
tail -n 1 "$out" > "$tmp.head"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 10:40 '<down-csi><down-csi><down-csi><right-csi><right-csi>' test.sh > "$out"
tail -n 1 "$out" > "$tmp.head"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 10:40 '<down><down>' test.sh > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:3:1\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 12:40 '<c-c>^w<right><right><right><right><right><right><right><right><right><right><right><right><right><right><down><down><down><down><down>' readme.md > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:6:15\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 12:28 '<c-c>^w<right><right><right><right><right><right><right><right><right><right><right><right><right><right><down><down><down><down><down>' readme.md > "$out"
tail -n 1 "$out" > "$tmp.head"
cmp -s "$tmp.expected" "$tmp.head"

review="$dir/review.txt"
printf 'alpha\nbeta\n' > "$review"
./edit --render-keys 7:60 'CeXCcok
xs' "$review" > "$out"
printf 'alpha\nbeta\n' | cmp -s - "$review"
grep -q '^EDIT-SUGGESTIONS 2$' "$review.edits"
grep -q '^proposed 12$' "$review.edits"
grep -q '^changes 1$' "$review.edits"
grep -q '^insert 0 1 ' "$review.edits"
grep -q '^comment 0 6 2$' "$review.edits"
grep -q '^ok$' "$review.edits"
grep -q '^selected 6$' "$review.edits"
grep -q '^Xalpha$' "$review.edits"
./edit --render 7:60 "$review" > "$out"
grep -q 'Xalpha' "$out"
./edit --render-keys 7:60 'Ca' "$review" > "$out"
printf 'Xalpha\nbeta\n' | cmp -s - "$review"
test ! -e "$review.edits"

./edit --render-keys 7:60 'CeYxs' "$review" > "$out"
printf 'Xalpha\nbeta\n' | cmp -s - "$review"
./edit --render-keys 7:60 'Cr' "$review" > "$out"
printf 'Xalpha\nbeta\n' | cmp -s - "$review"
test ! -e "$review.edits"

wrap_move="$dir/wrap-move"
printf 'abcdefghijklmnopqrstuvwxyz12345\n\nZYXWVUTSRQPONMLKJIHGFEDCBA98765\n' > "$wrap_move"
python3 ./tui_view.py 8:25 '<c-c>^w^n' "$wrap_move" > "$out"
grep -q '1:26.Wrap' "$out"
python3 ./tui_view.py 8:25 '<c-c>^w^n^n' "$wrap_move" > "$out"
grep -q '2:1.Wrap' "$out"
python3 ./tui_view.py 8:25 '<c-c>^w^n^n^n' "$wrap_move" > "$out"
grep -q '3:1.Wrap' "$out"
python3 ./tui_view.py 8:25 '<c-c>^w^n^n^n^n^p^p^p' "$wrap_move" > "$out"
grep -q '1:26.Wrap' "$out"

compose="$dir/comment-compose.txt"
printf 'alpha\n' > "$compose"
./edit --render-keys 7:23 'CeCcijkmotuwyzijkmotuwyzijkmotuwyzijkmotuwyzijkmotuwyz' "$compose" > "$out"
grep -q '^otuwyzijkmotuwyzijkmotu' "$out"
grep -q '^wyzijkmotuwyz|$' "$out"

printf 'abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz\n' > "$review"
./edit --render-keys 20:30 'CeXCcok
xs' "$review" > "$out"
python3 ./tui_view.py 20:30 '<c-c>^w<c-c>^w' "$review" > "$out"
test "$(grep -c 'ok' "$out")" = 1
grep -q 'Selected' "$out"

review_wrap="$dir/review-wrap.txt"
printf 'alpha\n' > "$review_wrap"
./edit --render-keys 14:30 'CeXCcijkmotuwyzijkmotuwyzijkmotuwyz
xs' "$review_wrap" > "$out"
python3 ./tui_view.py 14:29 '<c-c>^w<c-c>^w' "$review_wrap" > "$out"
grep -q 'ijkmotuwyzij' "$out"
grep -q 'kmotuwyzijkmot' "$out"
grep -q 'uwyz' "$out"

comment_mark="$dir/comment-mark.txt"
printf 'alpha\n' > "$comment_mark"
./edit --render-keys 8:50 $'Ce@ffCcok\n\027xs' "$comment_mark" > "$out"
grep -q '^proposed 6$' "$comment_mark.edits"

comment_align="$dir/comment-align.txt"
printf 'one\ntwo\nthree\n' > "$comment_align"
./edit --render-keys 12:60 'Ce@ffCcfirst
nn@ffCcsecond
xs' "$comment_align" > "$out"
python3 ./tui_view.py 12:60 '^n^n' "$comment_align" > "$out"
sed -n '3p' "$out" | grep -q '##.2..Comment'
python3 ./tui_view.py 12:60 '' "$comment_align" > "$out"
sed -n '1p' "$out" | grep -q '##.1..Comment'

# The nearest selected character controls both sidebar and source highlighting.
comment_nearest="$dir/comment-nearest.txt"
printf 'abcdefghijklmnopqrst----123456789\n' > "$comment_nearest"
./edit --render-keys 12:100 "Ce@$(printf 'f%.0s' $(seq 1 20))Cc111
$(printf 'f%.0s' $(seq 1 4))@$(printf 'f%.0s' $(seq 1 9))Cc222
xs" "$comment_nearest" > "$out"
python3 ./tui_view.py 12:100 "$(printf '^f%.0s' $(seq 1 21))" "$comment_nearest" > "$out"
sed -n '1p' "$out" | grep -q '##.1..Comment'
./edit --render-keys-color 5:100 "$(printf 'f%.0s' $(seq 1 21))" "$comment_nearest" > "$out"
grep -Fq "$(printf '%s[48;2;76;66;35mabcdefghijklmnopqrst' "$esc")" "$out"
python3 ./tui_view.py 12:100 "$(printf '^f%.0s' $(seq 1 22))" "$comment_nearest" > "$out"
grep -q '##.2..Comment' "$out"
./edit --render-keys-color 5:100 "$(printf 'f%.0s' $(seq 1 22))" "$comment_nearest" > "$out"
grep -Fq "$(printf '%s[48;2;76;66;35m123456789' "$esc")" "$out"

# The review is a normal read-only buffer; its search drives document selection.
cp "$comment_nearest" "$tmp.expected"
cp "$comment_nearest.edits" "$dir/review-expected.edits"
python3 ./tui_view.py 12:100 '^xo^s222
' "$comment_nearest" > "$out"
grep -q 'comment-nearest.txt.1:25.Suggested' "$out"
grep -q '\*Suggested.Changes\*.*RO.Wrap.>' "$out"
grep -q 'match.222' "$out"
python3 ./tui_view.py 12:100 '^xo^s222
^r111
' "$comment_nearest" > "$out"
grep -q 'comment-nearest.txt.1:1.Suggested' "$out"
python3 ./tui_view.py 12:100 '^xo^s222
X' "$comment_nearest" > "$out"
grep -q 'read.only' "$out"
cmp -s "$tmp.expected" "$comment_nearest"
cmp -s "$dir/review-expected.edits" "$comment_nearest.edits"
python3 ./tui_view.py 12:100 '^xo^x0' "$comment_nearest" > "$out"
if grep -q '\*Suggested.Changes\*' "$out"; then exit 1; fi
python3 ./tui_view.py 12:100 '^xo<c-c>]' "$comment_nearest" > "$out"
if grep -q '\*Suggested.Changes\*' "$out"; then exit 1; fi
comment_overlap="$dir/comment-overlap.txt"
printf 'abcdefghijklmnopqrst----123456789\n' > "$comment_overlap"
./edit --render-keys 12:100 "Ce@$(printf 'f%.0s' $(seq 1 10))Cc111
$(printf 'b%.0s' $(seq 1 5))@$(printf 'f%.0s' $(seq 1 15))Cc222
xs" "$comment_overlap" > "$out"
./edit --render-keys-color 5:100 "$(printf 'f%.0s' $(seq 1 23))" "$comment_overlap" > "$out"
grep -Fq "$(printf '%s[48;2;76;66;35mfghijklmnopqrst' "$esc")" "$out"

find_home="$dir/find-home"
mkdir "$find_home"
printf 'home file\n' > "$find_home/home.txt"
env HOME="$find_home" python3 ./tui_view.py 5:50 '^x^f' > "$out"
grep -q 'find.file:.~/' "$out"
env HOME="$find_home" python3 ./tui_view.py 5:50 '^x^fhome.txt
' > "$out"
grep -q 'home.file' "$out"

# Rendering reaches past the old line and syntax-span limits.
printf '%09000dTAIL\n' 0 > "$dir/long-line"
./edit --render-keys-color 5:80 e "$dir/long-line" > "$out"
grep -q 'TAIL' "$out"
printf 'style keyword 33\nword keyword int\n' > "$tmp.grammar"
printf '%s\n' "$(printf 'int %.0s' $(seq 1 300))" > "$dir/many-spans.c"
EDIT_GRAMMAR="$tmp.grammar" ./edit --render-keys-color 5:80 e "$dir/many-spans.c" > "$out"
grep -Fq "$(printf '%s[33mint' "$esc")" "$out"

# A long grammar record loads as one record; oversized fields fail explicitly.
printf 'style keyword 33\nword keyword %s TAIL\n' "$(printf 'word %.0s' $(seq 1 120))" > "$tmp.grammar"
printf 'TAIL\n' > "$dir/grammar-tail.txt"
EDIT_GRAMMAR="$tmp.grammar" ./edit --render-color 3:80 "$dir/grammar-tail.txt" > "$out"
grep -Fq "$(printf '%s[33mTAIL' "$esc")" "$out"
printf 'style keyword 33\nrule keyword %0300d\n' 0 > "$tmp.grammar"
EDIT_GRAMMAR="$tmp.grammar" ./edit --render-color 3:80 "$dir/grammar-tail.txt" > "$out" 2> "$tmp.head"
grep -q 'invalid or unreadable grammar' "$tmp.head"

# Paste rejection is atomic, including when a prompt selection is active.
oversized=$(printf '%0200d' 0)
python3 ./tui_view.py 5:60 "^skeep^a<c-space>^e<paste>$oversized</paste>" "$dir/a" > "$out"
grep -q 'input.too.long' "$out"
python3 ./tui_view.py 5:60 "^skeep<paste>$oversized</paste>
" "$dir/a" > "$out"
grep -q 'input.too.long' "$out"
python3 ./tui_view.py 5:60 "^skeep<paste>$oversized</paste><left>$(printf '\177')
" "$dir/a" > "$out"
if grep -q 'input.too.long' "$out"; then exit 1; fi
python3 ./tui_view.py 5:60 "^skeep^a<c-space>^e<paste>$oversized</paste>^b" "$dir/a" > "$out"
grep -q 'search:.keep' "$out"
python3 ./tui_view.py 5:50 '^s<paste>éééééééééééééééééééééééééééééééé</paste>' "$dir/a" > "$out"
grep -q '^cursor:5:41$' "$out"

# Long saved records cannot become shortened commands or extra recent paths.
audit_home="$dir/audit-home"
mkdir -p "$audit_home/.edit"
printf 'run\t%s\tprintf unsafe%01100d\n' "$dir/a" 0 > "$audit_home/.edit/config"
env HOME="$audit_home" python3 ./tui_view.py 5:60 '<c-c>x' "$dir/a" > "$out"
grep -q 'saved.command.too.long' "$out"
printf 'custom\t%03000d\n' 0 > "$tmp.expected"
cp "$tmp.expected" "$audit_home/.edit/config"
env HOME="$audit_home" SHELL=/bin/zsh python3 ./tui_view.py 8:80 '<c-c>xprintf safe
' "$dir/a" > "$out"
head -n 1 "$audit_home/.edit/config" > "$tmp.head"
cmp -s "$tmp.expected" "$tmp.head"
printf '%02000d\n%s\n' 0 "$dir/b" > "$recent"
python3 ./tui_view.py 5:60 '' "$dir/a" > "$out"
printf '%s\n%s\n' "$dir/a" "$dir/b" > "$tmp.expected"
cmp -s "$tmp.expected" "$recent"

# Reviews retain long text and sections after the old 256-row limit.
printf 'alpha\n' > "$dir/long-review.txt"
review_text="$(printf '%0350d' 0)REVIEWTAIL"
python3 ./tui_view.py 20:120 "<c-c>e<paste>$review_text</paste>^x^s" "$dir/long-review.txt" > "$out"
python3 ./tui_view.py 20:120 '' "$dir/long-review.txt" > "$out"
grep -q 'EWTAILalpha' "$out"
grep -q 'REVIEWTA' "$out"
review_keys=Ce
review_move=
i=0
: > "$dir/many-reviews.txt"
while [ "$i" -lt 60 ]; do
  printf 'alpha\n' >> "$dir/many-reviews.txt"
  review_keys="${review_keys}Xn"
  review_move="${review_move}^n"
  i=$((i + 1))
done
printf 'last\n' >> "$dir/many-reviews.txt"
./edit --render-keys 8:60 "${review_keys}Cc987654321
xs" "$dir/many-reviews.txt" > "$out"
python3 ./tui_view.py 20:120 "${review_move}^l" "$dir/many-reviews.txt" > "$out"
grep -q '##.61..Comment' "$out"
# Review search scrolls the document to a distant section; document navigation returns it.
python3 ./tui_view.py 12:100 '^xo^s987654321
' "$dir/many-reviews.txt" > "$out"
grep -q 'many-reviews.txt.61:1.Suggested' "$out"
grep -q '##.61..Comment' "$out"
python3 ./tui_view.py 12:100 '^xo^s987654321
^xo<esc><' "$dir/many-reviews.txt" > "$out"
grep -q 'many-reviews.txt.1:1.Suggested' "$out"
grep -q '##.1..Add' "$out"

printf 'ok\n'
