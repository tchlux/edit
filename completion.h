// The completion command and the small part of the editor it can access.
#ifndef EDIT_COMPLETION_H
#define EDIT_COMPLETION_H
#include <stdbool.h>
#include <stddef.h>

typedef struct buffer buffer;
typedef struct edit_state edit_state;
typedef struct {
  edit_state *editor;
  buffer *document;
  const char *filename;
  size_t length, cursor, mark, insert_at;
  unsigned group;
} edit_stream;

bool edit_stream_open(edit_state *e, edit_stream *s);
bool edit_stream_write(edit_stream *s, const char *text, size_t len);
char buffer_at(buffer *b, size_t i);
size_t utf8_prev_pos(buffer *b, size_t pos);
bool kill_push(edit_state *e, buffer *b, size_t start, size_t end);
void set_status(edit_state *e, const char *fmt, ...);
void render(edit_state *e);

int cmd_complete(edit_state *e, int key);
#endif
