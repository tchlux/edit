// ___________________________________________________________________
//                            edit.c
//
// DESCRIPTION
//  A small C11 terminal text editor with Emacs-like keybindings and
//  batch editing commands for shell and language-model use.
//
// USAGE
//    edit file
//    edit --print  line:col..line:col file
//    edit --insert line:col text file
//    edit --delete line:col..line:col file
//    edit --replace line:col..line:col text file
//    edit --search line:col regex file
//    edit --render rows:cols file
//    edit --render-at rows:cols line:col file
//    edit --render-keys rows:cols keys file
//    edit --render-color rows:cols file
//
// COMPILATION
//    cc -std=c11 -Wall -Wextra -pedantic -O2 -o edit edit.c grammar.c regex.c
// ___________________________________________________________________

#include "grammar.h"

#include <ctype.h>
#include <errno.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

void match(const char * regex, const char * string, int * start, int * end);

#define KEY_CTRL(c) ((c) & 0x1f)
#define KEY_META(c) (2000 + (c))
#define KEY_BACKSPACE 127
#define KEY_ENTER 13
#define KEY_ESC 27
#define KEY_UP 1000
#define KEY_DOWN 1001
#define KEY_RIGHT 1002
#define KEY_LEFT 1003
#define GAP_SIZE 4096
#define STATUS_SIZE 160
#define LINE_RENDER_MAX 8192
#define HISTORY_MAX 1024

enum { HIST_INSERT, HIST_DELETE };
enum { LAYOUT_ROWS, LAYOUT_COLS };

typedef struct {
  char * data;
  char * path;
  size_t cap;
  size_t gap_a;
  size_t gap_b;
  bool dirty;
} buffer;

typedef struct {
  int buffer;
  // Cursor positions are byte offsets between bytes in the logical buffer.
  size_t cursor;
  size_t top;
  size_t preferred_col;
  int recenter;
} pane;

typedef struct {
  char * data;
  size_t len;
  size_t cap;
} output;

typedef struct {
  int kind;
  size_t pos;
  size_t len;
  char * text;
  unsigned group;
} history;

typedef struct edit_state edit_state;
typedef int (*command_fn)(edit_state * e, int key);

typedef struct {
  int keys[2];
  int n_keys;
  command_fn fn;
} binding;

struct edit_state {
  buffer buffers[8];
  pane panes[8];
  int n_buffers;
  int n_panes;
  int active_pane;
  int layout;
  int rows;
  int cols;
  int prefix;
  bool search_prompt;
  char search[STATUS_SIZE];
  size_t search_len;
  char status[STATUS_SIZE];
  bool quit;
  bool quit_confirm;
  bool raw;
  history history[HISTORY_MAX];
  int n_history;
  int undo_at;
  unsigned history_group;
  struct termios saved_termios;
  grammar grammar;
  bool has_grammar;
};

static char * _dup(const char * s) {
  size_t n = strlen(s) + 1;
  char * out = malloc(n);
  if (out != NULL) memcpy(out, s, n);
  return out;
}

static size_t buffer_len(buffer * b) {
  return b->cap - (b->gap_b - b->gap_a);
}

static char buffer_at(buffer * b, size_t i) {
  return (i < b->gap_a) ? b->data[i] : b->data[i + (b->gap_b - b->gap_a)];
}

static void buffer_free(buffer * b);

static int buffer_blank(buffer * b, const char * path) {
  b->cap = GAP_SIZE;
  b->data = calloc(b->cap, 1);
  b->path = _dup(path);
  if (b->data == NULL || b->path == NULL) {
    buffer_free(b);
    return -1;
  }
  b->gap_a = 0;
  b->gap_b = b->cap;
  b->dirty = false;
  return 0;
}

static int buffer_load(buffer * b, const char * path) {
  FILE * f = fopen(path, "rb");
  if (f == NULL) {
    if (errno == ENOENT) return buffer_blank(b, path);
    return -1;
  }

  if (fseek(f, 0, SEEK_END) != 0) {
    fclose(f);
    return -1;
  }
  long n = ftell(f);
  if (n < 0) {
    fclose(f);
    return -1;
  }
  rewind(f);

  b->cap = (size_t) n + GAP_SIZE;
  b->data = malloc(b->cap);
  b->path = _dup(path);
  if (b->data == NULL || b->path == NULL) {
    buffer_free(b);
    fclose(f);
    return -1;
  }
  b->gap_a = 0;
  b->gap_b = GAP_SIZE;
  if (fread(b->data + b->gap_b, 1, (size_t) n, f) != (size_t) n) {
    buffer_free(b);
    fclose(f);
    return -1;
  }
  fclose(f);

  b->dirty = false;
  return 0;
}

static void buffer_free(buffer * b) {
  free(b->data);
  free(b->path);
  memset(b, 0, sizeof(*b));
}

static int buffer_save(buffer * b) {
  size_t n = strlen(b->path) + 12;
  char * tmp = malloc(n);
  if (tmp == NULL) return -1;
  snprintf(tmp, n, "%s.tmp.XXXXXX", b->path);

  int fd = mkstemp(tmp);
  if (fd < 0) {
    free(tmp);
    return -1;
  }

  FILE * f = fdopen(fd, "wb");
  if (f == NULL) {
    close(fd);
    unlink(tmp);
    free(tmp);
    return -1;
  }
  if (fwrite(b->data, 1, b->gap_a, f) != b->gap_a) {
    fclose(f);
    unlink(tmp);
    free(tmp);
    return -1;
  }
  size_t tail = b->cap - b->gap_b;
  if (fwrite(b->data + b->gap_b, 1, tail, f) != tail) {
    fclose(f);
    unlink(tmp);
    free(tmp);
    return -1;
  }
  if (fclose(f) != 0 || rename(tmp, b->path) != 0) {
    unlink(tmp);
    free(tmp);
    return -1;
  }
  free(tmp);
  b->dirty = false;
  return 0;
}

static int buffer_gap(buffer * b, size_t need) {
  if (b->gap_b - b->gap_a >= need) return 0;

  size_t len = buffer_len(b);
  size_t cap = b->cap * 2 + need + GAP_SIZE;
  char * data = malloc(cap);
  if (data == NULL) return -1;

  size_t tail = b->cap - b->gap_b;
  memcpy(data, b->data, b->gap_a);
  memcpy(data + cap - tail, b->data + b->gap_b, tail);
  free(b->data);
  b->data = data;
  b->cap = cap;
  b->gap_b = cap - tail;
  return (buffer_len(b) == len) ? 0 : -1;
}

