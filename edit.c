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
//    edit --render-keys-color rows:cols keys file
//    edit --render-color rows:cols file
//
// COMPILATION
//    cc -std=c11 -Wall -Wextra -pedantic -O2 -o edit edit.c grammar.c regex.c
// ___________________________________________________________________

#include "grammar.h"

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/time.h>
#include <termios.h>
#include <time.h>
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
#define DEBUG_PATH_SIZE 512
#define RECENT_MAX 16
#define DEFAULT_TAB_WIDTH 3
#define SEARCH_SGR "48;5;238"
#define SEARCH_CURRENT_SGR "48;5;241"
#define SEARCH_BLINK_MS 500
#define HELP_HINT "C-h help"

enum { HIST_INSERT, HIST_DELETE };
enum { LAYOUT_ROWS, LAYOUT_COLS };
enum { BUFFER_FILE, BUFFER_SCRATCH, BUFFER_LIST, BUFFER_HELP };

typedef struct {
  int kind;
  size_t pos;
  size_t len;
  char * text;
  unsigned group;
} history;

typedef struct {
  char * data;
  char * path;
  size_t cap;
  size_t gap_a;
  size_t gap_b;
  size_t cursor;
  size_t top;
  off_t disk_size;
  time_t disk_mtime;
  history history[HISTORY_MAX];
  int n_history;
  int undo_at;
  unsigned history_group;
  bool dirty;
  int kind;
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

typedef struct edit_state edit_state;
typedef int (*command_fn)(edit_state * e, int key);

typedef struct {
  int keys[2];
  int n_keys;
  command_fn fn;
} binding;

typedef struct {
  int key;
  unsigned char raw[32];
  int n_raw;
  long long start_ms;
  long long end_ms;
  char kind[24];
} key_event;

struct edit_state {
  buffer buffers[8];
  pane panes[8];
  int n_buffers;
  int n_panes;
  int active_pane;
  int layout;
  int rows;
  int cols;
  int tab_width;
  int prefix;
  bool search_prompt;
  bool search_reverse;
  bool search_reuse;
  char search[STATUS_SIZE];
  size_t search_len;
  bool find_prompt;
  bool find_reuse;
  char find_path[DEBUG_PATH_SIZE];
  size_t find_len;
  char status[STATUS_SIZE];
  char footer[STATUS_SIZE];
  bool quit;
  bool quit_confirm;
  bool raw;
  bool debug_recording;
  bool debug_note_prompt;
  FILE * debug_log;
  char debug_path[DEBUG_PATH_SIZE];
  char debug_note[STATUS_SIZE];
  size_t debug_note_len;
  unsigned debug_event;
  struct termios saved_termios;
  struct termios raw_termios;
  grammar grammar;
  bool has_grammar;
};

static int env_tab_width(void) {
  const char * s = getenv("EDIT_TAB_WIDTH");
  char * end = NULL;
  long n = s ? strtol(s, &end, 10) : 0;
  return (s != NULL && end > s && *end == '\0' && n > 0 && n < 1000) ?
    (int) n : DEFAULT_TAB_WIDTH;
}

static void init_state(edit_state * e) {
  memset(e, 0, sizeof(*e));
  e->tab_width = env_tab_width();
}

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

static int buffer_blank_kind(buffer * b, const char * path, int kind) {
  b->cap = GAP_SIZE;
  b->data = calloc(b->cap, 1);
  b->path = _dup(path);
  if (b->data == NULL || b->path == NULL) {
    buffer_free(b);
    return -1;
  }
  b->gap_a = 0;
  b->gap_b = b->cap;
  b->cursor = 0;
  b->top = 0;
  b->disk_size = 0;
  b->disk_mtime = 0;
  b->dirty = false;
  b->kind = kind;
  return 0;
}

static int buffer_blank(buffer * b, const char * path) {
  return buffer_blank_kind(b, path, BUFFER_FILE);
}

static int buffer_scratch(buffer * b) {
  return buffer_blank_kind(b, "*scratch*", BUFFER_SCRATCH);
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

  struct stat st;
  if (stat(path, &st) == 0) {
    b->disk_size = st.st_size;
    b->disk_mtime = st.st_mtime;
  } else {
    b->disk_size = 0;
    b->disk_mtime = 0;
  }
  b->cursor = 0;
  b->top = 0;
  b->dirty = false;
  b->kind = BUFFER_FILE;
  return 0;
}

static void history_free_buffer(buffer * b) {
  for (int i = 0; i < b->n_history; i++) free(b->history[i].text);
  b->n_history = 0;
  b->undo_at = 0;
}

static void buffer_free(buffer * b) {
  history_free_buffer(b);
  free(b->data);
  free(b->path);
  memset(b, 0, sizeof(*b));
}

static void buffers_free(edit_state * e) {
  for (int i = 0; i < 8; i++) buffer_free(&e->buffers[i]);
}

static int buffer_save(buffer * b) {
  if (b->kind != BUFFER_FILE) return -1;
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
  struct stat st;
  if (stat(b->path, &st) == 0) {
    b->disk_size = st.st_size;
    b->disk_mtime = st.st_mtime;
  }
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

static int buffer_search_back(buffer * b, size_t from, const char * regex,
                              size_t * start, size_t * end) {
  size_t len = buffer_len(b);
  size_t pos = 0;
  int found = 0;
  if (from > len) from = len;
  while (pos <= from) {
    size_t a = 0;
    size_t z = 0;
    int rc = buffer_search(b, pos, regex, &a, &z);
    if (rc != 1 || a > from) break;
    *start = a;
    *end = z;
    found = 1;
    pos = (z > pos) ? z : a + 1;
  }
  return found;
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

static size_t tab_stop(edit_state * e, size_t col) {
  return (size_t) e->tab_width - (col % (size_t) e->tab_width);
}

static size_t visual_col(edit_state * e, buffer * b, size_t start, size_t pos) {
  size_t col = 0;
  while (start < pos && start < buffer_len(b) && buffer_at(b, start) != '\n') {
    col += (buffer_at(b, start) == '\t') ? tab_stop(e, col) : 1;
    start++;
  }
  return col;
}

static size_t visual_column_pos(edit_state * e, buffer * b,
                                size_t start, size_t preferred) {
  size_t end = line_end(b, start);
  size_t col = 0;
  for (size_t pos = start; pos < end; pos++) {
    size_t next = col + ((buffer_at(b, pos) == '\t') ? tab_stop(e, col) : 1);
    if (preferred < next) return pos;
    col = next;
  }
  return end;
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

static void set_footer(edit_state * e, const char * fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(e->footer, sizeof(e->footer), fmt, ap);
  va_end(ap);
}

static long long now_ms(void) {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return (long long) tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

static void out_hex(output * o, const unsigned char * s, size_t n) {
  for (size_t i = 0; i < n; i++) out_f(o, "%02x%s", s[i], (i + 1 == n) ? "" : " ");
}

static void key_text(int key, char * out, size_t n) {
  if (key == KEY_ESC) snprintf(out, n, "ESC");
  else if (key == KEY_ENTER) snprintf(out, n, "ENTER");
  else if (key == KEY_BACKSPACE) snprintf(out, n, "BACKSPACE");
  else if (key == KEY_UP) snprintf(out, n, "UP");
  else if (key == KEY_DOWN) snprintf(out, n, "DOWN");
  else if (key == KEY_LEFT) snprintf(out, n, "LEFT");
  else if (key == KEY_RIGHT) snprintf(out, n, "RIGHT");
  else if (key >= KEY_META(0) && key < KEY_META(128)) {
    int c = key - KEY_META(0);
    snprintf(out, n, (c >= 32 && c < 127) ? "M-%c" : "M-%d", c);
  } else if (key > 0 && key < 32) snprintf(out, n, "C-%c", key + 96);
  else if (key >= 32 && key < 127) snprintf(out, n, "%c", key);
  else snprintf(out, n, "%d", key);
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

static void history_drop_oldest_group(buffer * b) {
  if (b->n_history == 0) return;
  unsigned group = b->history[0].group;
  int n = 0;
  while (n < b->n_history && b->history[n].group == group) n++;
  for (int i = 0; i < n; i++) history_free_one(&b->history[i]);
  memmove(b->history, b->history + n, (size_t) (b->n_history - n) * sizeof(history));
  b->n_history -= n;
  b->undo_at = (b->undo_at > n) ? b->undo_at - n : 0;
}

static int history_add(buffer * b, int kind, size_t pos,
                       const char * text, size_t len, unsigned group) {
  while (b->n_history >= HISTORY_MAX) history_drop_oldest_group(b);
  history * h = &b->history[b->n_history];
  h->text = malloc(len ? len : 1);
  if (h->text == NULL) return -1;
  if (len) memcpy(h->text, text, len);
  h->kind = kind;
  h->pos = pos;
  h->len = len;
  h->group = group;
  b->n_history++;
  return 0;
}

static int edit_insert(edit_state * e, size_t pos, const char * text,
                       size_t len, unsigned group, bool reset_undo) {
  if (len == 0) return 0;
  int bnum = active_pane(e)->buffer;
  buffer * b = active_buffer(e);
  if (buffer_insert(b, pos, text, len) != 0) return -1;
  for (int i = 0; i < e->n_panes; i++) {
    if (i == e->active_pane) continue;
    if (e->panes[i].buffer != bnum) continue;
    if (e->panes[i].cursor >= pos) e->panes[i].cursor += len;
    if (e->panes[i].top > pos) e->panes[i].top += len;
  }
  if (history_add(b, HIST_INSERT, pos, text, len, group) != 0) return -1;
  if (reset_undo) b->undo_at = b->n_history;
  return 0;
}

static int edit_delete(edit_state * e, size_t start, size_t end,
                       unsigned group, bool reset_undo) {
  buffer * b = active_buffer(e);
  size_t len = buffer_len(b);
  if (start > len) start = len;
  if (end > len) end = len;
  if (end <= start) return 0;

  int bnum = active_pane(e)->buffer;
  size_t n = end - start;
  char * text = malloc(n);
  if (text == NULL) return -1;
  for (size_t i = 0; i < n; i++) text[i] = buffer_at(b, start + i);
  buffer_delete(b, start, end);
  for (int i = 0; i < e->n_panes; i++) {
    pane * p = &e->panes[i];
    if (i == e->active_pane) continue;
    if (p->buffer != bnum) continue;
    if (p->cursor > start) p->cursor = (p->cursor >= end) ? p->cursor - n : start;
    if (p->top > start) p->top = (p->top >= end) ? p->top - n : start;
  }
  int rc = history_add(b, HIST_DELETE, start, text, n, group);
  free(text);
  if (rc != 0) return -1;
  if (reset_undo) b->undo_at = b->n_history;
  return 0;
}

static int path_absolute(const char * path, char * out, size_t n) {
  if (path[0] == '/') return snprintf(out, n, "%s", path) < (int) n ? 0 : -1;
  char cwd[DEBUG_PATH_SIZE];
  if (getcwd(cwd, sizeof(cwd)) == NULL) return -1;
  return snprintf(out, n, "%s/%s", cwd, path) < (int) n ? 0 : -1;
}

static void chomp(char * s) {
  s[strcspn(s, "\r\n")] = '\0';
}

static int recent_save(const char * path);
static int selected_buffer(edit_state * e);
static int split_pane(edit_state * e, int layout);
static void refresh_buffer_list(edit_state * e);
static const char * file_name(const char * path);

static int save_current_file(edit_state * e) {
  buffer * b = active_buffer(e);
  if (b->kind == BUFFER_FILE && b->dirty && buffer_save(b) != 0)
    return set_status(e, "save failed"), -1;
  return 0;
}

static int buffer_set_text(buffer * b, const char * name, int kind, const char * text) {
  buffer_free(b);
  if (buffer_blank_kind(b, name, kind) != 0) return -1;
  if (buffer_insert(b, 0, text, strlen(text)) != 0) return -1;
  b->dirty = false;
  return 0;
}

static bool read_only_buffer(buffer * b) {
  return b->kind == BUFFER_LIST || b->kind == BUFFER_HELP;
}

static void save_pane_state(edit_state * e) {
  pane * p = active_pane(e);
  buffer * b = pane_buffer(e, p);
  if (b->kind == BUFFER_LIST) return;
  b->cursor = p->cursor;
  b->top = p->top;
}

static int list_buffer(edit_state * e) {
  for (int i = 0; i < e->n_buffers; i++)
    if (e->buffers[i].kind == BUFFER_LIST) return i;
  return -1;
}

static int help_buffer(edit_state * e) {
  for (int i = 0; i < e->n_buffers; i++)
    if (e->buffers[i].kind == BUFFER_HELP) return i;
  return -1;
}

static int path_buffer(edit_state * e, const char * path) {
  for (int i = 0; i < e->n_buffers; i++)
    if (e->buffers[i].kind == BUFFER_FILE && strcmp(e->buffers[i].path, path) == 0)
      return i;
  return -1;
}

static int next_real_buffer(edit_state * e, int from) {
  for (int step = 1; step <= e->n_buffers; step++) {
    int i = (from + step) % e->n_buffers;
    if (e->buffers[i].kind != BUFFER_LIST) return i;
  }
  return -1;
}

static bool buffer_visible_elsewhere(edit_state * e, int buffer) {
  for (int i = 0; i < e->n_panes; i++)
    if (i != e->active_pane && e->panes[i].buffer == buffer) return true;
  return false;
}

static int next_hidden_buffer(edit_state * e, int from) {
  for (int step = 1; step <= e->n_buffers; step++) {
    int i = (from + step) % e->n_buffers;
    if (e->buffers[i].kind != BUFFER_LIST && ! buffer_visible_elsewhere(e, i))
      return i;
  }
  return -1;
}

static int previous_real_buffer(edit_state * e, int from) {
  for (int step = 1; step <= e->n_buffers; step++) {
    int i = (from - step + e->n_buffers) % e->n_buffers;
    if (e->buffers[i].kind != BUFFER_LIST) return i;
  }
  return -1;
}

static bool buffer_changed(buffer * b) {
  struct stat st;
  if (b->kind != BUFFER_FILE || b->dirty) return false;
  if (stat(b->path, &st) != 0) return false;
  return st.st_size != b->disk_size || st.st_mtime != b->disk_mtime;
}

static int reload_buffer(buffer * b) {
  char path[DEBUG_PATH_SIZE];
  snprintf(path, sizeof(path), "%s", b->path);
  buffer_free(b);
  return buffer_load(b, path);
}

static int ensure_scratch(edit_state * e) {
  for (int i = 0; i < e->n_buffers; i++)
    if (e->buffers[i].kind == BUFFER_SCRATCH) return i;
  if (e->n_buffers >= 8) return -1;
  return buffer_scratch(&e->buffers[e->n_buffers]) == 0 ? e->n_buffers++ : -1;
}

static int switch_to_buffer(edit_state * e, int i) {
  if (i < 0 || i >= e->n_buffers) return set_status(e, "no buffer"), 0;
  if (save_current_file(e) != 0) return 0;
  save_pane_state(e);
  if (buffer_changed(&e->buffers[i]) && reload_buffer(&e->buffers[i]) != 0)
    return set_status(e, "open failed"), 0;
  active_pane(e)->buffer = i;
  active_pane(e)->cursor = e->buffers[i].cursor;
  active_pane(e)->top = e->buffers[i].top;
  active_pane(e)->preferred_col = SIZE_MAX;
  if (e->buffers[i].kind == BUFFER_FILE) recent_save(e->buffers[i].path);
  refresh_buffer_list(e);
  set_status(e, "opened %s", file_name(e->buffers[i].path));
  return 0;
}

static int switch_to_path(edit_state * e, const char * path) {
  int i = path_buffer(e, path);
  if (i >= 0) return switch_to_buffer(e, i);
  if (e->n_buffers >= 8) return set_status(e, "too many buffers"), 0;
  if (save_current_file(e) != 0) return 0;
  save_pane_state(e);
  if (buffer_load(&e->buffers[e->n_buffers], path) != 0)
    return set_status(e, "open failed"), 0;
  i = e->n_buffers++;
  active_pane(e)->buffer = i;
  active_pane(e)->cursor = 0;
  active_pane(e)->top = 0;
  active_pane(e)->preferred_col = SIZE_MAX;
  recent_save(path);
  refresh_buffer_list(e);
  set_status(e, "opened %s", file_name(path));
  return 0;
}

static void refresh_buffer_list(edit_state * e) {
  int list = list_buffer(e);
  if (list < 0) return;
  output o = {0};
  for (int i = 0; i < e->n_buffers; i++)
    if (e->buffers[i].kind != BUFFER_LIST)
      out_f(&o, "%c %s\n", (i == active_pane(e)->buffer) ? '*' : ' ', e->buffers[i].path);
  buffer_set_text(&e->buffers[list], "*buffers*", BUFFER_LIST, o.data ? o.data : "");
  free(o.data);
}

static int recent_path(char * out, size_t n, bool create) {
  const char * override = getenv("EDIT_RECENT");
  if (override != NULL && override[0] != '\0')
    return snprintf(out, n, "%s", override) < (int) n ? 0 : -1;

  const char * home = getenv("HOME");
  if (home == NULL || home[0] == '\0') return -1;
  if (snprintf(out, n, "%s/.edit", home) >= (int) n) return -1;
  if (create) mkdir(out, 0755);
  return snprintf(out, n, "%s/.edit/recent", home) < (int) n ? 0 : -1;
}

static int recent_other(const char * current, char * out, size_t n) {
  char path[DEBUG_PATH_SIZE];
  char line[DEBUG_PATH_SIZE];
  if (recent_path(path, sizeof(path), false) != 0) return -1;
  FILE * f = fopen(path, "r");
  if (f == NULL) return -1;
  while (fgets(line, sizeof(line), f) != NULL) {
    chomp(line);
    if (line[0] != '\0' && strcmp(line, current) != 0) {
      int rc = snprintf(out, n, "%s", line) < (int) n ? 0 : -1;
      fclose(f);
      return rc;
    }
  }
  fclose(f);
  return -1;
}

static int recent_save(const char * path) {
  char recent[DEBUG_PATH_SIZE];
  char lines[RECENT_MAX][DEBUG_PATH_SIZE];
  int n = 1;
  snprintf(lines[0], sizeof(lines[0]), "%s", path);
  if (recent_path(recent, sizeof(recent), true) != 0) return -1;

  FILE * f = fopen(recent, "r");
  if (f != NULL) {
    char line[DEBUG_PATH_SIZE];
    while (n < RECENT_MAX && fgets(line, sizeof(line), f) != NULL) {
      chomp(line);
      if (line[0] != '\0' && strcmp(line, path) != 0)
        snprintf(lines[n++], sizeof(lines[0]), "%s", line);
    }
    fclose(f);
  }

  f = fopen(recent, "w");
  if (f == NULL) return -1;
  for (int i = 0; i < n; i++) fprintf(f, "%s\n", lines[i]);
  return fclose(f);
}

static bool starts_with(const char * s, const char * prefix) {
  return strncmp(s, prefix, strlen(prefix)) == 0;
}

static void common_prefix(char * s, const char * t) {
  size_t i = 0;
  while (s[i] != '\0' && t[i] != '\0' && s[i] == t[i]) i++;
  s[i] = '\0';
}

static void path_parts(const char * path, char * dir, char * prefix, char * base) {
  const char * slash = strrchr(path, '/');
  if (slash == NULL) {
    snprintf(dir, DEBUG_PATH_SIZE, ".");
    prefix[0] = '\0';
    snprintf(base, DEBUG_PATH_SIZE, "%s", path);
    return;
  }

  size_t n = (size_t) (slash - path) + 1;
  snprintf(prefix, DEBUG_PATH_SIZE, "%.*s", (int) n, path);
  snprintf(base, DEBUG_PATH_SIZE, "%s", slash + 1);
  if (n == 1) snprintf(dir, DEBUG_PATH_SIZE, "/");
  else snprintf(dir, DEBUG_PATH_SIZE, "%.*s", (int) (n - 1), path);
}

static bool directory_path(const char * path) {
  struct stat st;
  return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

static void find_set(edit_state * e, const char * path) {
  snprintf(e->find_path, sizeof(e->find_path), "%s", path);
  e->find_len = strlen(e->find_path);
  e->find_reuse = false;
}

static int find_complete(edit_state * e) {
  char dir[DEBUG_PATH_SIZE];
  char prefix[DEBUG_PATH_SIZE];
  char base[DEBUG_PATH_SIZE];
  char match[DEBUG_PATH_SIZE] = "";
  char list[STATUS_SIZE] = "";
  int n = 0;

  path_parts(e->find_path, dir, prefix, base);
  DIR * d = opendir(dir);
  if (d == NULL) return set_status(e, "no such directory"), 0;

  for (struct dirent * ent = readdir(d); ent != NULL; ent = readdir(d)) {
    if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) continue;
    if (! starts_with(ent->d_name, base)) continue;
    if (n == 0) snprintf(match, sizeof(match), "%s", ent->d_name);
    else common_prefix(match, ent->d_name);
    char path[DEBUG_PATH_SIZE];
    size_t used = strlen(list);
    snprintf(path, sizeof(path), "%s%s", prefix, ent->d_name);
    snprintf(list + used, sizeof(list) - used, "%s%s%s",
             used ? " " : "", ent->d_name, directory_path(path) ? "/" : "");
    n++;
  }
  closedir(d);

  if (n == 0) return set_footer(e, "no match"), 0;
  if (base[0] == '\0') return set_footer(e, "%s", list[0] ? list : "empty directory"), 0;

  char path[DEBUG_PATH_SIZE];
  snprintf(path, sizeof(path), "%s%s", prefix, match);
  if (n == 1 && directory_path(path) && strlen(path) + 1 < sizeof(path))
    strcat(path, "/");
  if (n > 1) set_footer(e, "%s", list);
  find_set(e, path);
  set_status(e, "find file: %s", e->find_path);
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
  e->raw_termios = raw;
  e->raw = true;
  return 0;
}

static key_event read_key_event(int timeout_ms) {
  key_event ev;
  memset(&ev, 0, sizeof(ev));
  ev.key = -1;
  ev.start_ms = now_ms();

  if (timeout_ms >= 0) {
    fd_set set;
    struct timeval tv = {timeout_ms / 1000, (timeout_ms % 1000) * 1000};
    FD_ZERO(&set);
    FD_SET(STDIN_FILENO, &set);
    if (select(STDIN_FILENO + 1, &set, NULL, NULL, &tv) != 1) {
      ev.end_ms = now_ms();
      snprintf(ev.kind, sizeof(ev.kind), "timeout");
      return ev;
    }
  }

  char c;
  if (read(STDIN_FILENO, &c, 1) != 1) return ev;
  unsigned char uc = (unsigned char) c;
  ev.raw[ev.n_raw++] = uc;
  if (uc != KEY_ESC) {
    int need = (uc >= 0xf0) ? 4 : (uc >= 0xe0) ? 3 : (uc >= 0xc0) ? 2 : 1;
    while (ev.n_raw < need && ev.n_raw < (int) sizeof(ev.raw)) {
      fd_set set;
      struct timeval tv = {0, 20000};
      FD_ZERO(&set);
      FD_SET(STDIN_FILENO, &set);
      if (select(STDIN_FILENO + 1, &set, NULL, NULL, &tv) != 1) break;
      if (read(STDIN_FILENO, &c, 1) != 1) break;
      ev.raw[ev.n_raw++] = (unsigned char) c;
    }
    if (ev.n_raw == 2 && ev.raw[0] == 0xc6 && ev.raw[1] == 0x92) ev.key = KEY_META('f');
    else if (ev.n_raw == 3 && ev.raw[0] == 0xe2 && ev.raw[1] == 0x88 && ev.raw[2] == 0xab) ev.key = KEY_META('b');
    else if (ev.n_raw == 3 && ev.raw[0] == 0xe2 && ev.raw[1] == 0x88 && ev.raw[2] == 0x9a) ev.key = KEY_META('v');
    else if (ev.n_raw == 2 && ev.raw[0] == 0xc2 && ev.raw[1] == 0xae) ev.key = KEY_META('r');
    else if (ev.n_raw == 2 && ev.raw[0] == 0xcb && ev.raw[1] == 0x9c) ev.key = KEY_META('n');
    else if (ev.n_raw == 2 && ev.raw[0] == 0xcf && ev.raw[1] == 0x80) ev.key = KEY_META('p');
    else if (ev.n_raw == 2 && ev.raw[0] == 0xc2 && ev.raw[1] == 0xaf) ev.key = KEY_META('<');
    else if (ev.n_raw == 2 && ev.raw[0] == 0xcb && ev.raw[1] == 0x98) ev.key = KEY_META('>');
    if (ev.key >= KEY_META(0)) {
      snprintf(ev.kind, sizeof(ev.kind), "mac-option");
      ev.end_ms = now_ms();
      return ev;
    }
    ev.key = (uc & 0x80) ? KEY_META(uc & 0x7f) : uc;
    snprintf(ev.kind, sizeof(ev.kind), "%s", (uc & 0x80) ? "high-meta" : "plain");
    ev.end_ms = now_ms();
    return ev;
  }

  char seq[32];
  int n = 0;
  fd_set set;
  while (n < (int) sizeof(seq)) {
    struct timeval tv = {0, 20000};
    FD_ZERO(&set);
    FD_SET(STDIN_FILENO, &set);
    if (select(STDIN_FILENO + 1, &set, NULL, NULL, &tv) != 1) break;
    if (read(STDIN_FILENO, &seq[n], 1) != 1) break;
    if (ev.n_raw < (int) sizeof(ev.raw)) ev.raw[ev.n_raw++] = (unsigned char) seq[n];
    n++;
    if ((n == 1) && ((seq[0] != '[') && (seq[0] != 'O'))) break;
    if ((seq[0] == 'O') && (n == 2)) break;
    if ((seq[0] == '[') && (n > 1) &&
        (seq[n-1] >= '@') && (seq[n-1] <= '~')) {
      break;
    }
  }

  ev.end_ms = now_ms();
  if (n == 1) {
    ev.key = KEY_META((unsigned char) seq[0]);
    snprintf(ev.kind, sizeof(ev.kind), "esc-meta");
    return ev;
  }
  if (n < 2) {
    ev.key = KEY_ESC;
    snprintf(ev.kind, sizeof(ev.kind), "plain-esc");
    return ev;
  }
  char final = seq[n-1];
  if ((seq[0] == '[') || (seq[0] == 'O')) {
    snprintf(ev.kind, sizeof(ev.kind), "%s", seq[0] == '[' ? "csi" : "ss3");
    if (final == 'A') ev.key = KEY_UP;
    else if (final == 'B') ev.key = KEY_DOWN;
    else if (final == 'C') ev.key = KEY_RIGHT;
    else if (final == 'D') ev.key = KEY_LEFT;
    else ev.key = KEY_ESC;
    return ev;
  }
  ev.key = KEY_ESC;
  snprintf(ev.kind, sizeof(ev.kind), "unknown-esc");
  return ev;
}

static void raw_off(edit_state * e) {
  if (e->raw) tcsetattr(STDIN_FILENO, TCSAFLUSH, &e->saved_termios);
  e->raw = false;
}

static int pane_body_rows(edit_state * e, int i) {
  if (e->layout == LAYOUT_COLS) return (e->rows > 2) ? e->rows - 2 : 1;
  int total = e->rows - e->n_panes - 1;
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

static int file_rows_from(buffer * b, size_t top) {
  size_t len = buffer_len(b);
  int rows = 0;
  if (len == 0) return 1;
  while (top < len) {
    rows++;
    top = next_line(b, top);
  }
  if (len > 0 && buffer_at(b, len - 1) == '\n') rows++;
  return rows;
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
    if (row < body_rows) break;
    p->top = next_line(b, p->top);
  }
  while (p->top > 0 && file_rows_from(b, p->top) < body_rows)
    p->top = prev_line(b, p->top);
}

static void ensure_visible(edit_state * e) {
  ensure_pane_visible(e, active_pane(e), pane_body_rows(e, e->active_pane));
}

static void debug_log_render(edit_state * e, output * o);

static void paint_search(edit_state * e, const char * line, size_t len,
                         size_t start, const char ** sgrs) {
  if (e->search_len == 0 || len == 0) return;

  for (size_t from = 0; from < len;) {
    int a = -1;
    int z = -1;
    match(e->search, line + from, &a, &z);
    if (a < 0) return;

    size_t s = from + (size_t) a;
    size_t t = from + (size_t) z;
    if (t > len) t = len;
    if (t <= s) {
      from = s + 1;
      continue;
    }

    bool current = start + s == active_pane(e)->cursor;
    bool blink = e->raw && ((now_ms() / SEARCH_BLINK_MS) % 2);
    const char * sgr = current && ! blink ? SEARCH_CURRENT_SGR : SEARCH_SGR;
    for (size_t i = s; i < t; i++) sgrs[i] = sgr;
    from = t;
  }
}

static char triple_quote_before(buffer * b, size_t end) {
  char quote = '\0';
  for (size_t i = 0; i + 2 < end; i++) {
    char c = buffer_at(b, i);
    if ((c == '"' || c == '\'') &&
        buffer_at(b, i + 1) == c && buffer_at(b, i + 2) == c) {
      quote = (quote == c) ? '\0' : quote ? quote : c;
      i += 2;
    }
  }
  return quote;
}

static void render_buffer_line(edit_state * e, output * o, buffer * b,
                               size_t * pos, size_t limit) {
  char line[LINE_RENDER_MAX];
  const char * search_sgrs[LINE_RENDER_MAX];
  size_t n = 0;
  size_t start = *pos;

  while ((*pos < buffer_len(b)) && (buffer_at(b, *pos) != '\n')) {
    if (n + 1 < sizeof(line)) line[n++] = buffer_at(b, *pos);
    (*pos)++;
  }
  if ((*pos < buffer_len(b)) && (buffer_at(b, *pos) == '\n')) (*pos)++;
  line[n] = '\0';

  grammar_span spans[GRAMMAR_MAX_SPANS];
  if (e->has_grammar && e->grammar.is_default)
    e->grammar.triple_quote = triple_quote_before(b, start);
  int n_spans = e->has_grammar ?
    grammar_highlight(&e->grammar, line, n, spans, GRAMMAR_MAX_SPANS) : 0;
  int span = 0;
  const char * color = NULL;

  for (size_t i = 0; i < n; i++) search_sgrs[i] = NULL;
  paint_search(e, line, n, start, search_sgrs);

  size_t shown = 0;
  for (size_t i = 0; i < n && shown < limit; i++) {
    while (span < n_spans && i >= spans[span].end)
      span++;
    const char * sgr = search_sgrs[i] ? search_sgrs[i] :
      (span < n_spans && i >= spans[span].start) ? spans[span].sgr : NULL;
    if (sgr != color) {
      if (color != NULL)
        out_s(o, "\x1b[0m");
      if (sgr != NULL)
        out_f(o, "\x1b[%sm", sgr);
      color = sgr;
    }

    char c = line[i];
    size_t width = (c == '\t') ? tab_stop(e, shown) : 1;
    if ((unsigned char) c < 32) c = ' ';
    for (size_t j = 0; j < width && shown < limit; j++, shown++) {
      char out = (c == '\t') ? ' ' : c;
      out_add(o, &out, 1);
    }
  }
  if (color != NULL)
    out_s(o, "\x1b[0m");
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
  size_t cx = visual_col(e, b, line_start(b, p->cursor), p->cursor);
  int cols = pane_cols(e, (int) (p - e->panes));
  size_t limit = (cols > 1) ? (size_t) cols - 2 : 0;
  return (cx > limit) ? limit : cx;
}

static void modeline_pos(output * o, buffer * b, pane * p,
                          size_t * used, size_t limit) {
  size_t line;
  size_t col;
  char s[48];
  pos_line_col(b, p->cursor, &line, &col);
  snprintf(s, sizeof(s), " %zu:%zu", line, col);
  out_clip(o, s, used, limit);
}

static void footer_line(edit_state * e, output * o, int cols);

static void render_footer(edit_state * e, output * o, int cols) {
  footer_line(e, o, cols);
}

static const char * file_name(const char * path) {
  const char * slash = strrchr(path, '/');
  return slash ? slash + 1 : path;
}

static void footer_line(edit_state * e, output * o, int cols) {
  const char * msg = e->footer[0] ? e->footer : e->status;
  size_t used = 0;
  size_t limit = (cols > 1) ? (size_t) cols - 1 : 1;
  size_t hint = strlen(HELP_HINT);
  if (limit <= hint) {
    out_clip(o, HELP_HINT, &used, limit);
    return;
  }
  out_clip(o, msg, &used, limit - hint);
  while (used < limit - hint) {
    out_s(o, " ");
    used++;
  }
  out_clip(o, HELP_HINT, &used, limit);
}

static void render_modeline(edit_state * e, output * o, pane * p,
                            bool active, int cols) {
  buffer * b = pane_buffer(e, p);
  size_t status_cols = (cols > 1) ? (size_t) cols - 1 : 1;
  size_t used = 0;
  out_clip(o, file_name(b->path), &used, status_cols);
  modeline_pos(o, b, p, &used, status_cols);
  if (b->dirty) out_clip(o, " *", &used, status_cols);
  if (active && e->n_panes > 1) out_clip(o, " >", &used, status_cols);
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
    int body_rows = pane_body_rows(e, 0);

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
    out_f(&o, "\x1b[%d;1H", e->rows - 1);
    for (int i = 0; i < e->n_panes; i++) {
      out_f(&o, "\x1b[%d;%dH\x1b[7m", e->rows - 1, pane_col(e, i) + 1);
      render_modeline(e, &o, &e->panes[i], i == e->active_pane, pane_cols(e, i));
      out_s(&o, "\x1b[0m");
    }
    out_f(&o, "\x1b[%d;1H\x1b[K\x1b[90m", e->rows);
    render_footer(e, &o, e->cols);
    out_s(&o, "\x1b[0m");
    out_f(&o, "\x1b[%d;%zuH\x1b[?25h", cursor_row + 1, cursor_col + 1);
    debug_log_render(e, &o);
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
      render_modeline(e, &o, p, i == e->active_pane, e->cols);
      out_s(&o, "\x1b[0m");
      if (++screen_row < e->rows) out_s(&o, "\r\n");
    }
  }
  if (screen_row < e->rows) {
    out_s(&o, "\x1b[90m");
    render_footer(e, &o, e->cols);
    out_s(&o, "\x1b[0m");
  }
  out_f(&o, "\x1b[%d;%zuH\x1b[?25h", cursor_row + 1, cursor_col + 1);

  debug_log_render(e, &o);
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
    size_t width = (c == '\t') ? tab_stop(e, col) : 1;
    for (size_t i = 0; i < width && col + i < limit; i++) {
      char out = (c == '\t') ? (i == 0 ? '>' : '.') :
        (c == ' ') ? '.' : ((unsigned char) c < 32) ? '?' : c;
      out_add(o, &out, 1);
    }
    (*pos)++;
    col += width;
  }
  if ((row == cursor_row) && (col == cursor_col)) out_s(o, "|");
  while ((*pos < buffer_len(b)) && (buffer_at(b, *pos) != '\n')) (*pos)++;
  if ((*pos < buffer_len(b)) && (buffer_at(b, *pos) == '\n')) (*pos)++;
}

static void snapshot_cell(edit_state * e, output * o, buffer * b, size_t * pos,
                          int cursor_row, size_t cursor_col, int row, int cols) {
  size_t limit = (cols > 1) ? (size_t) cols - 1 : 1;
  size_t col = 0;
  while ((*pos < buffer_len(b)) && (buffer_at(b, *pos) != '\n') && col < limit) {
    if ((row == cursor_row) && (col == cursor_col)) {
      out_s(o, "|");
      col++;
    }
    char c = buffer_at(b, *pos);
    size_t width = (c == '\t') ? tab_stop(e, col) : 1;
    for (size_t j = 0; j < width && col + j < limit; j++) {
      char out = (c == '\t') ? (j == 0 ? '>' : '.') :
        (c == ' ') ? '.' : ((unsigned char) c < 32) ? '?' : c;
      out_add(o, &out, 1);
    }
    (*pos)++;
    col += width;
  }
  if ((row == cursor_row) && (col == cursor_col) && col < limit) {
    out_s(o, "|");
    col++;
  }
  while (col++ < limit) out_s(o, " ");
  while ((*pos < buffer_len(b)) && (buffer_at(b, *pos) != '\n')) (*pos)++;
  if ((*pos < buffer_len(b)) && (buffer_at(b, *pos) == '\n')) (*pos)++;
}

static void snapshot_modeline(edit_state * e, output * o, pane * p,
                              bool active, int cols) {
  buffer * b = pane_buffer(e, p);
  size_t limit = (cols > 1) ? (size_t) cols - 1 : SIZE_MAX;
  size_t used = 0;
  out_clip(o, file_name(b->path), &used, limit);
  if (b->dirty) out_clip(o, "*", &used, limit);
  modeline_pos(o, b, p, &used, limit);
  if (active && e->n_panes > 1) out_clip(o, ">", &used, limit);
  if (cols > 1) while (used++ < limit) out_s(o, " ");
}

static void snapshot_keymap(edit_state * e, output * o) {
  footer_line(e, o, e->cols);
  out_s(o, "\n");
}

static void build_snapshot(edit_state * e, output * o) {
  if (e->layout == LAYOUT_COLS) {
    size_t pos[8];
    int cy[8];
    size_t cx[8];
    int body_rows = pane_body_rows(e, 0);

    for (int i = 0; i < e->n_panes; i++) {
      pane * p = &e->panes[i];
      ensure_pane_visible(e, p, body_rows);
      pos[i] = p->top;
      cy[i] = pane_cursor_row(e, p, body_rows);
      cx[i] = pane_cursor_col(e, p);
    }
    for (int row = 0; row < body_rows; row++) {
      for (int i = 0; i < e->n_panes; i++)
        snapshot_cell(e, o, pane_buffer(e, &e->panes[i]), &pos[i],
                      cy[i], cx[i], row, pane_cols(e, i));
      out_s(o, "\n");
    }
    for (int i = 0; i < e->n_panes; i++)
      snapshot_modeline(e, o, &e->panes[i], i == e->active_pane, pane_cols(e, i));
    out_s(o, "\n");
    snapshot_keymap(e, o);
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
      if (pos < buffer_len(b)) snapshot_line(e, o, b, &pos, cy, cx, row);
      else if (row == cy && cx == 0) out_s(o, "|");
      out_s(o, "\n");
    }
    if (e->n_panes > 1) {
      snapshot_modeline(e, o, p, i == e->active_pane, 0);
      out_s(o, "\n");
    }
  }
  if (e->n_panes == 1) {
    snapshot_modeline(e, o, active_pane(e), false, 0);
    out_s(o, "\n");
  }
  snapshot_keymap(e, o);
}

static void render_snapshot(edit_state * e) {
  output o = {0};
  build_snapshot(e, &o);
  fwrite(o.data, 1, o.len, stdout);
  free(o.data);
}

static void debug_log_state(edit_state * e, const char * label) {
  if (e->debug_log == NULL) return;
  buffer * b = active_buffer(e);
  pane * p = active_pane(e);
  size_t line;
  size_t col;
  pos_line_col(b, p->cursor, &line, &col);
  fprintf(e->debug_log,
          "state %s active=%d panes=%d layout=%d cursor=%zu line=%zu col=%zu top=%zu preferred=%zu prefix=%d search=%d dirty=%d len=%zu status=%s\n",
          label, e->active_pane, e->n_panes, e->layout, p->cursor, line, col,
          p->top, p->preferred_col, e->prefix, e->search_prompt, b->dirty,
          buffer_len(b), e->status);
  for (int i = 0; i < e->n_panes; i++)
    fprintf(e->debug_log, "pane %d buffer=%d cursor=%zu top=%zu preferred=%zu\n",
            i, e->panes[i].buffer, e->panes[i].cursor, e->panes[i].top,
            e->panes[i].preferred_col);
}

static void debug_log_render(edit_state * e, output * o) {
  if (e->debug_log == NULL) return;
  output snap = {0};
  build_snapshot(e, &snap);
  fprintf(e->debug_log,
          "\nrender event=%u time_ms=%lld rows=%d cols=%d layout=%d active=%d\nansi_hex=",
          ++e->debug_event, now_ms(), e->rows, e->cols, e->layout, e->active_pane);
  for (size_t i = 0; i < o->len; i++)
    fprintf(e->debug_log, "%02x%s", (unsigned char) o->data[i],
            (i + 1 == o->len) ? "" : " ");
  fprintf(e->debug_log, "\nsnapshot:\n%.*s", (int) snap.len, snap.data ? snap.data : "");
  fprintf(e->debug_log, "end_render\n");
  free(snap.data);
  fflush(e->debug_log);
}

static void debug_log_key(edit_state * e, key_event * ev, const char * when) {
  if (e->debug_log == NULL) return;
  char name[32];
  output hex = {0};
  key_text(ev->key, name, sizeof(name));
  out_hex(&hex, ev->raw, (size_t) ev->n_raw);
  fprintf(e->debug_log,
          "\nkey event=%u %s start_ms=%lld end_ms=%lld kind=%s key=%s raw=%s\n",
          ++e->debug_event, when, ev->start_ms, ev->end_ms, ev->kind, name,
          hex.data ? hex.data : "");
  free(hex.data);
}

static void debug_log_env(edit_state * e, const char * name) {
  const char * value = getenv(name);
  fprintf(e->debug_log, "env %s=%s\n", name, value ? value : "");
}

static int debug_start(edit_state * e, const char * path) {
  const char * override = getenv("EDIT_DEBUG_LOG");
  if (override != NULL && override[0] != '\0') snprintf(e->debug_path, sizeof(e->debug_path), "%s", override);
  else {
    time_t t = time(NULL);
    struct tm * tm = localtime(&t);
    snprintf(e->debug_path, sizeof(e->debug_path),
             "logs/debug-%04d%02d%02d-%02d%02d%02d-%d.log",
             tm ? tm->tm_year + 1900 : 0, tm ? tm->tm_mon + 1 : 0,
             tm ? tm->tm_mday : 0, tm ? tm->tm_hour : 0, tm ? tm->tm_min : 0,
             tm ? tm->tm_sec : 0, (int) getpid());
  }
  e->debug_log = fopen(e->debug_path, "w");
  if (e->debug_log == NULL) return set_status(e, "debug log failed"), -1;

  char cwd[DEBUG_PATH_SIZE];
  if (getcwd(cwd, sizeof(cwd)) == NULL) snprintf(cwd, sizeof(cwd), "?");
  fprintf(e->debug_log, "edit debug recording\npid=%d\ncwd=%s\nfile=%s\nlog=%s\n",
          (int) getpid(), cwd, path, e->debug_path);
  fprintf(e->debug_log, "termios saved iflag=%lu oflag=%lu cflag=%lu lflag=%lu\n",
          (unsigned long) e->saved_termios.c_iflag, (unsigned long) e->saved_termios.c_oflag,
          (unsigned long) e->saved_termios.c_cflag, (unsigned long) e->saved_termios.c_lflag);
  fprintf(e->debug_log, "termios raw iflag=%lu oflag=%lu cflag=%lu lflag=%lu\n",
          (unsigned long) e->raw_termios.c_iflag, (unsigned long) e->raw_termios.c_oflag,
          (unsigned long) e->raw_termios.c_cflag, (unsigned long) e->raw_termios.c_lflag);
  debug_log_env(e, "TERM");
  debug_log_env(e, "COLORTERM");
  debug_log_env(e, "LANG");
  debug_log_env(e, "LC_CTYPE");
  debug_log_env(e, "SHELL");
  debug_log_env(e, "EDIT_GRAMMAR");
  debug_log_env(e, "EDIT_TAB_WIDTH");
  debug_log_env(e, "PATH");
  e->debug_recording = true;
  e->debug_event = 0;
  set_status(e, "debug recording; Esc stops");
  debug_log_state(e, "start");
  fflush(e->debug_log);
  return 0;
}

static void debug_stop_prompt(edit_state * e) {
  if (e->debug_log == NULL) return;
  e->debug_recording = false;
  e->debug_note_prompt = true;
  e->debug_note_len = 0;
  e->debug_note[0] = '\0';
  set_status(e, "debug note: ");
}

static const char * debug_note_key(edit_state * e, key_event * ev) {
  if (ev->key == KEY_ENTER) {
    fprintf(e->debug_log, "action=debug-note-saved\nnote=%s\nend_debug\n", e->debug_note);
    fclose(e->debug_log);
    e->debug_log = NULL;
    e->debug_note_prompt = false;
    set_status(e, "debug saved %s", e->debug_path);
    return "debug-note-saved";
  }
  if (ev->key == KEY_BACKSPACE && e->debug_note_len > 0)
    e->debug_note[--e->debug_note_len] = '\0';
  else if (ev->key >= 32 && ev->key < 127 && e->debug_note_len + 1 < sizeof(e->debug_note)) {
    e->debug_note[e->debug_note_len++] = (char) ev->key;
    e->debug_note[e->debug_note_len] = '\0';
  }
  set_status(e, "debug note: %s", e->debug_note);
  return "debug-note";
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
  init_state(&e);
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
  buffers_free(&e);
  return 0;
}

static int cli_render_color(const char * size, const char * path) {
  edit_state e;
  init_state(&e);
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
  buffers_free(&e);
  return 0;
}

static int cli_render_at(const char * size, const char * point, const char * path) {
  edit_state e;
  init_state(&e);
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
  buffers_free(&e);
  return 0;
}

static int key_name(char c) {
  if (c == '\n') return KEY_ENTER;
  if (c == '\t') return KEY_CTRL('i');
  if (c == 'b') return KEY_CTRL('b');
  if (c == 'f') return KEY_CTRL('f');
  if (c == 'p') return KEY_CTRL('p');
  if (c == 'n') return KEY_CTRL('n');
  if (c == 'a') return KEY_CTRL('a');
  if (c == 'e') return KEY_CTRL('e');
  if (c == 'd') return KEY_CTRL('d');
  if (c == 'h') return KEY_CTRL('h');
  if (c == 'l') return KEY_CTRL('l');
  if (c == 'g') return KEY_CTRL('g');
  if (c == 'q') return KEY_CTRL('q');
  if (c == 'r') return KEY_CTRL('r');
  if (c == 's') return KEY_CTRL('s');
  if (c == 'v') return KEY_CTRL('v');
  if (c == 'B') return KEY_META('b');
  if (c == 'F') return KEY_META('f');
  if (c == 'N') return KEY_META('n');
  if (c == 'P') return KEY_META('p');
  if (c == 'V') return KEY_META('v');
  if (c == '<') return KEY_META('<');
  if (c == '>') return KEY_META('>');
  if (c == 'x') return KEY_CTRL('x');
  if (c == '/') return KEY_CTRL('_');
  if (c == '_') return KEY_CTRL('_');
  return (unsigned char) c;
}

static int cli_render_keys(const char * size, const char * keys, const char * path) {
  edit_state e;
  init_state(&e);
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
  buffers_free(&e);
  return 0;
}

static int cli_render_keys_color(const char * size, const char * keys, const char * path) {
  edit_state e;
  init_state(&e);
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

  for (size_t i = 0; keys[i] != '\0'; i++) dispatch(&e, key_name(keys[i]));
  render_color_snapshot(&e);
  buffers_free(&e);
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
  if (p->preferred_col == SIZE_MAX) p->preferred_col = visual_col(e, b, current, p->cursor);
  size_t prev = prev_line(b, p->cursor);
  p->cursor = visual_column_pos(e, b, prev, p->preferred_col);
  (void) key;
  return 0;
}

static int cmd_down(edit_state * e, int key) {
  buffer * b = active_buffer(e);
  pane * p = active_pane(e);
  size_t current = line_start(b, p->cursor);
  if (p->preferred_col == SIZE_MAX) p->preferred_col = visual_col(e, b, current, p->cursor);
  size_t next = next_line(b, p->cursor);
  p->cursor = visual_column_pos(e, b, next, p->preferred_col);
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

static int cmd_down_10(edit_state * e, int key) {
  for (int i = 0; i < 10; i++) cmd_down(e, key);
  return 0;
}

static int cmd_up_10(edit_state * e, int key) {
  for (int i = 0; i < 10; i++) cmd_up(e, key);
  return 0;
}

static int cmd_file_start(edit_state * e, int key) {
  pane * p = active_pane(e);
  p->cursor = 0;
  p->top = 0;
  p->preferred_col = SIZE_MAX;
  (void) key;
  return 0;
}

static int cmd_file_end(edit_state * e, int key) {
  buffer * b = active_buffer(e);
  pane * p = active_pane(e);
  p->cursor = buffer_len(b);
  p->top = line_start(b, p->cursor);
  p->preferred_col = SIZE_MAX;
  (void) key;
  return 0;
}

static bool word_byte(buffer * b, size_t pos) {
  char s[2] = {0};
  int start = -1;
  int end = -1;
  if (pos >= buffer_len(b)) return false;
  s[0] = buffer_at(b, pos);
  match("{.}[ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_]",
        s, &start, &end);
  return start == 0 && end == 1;
}

static int cmd_word_forward(edit_state * e, int key) {
  buffer * b = active_buffer(e);
  pane * p = active_pane(e);
  while (p->cursor < buffer_len(b) && ! word_byte(b, p->cursor)) p->cursor++;
  while (p->cursor < buffer_len(b) && word_byte(b, p->cursor)) p->cursor++;
  p->preferred_col = SIZE_MAX;
  (void) key;
  return 0;
}

static int cmd_word_back(edit_state * e, int key) {
  buffer * b = active_buffer(e);
  pane * p = active_pane(e);
  while (p->cursor > 0 && ! word_byte(b, p->cursor - 1)) p->cursor--;
  while (p->cursor > 0 && word_byte(b, p->cursor - 1)) p->cursor--;
  p->preferred_col = SIZE_MAX;
  (void) key;
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
  if (read_only_buffer(active_buffer(e))) return set_status(e, "read only"), 0;
  buffer * b = active_buffer(e);
  pane * p = active_pane(e);
  if (p->cursor < buffer_len(b))
    edit_delete(e, p->cursor, p->cursor + 1, ++b->history_group, true);
  (void) key;
  return 0;
}

static int cmd_backspace(edit_state * e, int key) {
  if (read_only_buffer(active_buffer(e))) return set_status(e, "read only"), 0;
  buffer * b = active_buffer(e);
  pane * p = active_pane(e);
  if (p->cursor > 0) {
    edit_delete(e, p->cursor - 1, p->cursor, ++b->history_group, true);
    p->cursor--;
  }
  (void) key;
  return 0;
}

static int cmd_insert(edit_state * e, int key) {
  if (active_buffer(e)->kind == BUFFER_LIST) {
    if (key == KEY_ENTER) return switch_to_buffer(e, selected_buffer(e));
    return set_status(e, "read only"), 0;
  }
  if (read_only_buffer(active_buffer(e))) return set_status(e, "read only"), 0;
  char c = (key == KEY_ENTER) ? '\n' : (char) key;
  pane * p = active_pane(e);
  buffer * b = active_buffer(e);
  edit_insert(e, p->cursor, &c, 1, ++b->history_group, true);
  p->cursor++;
  p->preferred_col = SIZE_MAX;
  return 0;
}

static int cmd_tab(edit_state * e, int key) {
  if (read_only_buffer(active_buffer(e))) return set_status(e, "read only"), 0;
  size_t n = (size_t) e->tab_width;
  char * spaces = malloc(n);
  pane * p = active_pane(e);
  buffer * b = active_buffer(e);
  if (spaces == NULL) return 0;
  memset(spaces, ' ', n);
  if (edit_insert(e, p->cursor, spaces, n, ++b->history_group, true) == 0)
    p->cursor += n;
  free(spaces);
  p->preferred_col = SIZE_MAX;
  (void) key;
  return 0;
}

static int cmd_quote(edit_state * e, int key) {
  e->prefix = key;
  set_status(e, "C-q");
  return 0;
}

static int cmd_literal(edit_state * e, int key) {
  if (read_only_buffer(active_buffer(e))) return set_status(e, "read only"), 0;
  char c = (key == KEY_ENTER) ? '\n' :
    (key == KEY_CTRL('i')) ? '\t' : (char) key;
  pane * p = active_pane(e);
  buffer * b = active_buffer(e);
  edit_insert(e, p->cursor, &c, 1, ++b->history_group, true);
  p->cursor++;
  p->preferred_col = SIZE_MAX;
  return 0;
}

static int cmd_undo(edit_state * e, int key) {
  if (read_only_buffer(active_buffer(e))) return set_status(e, "read only"), 0;
  buffer * b = active_buffer(e);
  if (b->undo_at <= 0) {
    set_status(e, "no undo");
    (void) key;
    return 0;
  }

  int end = b->undo_at;
  unsigned group = b->history[end - 1].group;
  int start = end - 1;
  while (start > 0 && b->history[start - 1].group == group) start--;

  unsigned undo_group = ++b->history_group;
  pane * p = active_pane(e);
  for (int i = end - 1; i >= start; i--) {
    history * h = &b->history[i];
    if (h->kind == HIST_INSERT) {
      edit_delete(e, h->pos, h->pos + h->len, undo_group, false);
      p->cursor = h->pos;
    } else {
      edit_insert(e, h->pos, h->text, h->len, undo_group, false);
      p->cursor = h->pos + h->len;
    }
  }
  p->preferred_col = SIZE_MAX;
  b->undo_at = start;
  set_status(e, "undo");
  (void) key;
  return 0;
}

static int cmd_save(edit_state * e, int key) {
  buffer * b = active_buffer(e);
  if (b->kind == BUFFER_SCRATCH) set_status(e, "scratch not saved");
  else if (read_only_buffer(b)) set_status(e, "read only");
  else set_status(e, (buffer_save(b) == 0) ? "saved" : "save failed");
  (void) key;
  return 0;
}

static int open_find_path(edit_state * e) {
  if (e->find_len == 0) {
    e->find_prompt = false;
    return set_status(e, "no file"), 0;
  }
  char path[DEBUG_PATH_SIZE];
  if (path_absolute(e->find_path, path, sizeof(path)) != 0) {
    e->find_prompt = false;
    return set_status(e, "bad path"), 0;
  }

  e->find_prompt = false;
  e->find_reuse = false;
  return switch_to_path(e, path);
}

static int cmd_find_file(edit_state * e, int key) {
  char current[DEBUG_PATH_SIZE];
  (void) key;
  if (active_buffer(e)->kind == BUFFER_FILE &&
      path_absolute(active_buffer(e)->path, current, sizeof(current)) == 0 &&
      recent_other(current, e->find_path, sizeof(e->find_path)) == 0) {
  } else {
    e->find_path[0] = '\0';
  }
  e->find_len = strlen(e->find_path);
  e->find_prompt = true;
  e->find_reuse = e->find_len > 0;
  set_status(e, "find file: %s", e->find_path);
  return 0;
}

static int cmd_kill_buffer(edit_state * e, int key) {
  int dead = active_pane(e)->buffer;
  buffer * b = active_buffer(e);
  (void) key;
  if (b->kind == BUFFER_LIST) return set_status(e, "read only"), 0;
  if (b->kind == BUFFER_SCRATCH) {
    buffer_free(b);
    buffer_scratch(b);
    active_pane(e)->cursor = 0;
    active_pane(e)->top = 0;
    set_status(e, "scratch");
    return 0;
  }
  if (save_current_file(e) != 0) return 0;

  int next = previous_real_buffer(e, dead);
  if (next < 0 || next == dead) next = ensure_scratch(e);
  if (next < 0) return set_status(e, "scratch failed"), 0;
  for (int i = 0; i < e->n_panes; i++) {
    if (e->panes[i].buffer == dead) {
      e->panes[i].buffer = next;
      e->panes[i].cursor = e->buffers[next].cursor;
      e->panes[i].top = e->buffers[next].top;
      e->panes[i].preferred_col = SIZE_MAX;
    }
  }
  buffer_free(&e->buffers[dead]);
  memmove(e->buffers + dead, e->buffers + dead + 1,
          (size_t) (e->n_buffers - dead - 1) * sizeof(buffer));
  e->n_buffers--;
  memset(&e->buffers[e->n_buffers], 0, sizeof(buffer));
  for (int i = 0; i < e->n_panes; i++)
    if (e->panes[i].buffer > dead) e->panes[i].buffer--;
  set_status(e, "killed");
  refresh_buffer_list(e);
  return 0;
}

static int selected_buffer(edit_state * e) {
  size_t line;
  size_t col;
  pos_line_col(active_buffer(e), active_pane(e)->cursor, &line, &col);
  (void) col;
  int n = 0;
  for (int i = 0; i < e->n_buffers; i++) {
    if (e->buffers[i].kind == BUFFER_LIST) continue;
    if (n++ == (int) line - 1) return i;
  }
  return -1;
}

static int cmd_buffer_list(edit_state * e, int key) {
  int target = -1;
  (void) key;
  save_pane_state(e);
  if (e->n_panes == 1) {
    int old = e->n_panes;
    split_pane(e, LAYOUT_COLS);
    if (e->n_panes == old) return 0;
    target = e->active_pane + 1;
  } else {
    e->layout = LAYOUT_COLS;
    int list = list_buffer(e);
    for (int i = 0; i < e->n_panes; i++)
      if (e->panes[i].buffer == list) target = i;
    if (target < 0)
      for (int i = 0; i < e->n_panes; i++)
        if (i != e->active_pane) {
          target = i;
          break;
        }
  }
  if (target < 0) return set_status(e, "cannot show buffers"), 0;
  int list = list_buffer(e);
  if (list < 0) {
    if (e->n_buffers >= 8) return set_status(e, "too many buffers"), 0;
    list = e->n_buffers++;
  }
  buffer_set_text(&e->buffers[list], "*buffers*", BUFFER_LIST, "");
  refresh_buffer_list(e);
  e->panes[target].buffer = list;
  e->panes[target].cursor = 0;
  e->panes[target].top = 0;
  e->panes[target].preferred_col = SIZE_MAX;
  e->active_pane = target;
  set_status(e, "buffers");
  return 0;
}

static int cmd_cycle_buffer(edit_state * e, int key) {
  int next = next_hidden_buffer(e, active_pane(e)->buffer);
  (void) key;
  if (next < 0) next = next_real_buffer(e, active_pane(e)->buffer);
  return (next < 0) ? set_status(e, "no buffer"), 0 : switch_to_buffer(e, next);
}

static int search_move(edit_state * e, bool reverse, bool skip_current) {
  pane * p = active_pane(e);
  buffer * b = active_buffer(e);
  size_t start = 0;
  size_t end = 0;
  size_t from = p->cursor;
  int rc;

  if (e->search_len == 0) return set_status(e, "no search"), 0;
  if (reverse) {
    if (skip_current && from > 0) from--;
    rc = buffer_search_back(b, from, e->search, &start, &end);
    if (rc == 0)
      rc = buffer_search_back(b, buffer_len(b), e->search, &start, &end);
  } else {
    if (skip_current && from < buffer_len(b)) from++;
    rc = buffer_search(b, from, e->search, &start, &end);
    if (rc == 0)
      rc = buffer_search(b, 0, e->search, &start, &end);
  }
  if (rc == 1) {
    p->cursor = start;
    p->preferred_col = SIZE_MAX;
    set_status(e, "match %s", e->search);
  } else {
    set_status(e, "%s", (rc == 0) ? "no match" : "search failed");
  }
  return 0;
}

static int cmd_search_dir(edit_state * e, bool reverse) {
  e->search_prompt = true;
  e->search_reverse = reverse;
  e->search_reuse = e->search_len > 0;
  set_status(e, "%ssearch: %s", reverse ? "r" : "", e->search);
  return 0;
}

static int cmd_search(edit_state * e, int key) {
  (void) key;
  return cmd_search_dir(e, false);
}

static int cmd_reverse_search(edit_state * e, int key) {
  (void) key;
  return cmd_search_dir(e, true);
}

static int cmd_cancel(edit_state * e, int key) {
  e->prefix = 0;
  e->search_prompt = false;
  e->search_reuse = false;
  e->search_len = 0;
  e->search[0] = '\0';
  e->find_prompt = false;
  e->find_reuse = false;
  e->quit_confirm = false;
  set_status(e, "cancel");
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
  save_pane_state(e);
  if (e->n_panes > 1) e->active_pane = (e->active_pane + 1) % e->n_panes;
  refresh_buffer_list(e);
  set_status(e, (e->n_panes > 1) ? "other pane" : "one pane");
  (void) key;
  return 0;
}

static int cmd_close_pane(edit_state * e, int key) {
  save_pane_state(e);
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
  save_pane_state(e);
  e->panes[0] = *active_pane(e);
  e->n_panes = 1;
  e->active_pane = 0;
  e->layout = LAYOUT_ROWS;
  set_status(e, "one pane");
  (void) key;
  return 0;
}

static const char HELP_TEXT[] =
  "edit help\n"
  "\n"
  "Movement\n"
  "  Arrow keys, C-b, C-f, C-p, C-n  move by character or line\n"
  "  Esc f, Esc b                      move by word\n"
  "  C-a, C-e                          line start and end\n"
  "  C-v, Esc v                        page down and up\n"
  "  Esc n, Esc p                      move 10 lines down and up\n"
  "  Esc <, Esc >                      file start and end\n"
  "\n"
  "Editing\n"
  "  Text                              insert text\n"
  "  Backspace                         delete previous character\n"
  "  C-d                               delete next character\n"
  "  C-q                               insert next key literally\n"
  "  C-_, C-x u                        undo\n"
  "\n"
  "Search\n"
  "  C-s, C-r                          search forward and reverse\n"
  "  C-s/C-r again                     repeat search\n"
  "  Enter                             accept search\n"
  "  C-g                               cancel\n"
  "\n"
  "Files and buffers\n"
  "  C-x C-f                           find file\n"
  "  Tab                               complete file prompt\n"
  "  C-x C-s                           save file\n"
  "  C-x b                             switch buffer\n"
  "  C-x C-b                           list buffers\n"
  "  C-x k                             kill buffer\n"
  "\n"
  "Panes/windows\n"
  "  C-x 2, C-x 3                      split rows and columns\n"
  "  C-x o                             other pane\n"
  "  C-x 0, C-x 1                      close pane and one pane\n"
  "\n"
  "Quit/debug\n"
  "  C-x C-c                           quit\n"
  "  Esc r                             record debug log\n"
  "\n"
  "Help\n"
  "  C-h                               show this help\n";

static int cmd_help(edit_state * e, int key) {
  int h = help_buffer(e);
  (void) key;
  e->find_prompt = false;
  e->search_prompt = false;
  e->footer[0] = '\0';
  if (h < 0) {
    if (e->n_buffers >= 8) return set_status(e, "too many buffers"), 0;
    h = e->n_buffers++;
  }
  if (buffer_set_text(&e->buffers[h], "*help*", BUFFER_HELP, HELP_TEXT) != 0)
    return set_status(e, "help failed"), 0;
  save_pane_state(e);
  active_pane(e)->buffer = h;
  active_pane(e)->cursor = 0;
  active_pane(e)->top = 0;
  active_pane(e)->preferred_col = SIZE_MAX;
  set_status(e, "help");
  refresh_buffer_list(e);
  return 0;
}

static int cmd_quit(edit_state * e, int key) {
  for (int i = 0; i < e->n_buffers; i++)
    if (e->buffers[i].kind == BUFFER_FILE && e->buffers[i].dirty && ! e->quit_confirm) {
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
  {{KEY_META('b'), 0}, 1, cmd_word_back},
  {{KEY_META('f'), 0}, 1, cmd_word_forward},
  {{KEY_META('n'), 0}, 1, cmd_down_10},
  {{KEY_META('p'), 0}, 1, cmd_up_10},
  {{KEY_META('v'), 0}, 1, cmd_page_up},
  {{KEY_META('<'), 0}, 1, cmd_file_start},
  {{KEY_META('>'), 0}, 1, cmd_file_end},
  {{KEY_CTRL('a'), 0}, 1, cmd_line_start},
  {{KEY_CTRL('e'), 0}, 1, cmd_line_end},
  {{KEY_CTRL('d'), 0}, 1, cmd_delete_next},
  {{KEY_BACKSPACE, 0}, 1, cmd_backspace},
  {{KEY_CTRL('h'), 0}, 1, cmd_help},
  {{KEY_CTRL('i'), 0}, 1, cmd_tab},
  {{KEY_ENTER, 0}, 1, cmd_insert},
  {{KEY_CTRL('g'), 0}, 1, cmd_cancel},
  {{KEY_CTRL('q'), 0}, 1, cmd_quote},
  {{KEY_CTRL('r'), 0}, 1, cmd_reverse_search},
  {{KEY_CTRL('s'), 0}, 1, cmd_search},
  {{KEY_CTRL('_'), 0}, 1, cmd_undo},
  {{KEY_CTRL('x'), '0'}, 2, cmd_close_pane},
  {{KEY_CTRL('x'), '1'}, 2, cmd_one_pane},
  {{KEY_CTRL('x'), '2'}, 2, cmd_split},
  {{KEY_CTRL('x'), '3'}, 2, cmd_split_cols},
  {{KEY_CTRL('x'), 'b'}, 2, cmd_cycle_buffer},
  {{KEY_CTRL('x'), KEY_CTRL('b')}, 2, cmd_buffer_list},
  {{KEY_CTRL('x'), KEY_CTRL('f')}, 2, cmd_find_file},
  {{KEY_CTRL('x'), 'k'}, 2, cmd_kill_buffer},
  {{KEY_CTRL('x'), 'o'}, 2, cmd_other_pane},
  {{KEY_CTRL('x'), KEY_CTRL('s')}, 2, cmd_save},
  {{KEY_CTRL('x'), 'u'}, 2, cmd_undo},
  {{KEY_CTRL('x'), KEY_CTRL('c')}, 2, cmd_quit},
};

static int find_dispatch(edit_state * e, int key) {
  e->footer[0] = '\0';
  if (key == KEY_ENTER) return open_find_path(e);
  if (key == KEY_CTRL('i')) return find_complete(e);
  if (e->find_reuse && key >= 32 && key < 127) {
    e->find_len = 0;
    e->find_path[0] = '\0';
    e->find_reuse = false;
  }
  if (key == KEY_BACKSPACE && e->find_len > 0) {
    e->find_path[--e->find_len] = '\0';
    e->find_reuse = false;
  } else if (key >= 32 && key < 127 && e->find_len + 1 < sizeof(e->find_path)) {
    e->find_path[e->find_len++] = (char) key;
    e->find_path[e->find_len] = '\0';
  }
  set_status(e, "find file: %s", e->find_path);
  return 0;
}

static int search_dispatch(edit_state * e, int key) {
  if (key == KEY_CTRL('g')) return cmd_cancel(e, key);
  if (key == KEY_CTRL('s') || key == KEY_CTRL('r')) {
    bool reverse = key == KEY_CTRL('r');
    bool skip = e->search_reuse;
    e->search_reverse = reverse;
    search_move(e, reverse, skip);
    e->search_reuse = true;
    return 0;
  }
  if (key == KEY_ENTER) {
    search_move(e, e->search_reverse, false);
    e->search_prompt = false;
    e->search_reuse = false;
    return 0;
  }
  if (e->search_reuse && key >= 32 && key < 127) {
    e->search_len = 0;
    e->search[0] = '\0';
    e->search_reuse = false;
  }
  if (key == KEY_BACKSPACE && e->search_len > 0) {
    e->search[--e->search_len] = '\0';
    e->search_reuse = false;
  } else if ((key >= 32) && (key < 127) && e->search_len + 1 < sizeof(e->search)) {
    e->search[e->search_len++] = (char) key;
    e->search[e->search_len] = '\0';
  }
  set_status(e, "%ssearch: %s", e->search_reverse ? "r" : "", e->search);
  return 0;
}

static int dispatch(edit_state * e, int key) {
  int keys[2] = {key, 0};
  int n_keys = 1;

  if (key == KEY_CTRL('g')) return cmd_cancel(e, key);
  if (key == KEY_CTRL('h')) return cmd_help(e, key);
  if (e->find_prompt) return find_dispatch(e, key);
  if (e->search_prompt) return search_dispatch(e, key);

  if (e->prefix) {
    keys[0] = e->prefix;
    keys[1] = key;
    n_keys = 2;
    e->prefix = 0;
    if (keys[0] == KEY_CTRL('q')) return cmd_literal(e, key);
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
  char open_path[DEBUG_PATH_SIZE];
  init_state(&e);
  e.n_buffers = 1;
  e.n_panes = 1;
  e.panes[0].buffer = 0;
  e.panes[0].cursor = 0;
  e.panes[0].preferred_col = SIZE_MAX;
  snprintf(e.status, sizeof(e.status), "C-s/C-r search, C-g cancel, Esc r debug");
  if (path_absolute(path, open_path, sizeof(open_path)) != 0)
    snprintf(open_path, sizeof(open_path), "%s", path);

  load_grammar(&e);
  if (buffer_load(&e.buffers[0], open_path) != 0) {
    fprintf(stderr, "edit: cannot open %s\n", path);
    return 1;
  }
  recent_save(open_path);
  if (raw_on(&e) != 0) {
    fprintf(stderr, "edit: raw mode failed\n");
    buffers_free(&e);
    return 1;
  }
  write(STDOUT_FILENO, "\x1b[?1049h", 8);

  while (! e.quit) {
    render(&e);
    key_event ev = read_key_event(e.search_len > 0 ? SEARCH_BLINK_MS : -1);
    const char * action = "ignored";
    int key = ev.key;
    if (e.debug_log != NULL) {
      debug_log_key(&e, &ev, "before");
      debug_log_state(&e, "before");
    }

    if (! e.debug_recording && ! e.debug_note_prompt && e.prefix == KEY_ESC &&
        key != KEY_CTRL('g')) {
      e.prefix = 0;
      if (key >= 0 && key < 128) {
        key = KEY_META(key);
        action = "esc-meta";
      }
    }

    if (e.debug_note_prompt) action = debug_note_key(&e, &ev);
    else if (e.debug_recording && key == KEY_ESC) {
      debug_stop_prompt(&e);
      action = "debug-stop";
    } else if (! e.debug_recording && key == KEY_ESC) {
      e.prefix = KEY_ESC;
      set_status(&e, "Esc");
      action = "esc-prefix";
    } else if (key == KEY_META('r')) {
      if (e.debug_log == NULL && debug_start(&e, path) == 0) {
        debug_log_key(&e, &ev, "before");
        debug_log_state(&e, "before");
        action = "debug-start";
      } else action = "debug-already-recording";
    } else if (key != KEY_ESC && key != -1) {
      dispatch(&e, key);
      if (strcmp(action, "esc-meta") != 0) action = "dispatch";
    }

    if (e.debug_log != NULL) {
      fprintf(e.debug_log, "action=%s\n", action);
      debug_log_state(&e, "after");
      fflush(e.debug_log);
    }
  }

  raw_off(&e);
  const char * clear = "\x1b[?25h\x1b[0m\x1b[?1049l";
  write(STDOUT_FILENO, clear, strlen(clear));
  if (e.debug_log != NULL) {
    fprintf(e.debug_log, "end_debug aborted\n");
    fclose(e.debug_log);
  }
  buffers_free(&e);
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
    "  edit --render-keys-color rows:cols keys file\n"
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
  if (argc == 5 && strcmp(argv[1], "--render-keys-color") == 0)
    return cli_render_keys_color(argv[2], argv[3], argv[4]);
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