static void buffer_move_gap(buffer * b, size_t pos) {
  size_t len = buffer_len(b);
  if (pos > len) pos = len;

  if (pos < b->gap_a) {
    size_t n = b->gap_a - pos;
    memmove(b->data + b->gap_b - n, b->data + pos, n);
    b->gap_a = pos;
    b->gap_b -= n;
  } else if (pos > b->gap_a) {
    size_t n = pos - b->gap_a;
    memmove(b->data + b->gap_a, b->data + b->gap_b, n);
    b->gap_a += n;
    b->gap_b += n;
  }
}

static int buffer_insert(buffer * b, size_t pos, const char * s, size_t n) {
  buffer_move_gap(b, pos);
  if (buffer_gap(b, n) != 0) return -1;
  memcpy(b->data + b->gap_a, s, n);
  b->gap_a += n;
  b->dirty = true;
  return 0;
}

static void buffer_delete(buffer * b, size_t start, size_t end) {
  size_t len = buffer_len(b);
  if (start > len) start = len;
  if (end > len) end = len;
  if (end < start) end = start;
  buffer_move_gap(b, start);
  b->gap_b += end - start;
  b->dirty = true;
}

static int buffer_search(buffer * b, size_t from, const char * regex,
                         size_t * start, size_t * end) {
  size_t len = buffer_len(b);
  if (from > len) from = len;
  char * text = malloc(len - from + 1);
  if (text == NULL) return -1;
  for (size_t i = from; i < len; i++) text[i - from] = buffer_at(b, i);
  text[len - from] = '\0';

  int a = -1;
  int z = -1;
  match(regex, text, &a, &z);
  free(text);
  if (a < 0) return 0;
  *start = from + (size_t) a;
  *end = from + (size_t) z;
  return 1;
}

static size_t line_start(buffer * b, size_t pos) {
  while ((pos > 0) && (buffer_at(b, pos - 1) != '\n')) pos--;
  return pos;
}

static size_t line_end(buffer * b, size_t pos) {
  size_t len = buffer_len(b);
  while ((pos < len) && (buffer_at(b, pos) != '\n')) pos++;
  return pos;
}

static size_t next_line(buffer * b, size_t pos) {
  size_t len = buffer_len(b);
  while ((pos < len) && (buffer_at(b, pos) != '\n')) pos++;
  return (pos < len) ? pos + 1 : len;
}

static size_t prev_line(buffer * b, size_t pos) {
  pos = line_start(b, pos);
  return (pos == 0) ? 0 : line_start(b, pos - 1);
}

static size_t line_column(buffer * b, size_t start, size_t preferred) {
  size_t end = line_end(b, start);
  size_t len = end - start;
  return start + ((preferred > len) ? len : preferred);
}

static size_t line_col_pos(buffer * b, size_t line, size_t col) {
  size_t pos = 0;
  if (line == 0 || col == 0) return SIZE_MAX;

  for (size_t l = 1; l < line; l++) {
    size_t n = next_line(b, pos);
    if (n == pos) return SIZE_MAX;
    pos = n;
  }
  for (size_t c = 1; c < col && pos < buffer_len(b); c++) {
    if (buffer_at(b, pos) == '\n') break;
    pos++;
  }
  return pos;
}

static void pos_line_col(buffer * b, size_t pos, size_t * line, size_t * col) {
  *line = 1;
  *col = 1;
  for (size_t i = 0; i < pos && i < buffer_len(b); i++) {
    if (buffer_at(b, i) == '\n') {
      (*line)++;
      *col = 1;
    } else {
      (*col)++;
    }
  }
}

static int parse_point(const char * s, size_t * pos, buffer * b) {
  char * end = NULL;
  size_t line = (size_t) strtoull(s, &end, 10);
  if (end == s || *end != ':') return -1;
  size_t col = (size_t) strtoull(end + 1, &end, 10);
  if (*end != '\0') return -1;
  *pos = line_col_pos(b, line, col);
  return (*pos == SIZE_MAX) ? -1 : 0;
}

static int parse_range(const char * s, size_t * start, size_t * end, buffer * b) {
  char copy[128];
  snprintf(copy, sizeof(copy), "%s", s);
  char * split = strstr(copy, "..");
  if (split == NULL) return -1;
  *split = '\0';
  return parse_point(copy, start, b) || parse_point(split + 2, end, b);
}

static char * read_stdin(size_t * n) {
  size_t cap = 4096;
  char * s = malloc(cap);
  if (s == NULL) return NULL;
  *n = 0;

  for (;;) {
    if (*n == cap) {
      cap *= 2;
      char * next = realloc(s, cap);
      if (next == NULL) {
        free(s);
        return NULL;
      }
      s = next;
    }
    size_t got = fread(s + *n, 1, cap - *n, stdin);
    *n += got;
    if (got == 0) break;
  }
  return s;
}

static void out_add(output * o, const char * s, size_t n) {
  if (o->len + n + 1 > o->cap) {
    size_t cap = (o->cap == 0) ? 4096 : o->cap * 2;
    while (cap < o->len + n + 1) cap *= 2;
    char * data = realloc(o->data, cap);
    if (data == NULL) return;
    o->data = data;
    o->cap = cap;
  }
  memcpy(o->data + o->len, s, n);
  o->len += n;
  o->data[o->len] = '\0';
}

static void out_s(output * o, const char * s) {
  out_add(o, s, strlen(s));
}

static void out_f(output * o, const char * fmt, ...) {
  char buf[128];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  if (n > 0) out_add(o, buf, (size_t) n);
}

static void set_status(edit_state * e, const char * fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(e->status, sizeof(e->status), fmt, ap);
  va_end(ap);
}

static void out_clip(output * o, const char * s, size_t * used, size_t limit) {
  for (size_t i = 0; s[i] != '\0' && *used < limit; i++, (*used)++)
    out_add(o, &s[i], 1);
}

static buffer * active_buffer(edit_state * e) {
  return &e->buffers[e->panes[e->active_pane].buffer];
}

static pane * active_pane(edit_state * e) {
  return &e->panes[e->active_pane];
}

static buffer * pane_buffer(edit_state * e, pane * p) {
  return &e->buffers[p->buffer];
}

static void history_free_one(history * h) {
  free(h->text);
  memset(h, 0, sizeof(*h));
}

static void history_free(edit_state * e) {
  for (int i = 0; i < e->n_history; i++) history_free_one(&e->history[i]);
  e->n_history = 0;
  e->undo_at = 0;
}

static void history_drop_oldest_group(edit_state * e) {
  if (e->n_history == 0) return;
  unsigned group = e->history[0].group;
  int n = 0;
  while (n < e->n_history && e->history[n].group == group) n++;
  for (int i = 0; i < n; i++) history_free_one(&e->history[i]);
  memmove(e->history, e->history + n, (size_t) (e->n_history - n) * sizeof(history));
  e->n_history -= n;
  e->undo_at = (e->undo_at > n) ? e->undo_at - n : 0;
}

static int history_add(edit_state * e, int kind, size_t pos,
                       const char * text, size_t len, unsigned group) {
  while (e->n_history >= HISTORY_MAX) history_drop_oldest_group(e);
  history * h = &e->history[e->n_history];
  h->text = malloc(len ? len : 1);
  if (h->text == NULL) return -1;
  if (len) memcpy(h->text, text, len);
  h->kind = kind;
  h->pos = pos;
  h->len = len;
  h->group = group;
  e->n_history++;
  return 0;
}

static int edit_insert(edit_state * e, size_t pos, const char * text,
                       size_t len, unsigned group, bool reset_undo) {
  if (len == 0) return 0;
  if (buffer_insert(active_buffer(e), pos, text, len) != 0) return -1;
  for (int i = 0; i < e->n_panes; i++) {
    if (i == e->active_pane) continue;
    if (e->panes[i].cursor >= pos) e->panes[i].cursor += len;
    if (e->panes[i].top > pos) e->panes[i].top += len;
  }
  if (history_add(e, HIST_INSERT, pos, text, len, group) != 0) return -1;
  if (reset_undo) e->undo_at = e->n_history;
  return 0;
}

static int edit_delete(edit_state * e, size_t start, size_t end,
                       unsigned group, bool reset_undo) {
  buffer * b = active_buffer(e);
  size_t len = buffer_len(b);
  if (start > len) start = len;
  if (end > len) end = len;
  if (end <= start) return 0;

  size_t n = end - start;
  char * text = malloc(n);
  if (text == NULL) return -1;
  for (size_t i = 0; i < n; i++) text[i] = buffer_at(b, start + i);
  buffer_delete(b, start, end);
  for (int i = 0; i < e->n_panes; i++) {
    pane * p = &e->panes[i];
    if (i == e->active_pane) continue;
    if (p->cursor > start) p->cursor = (p->cursor >= end) ? p->cursor - n : start;
    if (p->top > start) p->top = (p->top >= end) ? p->top - n : start;
  }
  int rc = history_add(e, HIST_DELETE, start, text, n, group);
  free(text);
  if (rc != 0) return -1;
  if (reset_undo) e->undo_at = e->n_history;
  return 0;
}

static int dispatch(edit_state * e, int key);

static void load_grammar(edit_state * e) {
  const char * gp = getenv("EDIT_GRAMMAR");
  if (gp != NULL) e->has_grammar = grammar_load(&e->grammar, gp) == 0;
  else {
    grammar_load_default(&e->grammar);
    e->has_grammar = true;
  }
}

static void get_window_size(edit_state * e) {
  struct winsize ws;
  if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0) {
    e->rows = ws.ws_row;
    e->cols = ws.ws_col;
  } else {
    e->rows = 24;
    e->cols = 80;
  }
}

static int raw_on(edit_state * e) {
  if (tcgetattr(STDIN_FILENO, &e->saved_termios) != 0) return -1;
  struct termios raw = e->saved_termios;
  raw.c_iflag &= (tcflag_t) ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
  raw.c_oflag &= (tcflag_t) ~(OPOST);
  raw.c_cflag |= CS8;
  raw.c_lflag &= (tcflag_t) ~(ECHO | ICANON | IEXTEN | ISIG);
  raw.c_cc[VMIN] = 1;
  raw.c_cc[VTIME] = 0;
  if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) != 0) return -1;
  e->raw = true;
  return 0;
}

static int read_key(void) {
  char c;
  if (read(STDIN_FILENO, &c, 1) != 1) return -1;
  if ((unsigned char) c != KEY_ESC) return (unsigned char) c;

  char seq[32];
  int n = 0;
  fd_set set;
  while (n < (int) sizeof(seq)) {
    struct timeval tv = {0, 20000};
    FD_ZERO(&set);
    FD_SET(STDIN_FILENO, &set);
    if (select(STDIN_FILENO + 1, &set, NULL, NULL, &tv) != 1) break;
    if (read(STDIN_FILENO, &seq[n], 1) != 1) break;
    n++;
    if ((n == 1) && ((seq[0] != '[') && (seq[0] != 'O'))) break;
    if ((seq[0] == 'O') && (n == 2)) break;
    if ((seq[0] == '[') && (n > 1) &&
        (seq[n-1] >= '@') && (seq[n-1] <= '~')) {
      break;
    }
  }

  if (n == 1) return KEY_META((unsigned char) seq[0]);
  if (n < 2) return KEY_ESC;
  char final = seq[n-1];
  if ((seq[0] == '[') || (seq[0] == 'O')) {
    if (final == 'A') return KEY_UP;
    if (final == 'B') return KEY_DOWN;
    if (final == 'C') return KEY_RIGHT;
    if (final == 'D') return KEY_LEFT;
  }
  return KEY_ESC;
}

static void raw_off(edit_state * e) {
  if (e->raw) tcsetattr(STDIN_FILENO, TCSAFLUSH, &e->saved_termios);
  e->raw = false;
}

static int pane_body_rows(edit_state * e, int i) {
  if (e->layout == LAYOUT_COLS) return (e->rows > 1) ? e->rows - 1 : 1;
  int total = e->rows - e->n_panes;
  if (total < e->n_panes) return 1;
  return total / e->n_panes + (i < total % e->n_panes);
}

static int pane_cols(edit_state * e, int i) {
  if (e->layout == LAYOUT_ROWS) return e->cols;
  int width = e->cols / e->n_panes;
  return width + (i < e->cols % e->n_panes);
}

static int pane_col(edit_state * e, int i) {
  if (e->layout == LAYOUT_ROWS) return 0;
  int x = 0;
  for (int n = 0; n < i; n++) x += pane_cols(e, n);
  return x;
}

static void ensure_pane_visible(edit_state * e, pane * p, int body_rows) {
  buffer * b = pane_buffer(e, p);
  size_t cursor = p->cursor;

  if (cursor < p->top) p->top = line_start(b, cursor);
  for (;;) {
    size_t pos = p->top;
    int row = 0;
    while (pos < cursor) {
      if (buffer_at(b, pos) == '\n') row++;
      pos++;
    }
    if (row < body_rows) return;
    p->top = next_line(b, p->top);
  }
}

static void ensure_visible(edit_state * e) {
  ensure_pane_visible(e, active_pane(e), pane_body_rows(e, e->active_pane));
}

static void render_buffer_line(edit_state * e, output * o, buffer * b,
                               size_t * pos, size_t limit) {
  char line[LINE_RENDER_MAX];
  size_t n = 0;
  size_t start = *pos;

  while ((*pos < buffer_len(b)) && (buffer_at(b, *pos) != '\n')) {
    if (n + 1 < sizeof(line)) line[n++] = buffer_at(b, *pos);
    (*pos)++;
  }
  if ((*pos < buffer_len(b)) && (buffer_at(b, *pos) == '\n')) (*pos)++;

  grammar_span spans[GRAMMAR_MAX_SPANS];
  int n_spans = e->has_grammar ?
    grammar_highlight(&e->grammar, line, n, spans, GRAMMAR_MAX_SPANS) : 0;
  int span = 0;
  bool color = false;

  size_t shown = 0;
  for (size_t i = 0; i < n && shown < limit; i++) {
    while (span < n_spans && i >= spans[span].end) {
      out_s(o, "\x1b[0m");
      color = false;
      span++;
    }
    if (span < n_spans && i == spans[span].start) {
      out_f(o, "\x1b[%sm", spans[span].sgr);
      color = true;
    }
    char c = line[i];
    if (c == '\t') c = ' ';
    if ((unsigned char) c < 32) c = ' ';
    out_add(o, &c, 1);
    shown++;
  }
  if (color) out_s(o, "\x1b[0m");
  (void) start;
}

static void render_line(edit_state * e, output * o, size_t * pos) {
  size_t limit = (e->cols > 1) ? (size_t) e->cols - 1 : 1;
  render_buffer_line(e, o, active_buffer(e), pos, limit);
}

static int pane_cursor_row(edit_state * e, pane * p, int body_rows) {
  buffer * b = pane_buffer(e, p);
  size_t row_pos = p->top;
  int cy = 0;
  while (row_pos < p->cursor && cy < body_rows) {
    if (buffer_at(b, row_pos) == '\n') cy++;
    row_pos++;
  }
  return (cy >= body_rows) ? body_rows - 1 : cy;
}

static size_t pane_cursor_col(edit_state * e, pane * p) {
  buffer * b = pane_buffer(e, p);
  size_t cx = p->cursor - line_start(b, p->cursor);
  int cols = pane_cols(e, (int) (p - e->panes));
  size_t limit = (cols > 1) ? (size_t) cols - 2 : 0;
  return (cx > limit) ? limit : cx;
}

static void render_modeline(edit_state * e, output * o, buffer * b,
                            bool active, int cols) {
  size_t status_cols = (cols > 1) ? (size_t) cols - 1 : 1;
  size_t used = 0;
  out_clip(o, (active && e->n_panes > 1) ? ">" : " ", &used, status_cols);
  if (active && e->status[0] != '\0') {
    out_clip(o, e->status, &used, status_cols);
    out_clip(o, "  ", &used, status_cols);
    if (b->dirty) out_clip(o, "* ", &used, status_cols);
  }
  out_clip(o, b->path, &used, status_cols);
  if (b->dirty && (! active || e->status[0] == '\0')) out_clip(o, " *", &used, status_cols);
  out_clip(o, " ", &used, status_cols);
  while (used++ < status_cols) out_s(o, " ");
}

static void render(edit_state * e) {
  get_window_size(e);
  output o = {0};
  out_s(&o, "\x1b[?25l\x1b[H");

  if (e->layout == LAYOUT_COLS) {
    size_t pos[8];
    int cursor_row = 0;
    size_t cursor_col = 0;
    int body_rows = (e->rows > 1) ? e->rows - 1 : 1;

    for (int i = 0; i < e->n_panes; i++) {
      pane * p = &e->panes[i];
      ensure_pane_visible(e, p, body_rows);
      pos[i] = p->top;
      if (i == e->active_pane) {
        cursor_row = pane_cursor_row(e, p, body_rows);
        cursor_col = (size_t) pane_col(e, i) + pane_cursor_col(e, p);
      }
    }
    for (int row = 0; row < body_rows; row++) {
      out_f(&o, "\x1b[%d;1H\x1b[K", row + 1);
      for (int i = 0; i < e->n_panes; i++) {
        buffer * b = pane_buffer(e, &e->panes[i]);
        out_f(&o, "\x1b[%d;%dH", row + 1, pane_col(e, i) + 1);
        int cols = pane_cols(e, i);
        if (pos[i] < buffer_len(b))
          render_buffer_line(e, &o, b, &pos[i], (cols > 1) ? (size_t) cols - 1 : 1);
      }
    }
    out_f(&o, "\x1b[%d;1H", e->rows);
    for (int i = 0; i < e->n_panes; i++) {
      out_f(&o, "\x1b[%d;%dH\x1b[7m", e->rows, pane_col(e, i) + 1);
      render_modeline(e, &o, pane_buffer(e, &e->panes[i]),
                       i == e->active_pane, pane_cols(e, i));
      out_s(&o, "\x1b[0m");
    }
    out_f(&o, "\x1b[%d;%zuH\x1b[?25h", cursor_row + 1, cursor_col + 1);
    write(STDOUT_FILENO, o.data, o.len);
    free(o.data);
    return;
  }

  int cursor_row = 0;
  size_t cursor_col = 0;
  int screen_row = 0;
  for (int i = 0; i < e->n_panes && screen_row < e->rows; i++) {
    pane * p = &e->panes[i];
    buffer * b = pane_buffer(e, p);
    int body_rows = pane_body_rows(e, i);
    ensure_pane_visible(e, p, body_rows);
    if (i == e->active_pane) {
      cursor_row = screen_row + pane_cursor_row(e, p, body_rows);
      cursor_col = pane_cursor_col(e, p);
    }

    size_t pos = p->top;
    for (int row = 0; row < body_rows && screen_row < e->rows; row++, screen_row++) {
      out_s(&o, "\x1b[K");
      if (pos < buffer_len(b))
        render_buffer_line(e, &o, b, &pos, (e->cols > 1) ? (size_t) e->cols - 1 : 1);
      if (screen_row + 1 < e->rows) out_s(&o, "\r\n");
    }
    if (screen_row < e->rows) {
      out_s(&o, "\x1b[7m");
      render_modeline(e, &o, b, i == e->active_pane, e->cols);
      out_s(&o, "\x1b[0m");
      if (++screen_row < e->rows) out_s(&o, "\r\n");
    }
  }
  out_f(&o, "\x1b[%d;%zuH\x1b[?25h", cursor_row + 1, cursor_col + 1);

  write(STDOUT_FILENO, o.data, o.len);
  free(o.data);
}

static void snapshot_line(edit_state * e, output * o, buffer * b, size_t * pos,
                          int cursor_row, size_t cursor_col, int row) {
  size_t limit = (e->cols > 1) ? (size_t) e->cols - 1 : 1;
  size_t col = 0;
  while ((*pos < buffer_len(b)) && (buffer_at(b, *pos) != '\n') &&
         col < limit) {
    if ((row == cursor_row) && (col == cursor_col)) out_s(o, "|");
    char c = buffer_at(b, *pos);
    if (c == ' ') c = '.';
    if (c == '\t') c = '>';
    if ((unsigned char) c < 32) c = '?';
    out_add(o, &c, 1);
    (*pos)++;
    col++;
  }
  if ((row == cursor_row) && (col == cursor_col)) out_s(o, "|");
  while ((*pos < buffer_len(b)) && (buffer_at(b, *pos) != '\n')) (*pos)++;
  if ((*pos < buffer_len(b)) && (buffer_at(b, *pos) == '\n')) (*pos)++;
}

static void snapshot_cell(edit_state * e, output * o, buffer * b, size_t * pos,
                          int cursor_row, size_t cursor_col, int row, int cols) {
  (void) e;
  size_t limit = (cols > 1) ? (size_t) cols - 1 : 1;
  size_t col = 0;
  while ((*pos < buffer_len(b)) && (buffer_at(b, *pos) != '\n') && col < limit) {
    if ((row == cursor_row) && (col == cursor_col)) {
      out_s(o, "|");
      col++;
    }
    char c = buffer_at(b, *pos);
    if (c == ' ') c = '.';
    if (c == '\t') c = '>';
    if ((unsigned char) c < 32) c = '?';
    out_add(o, &c, 1);
    (*pos)++;
    col++;
  }
  if ((row == cursor_row) && (col == cursor_col) && col < limit) {
    out_s(o, "|");
    col++;
  }
  while (col++ < limit) out_s(o, " ");
  while ((*pos < buffer_len(b)) && (buffer_at(b, *pos) != '\n')) (*pos)++;
  if ((*pos < buffer_len(b)) && (buffer_at(b, *pos) == '\n')) (*pos)++;
}

static void snapshot_modeline(output * o, buffer * b, bool active, int cols) {
  size_t limit = (cols > 1) ? (size_t) cols - 1 : 1;
  size_t used = 0;
  out_s(o, active ? ">" : "=");
  used++;
  out_clip(o, b->path, &used, limit);
  while (used++ < limit) out_s(o, " ");
}

static void render_snapshot(edit_state * e) {
  output o = {0};
  if (e->layout == LAYOUT_COLS) {
    size_t pos[8];
    int cy[8];
    size_t cx[8];
    int body_rows = (e->rows > 1) ? e->rows - 1 : 1;

    for (int i = 0; i < e->n_panes; i++) {
      pane * p = &e->panes[i];
      ensure_pane_visible(e, p, body_rows);
      pos[i] = p->top;
      cy[i] = pane_cursor_row(e, p, body_rows);
      cx[i] = pane_cursor_col(e, p);
    }
    for (int row = 0; row < body_rows; row++) {
      for (int i = 0; i < e->n_panes; i++)
        snapshot_cell(e, &o, pane_buffer(e, &e->panes[i]), &pos[i],
                      cy[i], cx[i], row, pane_cols(e, i));
      out_s(&o, "\n");
    }
    for (int i = 0; i < e->n_panes; i++)
      snapshot_modeline(&o, pane_buffer(e, &e->panes[i]),
                         i == e->active_pane, pane_cols(e, i));
    if (e->status[0] != '\0') {
      out_s(&o, " ");
      out_s(&o, e->status);
    }
    out_s(&o, "\n");
    fwrite(o.data, 1, o.len, stdout);
    free(o.data);
    return;
  }
  for (int i = 0; i < e->n_panes; i++) {
    pane * p = &e->panes[i];
    buffer * b = pane_buffer(e, p);
    int body_rows = pane_body_rows(e, i);
    ensure_pane_visible(e, p, body_rows);
    int cy = pane_cursor_row(e, p, body_rows);
    size_t cx = pane_cursor_col(e, p);
    size_t pos = p->top;

    for (int row = 0; row < body_rows; row++) {
      if (pos < buffer_len(b)) snapshot_line(e, &o, b, &pos, cy, cx, row);
      else if (row == cy && cx == 0) out_s(&o, "|");
      out_s(&o, "\n");
    }
    if (e->n_panes > 1) {
      out_s(&o, (i == e->active_pane) ? ">" : "=");
      out_s(&o, b->path);
      if (b->dirty) out_s(&o, "*");
      if (i == e->active_pane && e->status[0] != '\0') {
        out_s(&o, " ");
        out_s(&o, e->status);
      }
      out_s(&o, "\n");
    }
  }
  if (e->n_panes == 1) {
    out_s(&o, "=");
    out_s(&o, active_buffer(e)->path);
    if (active_buffer(e)->dirty) out_s(&o, "*");
    if (e->status[0] != '\0') {
      out_s(&o, " ");
      out_s(&o, e->status);
    }
    out_s(&o, "\n");
  }
  fwrite(o.data, 1, o.len, stdout);
  free(o.data);
}

static void render_color_snapshot(edit_state * e) {
  ensure_visible(e);
  output o = {0};
  size_t pos = active_pane(e)->top;
  int body_rows = (e->rows > 1) ? e->rows - 1 : 1;
  for (int row = 0; row < body_rows; row++) {
    if (pos < buffer_len(active_buffer(e))) render_line(e, &o, &pos);
    out_s(&o, "\n");
  }
  fwrite(o.data, 1, o.len, stdout);
  free(o.data);
}

static int cli_render(const char * size, const char * path) {
  edit_state e;
  memset(&e, 0, sizeof(e));
  e.n_buffers = 1;
  e.n_panes = 1;
  e.panes[0].buffer = 0;
  e.panes[0].cursor = 0;
  e.panes[0].preferred_col = SIZE_MAX;
  if (sscanf(size, "%d:%d", &e.rows, &e.cols) != 2 || e.rows < 2 || e.cols < 1)
    return fprintf(stderr, "edit: bad render size\n"), 1;
  if (buffer_load(&e.buffers[0], path) != 0)
    return fprintf(stderr, "edit: open failed\n"), 1;
  render_snapshot(&e);
  buffer_free(&e.buffers[0]);
  return 0;
}

static int cli_render_color(const char * size, const char * path) {
  edit_state e;
  memset(&e, 0, sizeof(e));
  e.n_buffers = 1;
  e.n_panes = 1;
  e.panes[0].buffer = 0;
  e.panes[0].cursor = 0;
  e.panes[0].preferred_col = SIZE_MAX;
  if (sscanf(size, "%d:%d", &e.rows, &e.cols) != 2 || e.rows < 2 || e.cols < 1)
    return fprintf(stderr, "edit: bad render size\n"), 1;
  load_grammar(&e);
  if (buffer_load(&e.buffers[0], path) != 0)
    return fprintf(stderr, "edit: open failed\n"), 1;
  render_color_snapshot(&e);
  buffer_free(&e.buffers[0]);
  return 0;
}

static int cli_render_at(const char * size, const char * point, const char * path) {
  edit_state e;
  memset(&e, 0, sizeof(e));
  e.n_buffers = 1;
  e.n_panes = 1;
  e.panes[0].buffer = 0;
  e.panes[0].cursor = 0;
  e.panes[0].preferred_col = SIZE_MAX;
  if (sscanf(size, "%d:%d", &e.rows, &e.cols) != 2 || e.rows < 2 || e.cols < 1)
    return fprintf(stderr, "edit: bad render size\n"), 1;
  if (buffer_load(&e.buffers[0], path) != 0)
    return fprintf(stderr, "edit: open failed\n"), 1;

  size_t pos;
  if (parse_point(point, &pos, &e.buffers[0]) != 0) {
    buffer_free(&e.buffers[0]);
    return fprintf(stderr, "edit: bad point\n"), 1;
  }
  e.panes[0].cursor = pos;
  render_snapshot(&e);
  buffer_free(&e.buffers[0]);
  return 0;
}

static int key_name(char c) {
  if (c == '\n') return KEY_ENTER;
  if (c == 'b') return KEY_CTRL('b');
  if (c == 'f') return KEY_CTRL('f');
  if (c == 'p') return KEY_CTRL('p');
  if (c == 'n') return KEY_CTRL('n');
  if (c == 'a') return KEY_CTRL('a');
  if (c == 'e') return KEY_CTRL('e');
  if (c == 'd') return KEY_CTRL('d');
  if (c == 'h') return KEY_CTRL('h');
  if (c == 'l') return KEY_CTRL('l');
  if (c == 's') return KEY_CTRL('s');
  if (c == 'v') return KEY_CTRL('v');
  if (c == 'V') return KEY_META('v');
  if (c == 'x') return KEY_CTRL('x');
  if (c == '/') return KEY_CTRL('_');
  if (c == '_') return KEY_CTRL('_');
  return (unsigned char) c;
}

static int cli_render_keys(const char * size, const char * keys, const char * path) {
  edit_state e;
  memset(&e, 0, sizeof(e));
  e.n_buffers = 1;
  e.n_panes = 1;
  e.panes[0].buffer = 0;
  e.panes[0].cursor = 0;
  e.panes[0].preferred_col = SIZE_MAX;
  if (sscanf(size, "%d:%d", &e.rows, &e.cols) != 2 || e.rows < 2 || e.cols < 1)
    return fprintf(stderr, "edit: bad render size\n"), 1;
  if (buffer_load(&e.buffers[0], path) != 0)
    return fprintf(stderr, "edit: open failed\n"), 1;

  for (size_t i = 0; keys[i] != '\0'; i++) dispatch(&e, key_name(keys[i]));
  render_snapshot(&e);
  history_free(&e);
  buffer_free(&e.buffers[0]);
  return 0;
}

static int cmd_left(edit_state * e, int key) {
  pane * p = active_pane(e);
  if (p->cursor > 0) p->cursor--;
  p->preferred_col = SIZE_MAX;
  (void) key;
  return 0;
}

static int cmd_right(edit_state * e, int key) {
  buffer * b = active_buffer(e);
  pane * p = active_pane(e);
  if (p->cursor < buffer_len(b)) p->cursor++;
  p->preferred_col = SIZE_MAX;
  (void) key;
  return 0;
}

static int cmd_up(edit_state * e, int key) {
  buffer * b = active_buffer(e);
  pane * p = active_pane(e);
  size_t current = line_start(b, p->cursor);
  if (p->preferred_col == SIZE_MAX) p->preferred_col = p->cursor - current;
  size_t prev = prev_line(b, p->cursor);
  p->cursor = line_column(b, prev, p->preferred_col);
  (void) key;
  return 0;
}

static int cmd_down(edit_state * e, int key) {
  buffer * b = active_buffer(e);
  pane * p = active_pane(e);
  size_t current = line_start(b, p->cursor);
  if (p->preferred_col == SIZE_MAX) p->preferred_col = p->cursor - current;
  size_t next = next_line(b, p->cursor);
  p->cursor = line_column(b, next, p->preferred_col);
  (void) key;
  return 0;
}

static int cmd_page_down(edit_state * e, int key) {
  int n = pane_body_rows(e, e->active_pane);
  for (int i = 0; i < n; i++) cmd_down(e, key);
  return 0;
}

static int cmd_page_up(edit_state * e, int key) {
  int n = pane_body_rows(e, e->active_pane);
  for (int i = 0; i < n; i++) cmd_up(e, key);
  return 0;
}

static int cmd_recenter(edit_state * e, int key) {
  pane * p = active_pane(e);
  buffer * b = active_buffer(e);
  int body_rows = pane_body_rows(e, e->active_pane);
  int mode = p->recenter++ % 3;
  int above = (mode == 0) ? body_rows / 2 : (mode == 1) ? 0 : body_rows - 1;

  p->top = line_start(b, p->cursor);
  for (int i = 0; i < above && p->top > 0; i++) p->top = prev_line(b, p->top);
  (void) key;
  return 0;
}

static int cmd_line_start(edit_state * e, int key) {
  buffer * b = active_buffer(e);
  pane * p = active_pane(e);
  p->cursor = line_start(b, p->cursor);
  p->preferred_col = SIZE_MAX;
  (void) key;
  return 0;
}

static int cmd_line_end(edit_state * e, int key) {
  buffer * b = active_buffer(e);
  pane * p = active_pane(e);
  p->cursor = line_end(b, p->cursor);
  p->preferred_col = SIZE_MAX;
  (void) key;
  return 0;
}

static int cmd_delete_next(edit_state * e, int key) {
  buffer * b = active_buffer(e);
  pane * p = active_pane(e);
  if (p->cursor < buffer_len(b))
    edit_delete(e, p->cursor, p->cursor + 1, ++e->history_group, true);
  (void) key;
  return 0;
}

static int cmd_backspace(edit_state * e, int key) {
  pane * p = active_pane(e);
  if (p->cursor > 0) {
    edit_delete(e, p->cursor - 1, p->cursor, ++e->history_group, true);
    p->cursor--;
  }
  (void) key;
  return 0;
}

static int cmd_insert(edit_state * e, int key) {
  char c = (key == KEY_ENTER) ? '\n' : (char) key;
  pane * p = active_pane(e);
  edit_insert(e, p->cursor, &c, 1, ++e->history_group, true);
  p->cursor++;
  p->preferred_col = SIZE_MAX;
  return 0;
}

static int cmd_undo(edit_state * e, int key) {
  if (e->undo_at <= 0) {
    set_status(e, "no undo");
    (void) key;
    return 0;
  }

  int end = e->undo_at;
  unsigned group = e->history[end - 1].group;
  int start = end - 1;
  while (start > 0 && e->history[start - 1].group == group) start--;

  unsigned undo_group = ++e->history_group;
  pane * p = active_pane(e);
  for (int i = end - 1; i >= start; i--) {
    history * h = &e->history[i];
    if (h->kind == HIST_INSERT) {
      edit_delete(e, h->pos, h->pos + h->len, undo_group, false);
      p->cursor = h->pos;
    } else {
      edit_insert(e, h->pos, h->text, h->len, undo_group, false);
      p->cursor = h->pos + h->len;
    }
  }
  p->preferred_col = SIZE_MAX;
  e->undo_at = start;
  set_status(e, "undo");
  (void) key;
  return 0;
}

static int cmd_save(edit_state * e, int key) {
  set_status(e, (buffer_save(active_buffer(e)) == 0) ? "saved" : "save failed");
  (void) key;
  return 0;
}

static int cmd_search(edit_state * e, int key) {
  e->search_prompt = true;
  e->search_len = 0;
  e->search[0] = '\0';
  set_status(e, "search: ");
  (void) key;
  return 0;
}

static int split_pane(edit_state * e, int layout) {
  if (e->n_panes >= 8 ||
      (layout == LAYOUT_ROWS && e->rows && e->rows < (e->n_panes + 1) * 2) ||
      (layout == LAYOUT_COLS && e->cols && e->cols < (e->n_panes + 1) * 4)) {
    set_status(e, "cannot split");
    return 0;
  }
  int at = e->active_pane + 1;
  memmove(e->panes + at + 1, e->panes + at,
          (size_t) (e->n_panes - at) * sizeof(pane));
  e->panes[at] = e->panes[e->active_pane];
  e->n_panes++;
  e->layout = layout;
  set_status(e, "split");
  return 0;
}

static int cmd_split(edit_state * e, int key) {
  split_pane(e, LAYOUT_ROWS);
  (void) key;
  return 0;
}

static int cmd_split_cols(edit_state * e, int key) {
  split_pane(e, LAYOUT_COLS);
  (void) key;
  return 0;
}

static int cmd_other_pane(edit_state * e, int key) {
  if (e->n_panes > 1) e->active_pane = (e->active_pane + 1) % e->n_panes;
  set_status(e, (e->n_panes > 1) ? "other pane" : "one pane");
  (void) key;
  return 0;
}

static int cmd_close_pane(edit_state * e, int key) {
  if (e->n_panes <= 1) {
    set_status(e, "one pane");
    (void) key;
    return 0;
  }
  memmove(e->panes + e->active_pane, e->panes + e->active_pane + 1,
          (size_t) (e->n_panes - e->active_pane - 1) * sizeof(pane));
  e->n_panes--;
  if (e->active_pane >= e->n_panes) e->active_pane = e->n_panes - 1;
  set_status(e, "close pane");
  (void) key;
  return 0;
}

static int cmd_one_pane(edit_state * e, int key) {
  e->panes[0] = *active_pane(e);
  e->n_panes = 1;
  e->active_pane = 0;
  e->layout = LAYOUT_ROWS;
  set_status(e, "one pane");
  (void) key;
  return 0;
}

static int cmd_quit(edit_state * e, int key) {
  if (active_buffer(e)->dirty && ! e->quit_confirm) {
    e->quit_confirm = true;
    set_status(e, "modified; C-x C-c again to quit");
    (void) key;
    return 0;
  }
  e->quit = true;
  (void) key;
  return 0;
}

static binding bindings[] = {
  {{KEY_LEFT, 0}, 1, cmd_left},
  {{KEY_RIGHT, 0}, 1, cmd_right},
  {{KEY_UP, 0}, 1, cmd_up},
  {{KEY_DOWN, 0}, 1, cmd_down},
  {{KEY_CTRL('b'), 0}, 1, cmd_left},
  {{KEY_CTRL('f'), 0}, 1, cmd_right},
  {{KEY_CTRL('p'), 0}, 1, cmd_up},
  {{KEY_CTRL('n'), 0}, 1, cmd_down},
  {{KEY_CTRL('l'), 0}, 1, cmd_recenter},
  {{KEY_CTRL('v'), 0}, 1, cmd_page_down},
  {{KEY_META('v'), 0}, 1, cmd_page_up},
  {{KEY_CTRL('a'), 0}, 1, cmd_line_start},
  {{KEY_CTRL('e'), 0}, 1, cmd_line_end},
  {{KEY_CTRL('d'), 0}, 1, cmd_delete_next},
  {{KEY_BACKSPACE, 0}, 1, cmd_backspace},
  {{KEY_CTRL('h'), 0}, 1, cmd_backspace},
  {{KEY_ENTER, 0}, 1, cmd_insert},
  {{KEY_CTRL('s'), 0}, 1, cmd_search},
  {{KEY_CTRL('_'), 0}, 1, cmd_undo},
  {{KEY_CTRL('x'), '0'}, 2, cmd_close_pane},
  {{KEY_CTRL('x'), '1'}, 2, cmd_one_pane},
  {{KEY_CTRL('x'), '2'}, 2, cmd_split},
  {{KEY_CTRL('x'), '3'}, 2, cmd_split_cols},
  {{KEY_CTRL('x'), 'o'}, 2, cmd_other_pane},
  {{KEY_CTRL('x'), KEY_CTRL('s')}, 2, cmd_save},
  {{KEY_CTRL('x'), 'u'}, 2, cmd_undo},
  {{KEY_CTRL('x'), KEY_CTRL('c')}, 2, cmd_quit},
};

static int search_dispatch(edit_state * e, int key) {
  pane * p = active_pane(e);
  buffer * b = active_buffer(e);
  if (key == KEY_ENTER) {
    size_t start = 0;
    size_t end = 0;
    int rc = e->search_len ?
      buffer_search(b, p->cursor, e->search, &start, &end) : 0;
    e->search_prompt = false;
    if (rc == 1) {
      p->cursor = start;
      p->preferred_col = SIZE_MAX;
      set_status(e, "match %s", e->search);
    } else {
      set_status(e, "%s", (rc == 0) ? "no match" : "search failed");
    }
    return 0;
  }
  if ((key == KEY_BACKSPACE || key == KEY_CTRL('h')) && e->search_len > 0)
    e->search[--e->search_len] = '\0';
  else if ((key >= 32) && (key < 127) && e->search_len + 1 < sizeof(e->search)) {
    e->search[e->search_len++] = (char) key;
    e->search[e->search_len] = '\0';
  }
  set_status(e, "search: %s", e->search);
  return 0;
}

static int dispatch(edit_state * e, int key) {
  int keys[2] = {key, 0};
  int n_keys = 1;

  if (e->search_prompt) return search_dispatch(e, key);

  if (e->prefix) {
    keys[0] = e->prefix;
    keys[1] = key;
    n_keys = 2;
    e->prefix = 0;
  } else if (key == KEY_CTRL('x')) {
    e->prefix = key;
    set_status(e, "C-x");
    return 0;
  }

  for (size_t i = 0; i < sizeof(bindings) / sizeof(bindings[0]); i++)
    if (bindings[i].n_keys == n_keys && bindings[i].keys[0] == keys[0] &&
        bindings[i].keys[1] == keys[1]) {
      if (bindings[i].fn != cmd_quit) e->quit_confirm = false;
      if (bindings[i].fn != cmd_recenter) active_pane(e)->recenter = 0;
      return bindings[i].fn(e, key);
    }

  if ((n_keys == 1) && (key >= 32) && (key < 127)) {
    e->quit_confirm = false;
    active_pane(e)->recenter = 0;
    return cmd_insert(e, key);
  }
  return 0;
}

static int tui(const char * path) {
  edit_state e;
  memset(&e, 0, sizeof(e));
  e.n_buffers = 1;
  e.n_panes = 1;
  e.panes[0].buffer = 0;
  e.panes[0].cursor = 0;
  e.panes[0].preferred_col = SIZE_MAX;
  snprintf(e.status, sizeof(e.status), "C-s search, C-x C-s save, C-x C-c quit");

  load_grammar(&e);
  if (buffer_load(&e.buffers[0], path) != 0) {
    fprintf(stderr, "edit: cannot open %s\n", path);
    return 1;
  }
  if (raw_on(&e) != 0) {
    fprintf(stderr, "edit: raw mode failed\n");
    history_free(&e);
    buffer_free(&e.buffers[0]);
    return 1;
  }
  write(STDOUT_FILENO, "\x1b[?1049h", 8);

  while (! e.quit) {
    render(&e);
    int key = read_key();
    if (key != KEY_ESC) dispatch(&e, key);
  }

  raw_off(&e);
  const char * clear = "\x1b[?25h\x1b[0m\x1b[?1049l";
  write(STDOUT_FILENO, clear, strlen(clear));
  history_free(&e);
  buffer_free(&e.buffers[0]);
  return 0;
}

static int cli_print(const char * range, const char * path) {
  buffer b;
  if (buffer_load(&b, path) != 0) return fprintf(stderr, "edit: open failed\n"), 1;
  size_t start;
  size_t end;
  if (parse_range(range, &start, &end, &b) != 0) {
    buffer_free(&b);
    return fprintf(stderr, "edit: bad range\n"), 1;
  }
  for (size_t i = start; i < end; i++) {
    char c = buffer_at(&b, i);
    fwrite(&c, 1, 1, stdout);
  }
  buffer_free(&b);
  return 0;
}

static int cli_search(const char * point, const char * regex, const char * path) {
  buffer b;
  if (buffer_load(&b, path) != 0) return fprintf(stderr, "edit: open failed\n"), 1;
  size_t from;
  size_t start = 0;
  size_t end = 0;
  if (parse_point(point, &from, &b) != 0) {
    buffer_free(&b);
    return fprintf(stderr, "edit: bad point\n"), 1;
  }

  int rc = buffer_search(&b, from, regex, &start, &end);
  if (rc != 1) {
    buffer_free(&b);
    return fprintf(stderr, "edit: %s\n",
      (rc == 0) ? "no match" : "search failed"), 1;
  }

  size_t sl;
  size_t sc;
  size_t el;
  size_t ec;
  pos_line_col(&b, start, &sl, &sc);
  pos_line_col(&b, end, &el, &ec);
  printf("%zu:%zu..%zu:%zu\n", sl, sc, el, ec);
  buffer_free(&b);
  return 0;
}

static int cli_change(const char * op, const char * point_or_range,
                      const char * text, const char * path) {
  buffer b;
  if (buffer_load(&b, path) != 0) return fprintf(stderr, "edit: open failed\n"), 1;

  size_t n = 0;
  char * input = NULL;
  if (text != NULL) {
    if (strcmp(text, "-") == 0) input = read_stdin(&n);
    else {
      input = (char *) text;
      n = strlen(text);
    }
    if (input == NULL) {
      buffer_free(&b);
      return fprintf(stderr, "edit: input failed\n"), 1;
    }
  }

  int rc = 0;
  if (strcmp(op, "--insert") == 0) {
    size_t pos;
    rc = parse_point(point_or_range, &pos, &b) || buffer_insert(&b, pos, input, n);
  } else {
    size_t start;
    size_t end;
    rc = parse_range(point_or_range, &start, &end, &b);
    if (rc == 0) buffer_delete(&b, start, end);
    if ((rc == 0) && (strcmp(op, "--replace") == 0))
      rc = buffer_insert(&b, start, input, n);
  }

  if ((text != NULL) && (strcmp(text, "-") == 0)) free(input);
  if (rc != 0 || buffer_save(&b) != 0) {
    buffer_free(&b);
    return fprintf(stderr, "edit: change failed\n"), 1;
  }

  printf("%s\n", op + 2);
  buffer_free(&b);
  return 0;
}

static void usage(void) {
  fprintf(stderr,
    "usage:\n"
    "  edit file\n"
    "  edit --print range file\n"
    "  edit --insert line:col text file\n"
    "  edit --delete range file\n"
    "  edit --replace range text file\n"
    "  edit --search line:col regex file\n"
    "  edit --render rows:cols file\n"
    "  edit --render-at rows:cols line:col file\n"
    "  edit --render-keys rows:cols keys file\n"
    "  edit --render-color rows:cols file\n");
}

int main(int argc, char ** argv) {
  if (argc == 2) return tui(argv[1]);
  if (argc == 4 && strcmp(argv[1], "--render") == 0)
    return cli_render(argv[2], argv[3]);
  if (argc == 4 && strcmp(argv[1], "--render-color") == 0)
    return cli_render_color(argv[2], argv[3]);
  if (argc == 5 && strcmp(argv[1], "--render-at") == 0)
    return cli_render_at(argv[2], argv[3], argv[4]);
  if (argc == 5 && strcmp(argv[1], "--render-keys") == 0)
    return cli_render_keys(argv[2], argv[3], argv[4]);
  if (argc == 4 && strcmp(argv[1], "--print") == 0)
    return cli_print(argv[2], argv[3]);
  if (argc == 5 && strcmp(argv[1], "--search") == 0)
    return cli_search(argv[2], argv[3], argv[4]);
  if (argc == 4 && strcmp(argv[1], "--delete") == 0)
    return cli_change(argv[1], argv[2], NULL, argv[3]);
  if (argc == 5 && strcmp(argv[1], "--insert") == 0)
    return cli_change(argv[1], argv[2], argv[3], argv[4]);
  if (argc == 5 && strcmp(argv[1], "--replace") == 0)
    return cli_change(argv[1], argv[2], argv[3], argv[4]);
  usage();
  return 2;
}
