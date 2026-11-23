// Chat owns the conversation and its file format. The C editor owns buffers and panes.
#ifndef EDIT_CHAT_H
#define EDIT_CHAT_H
#include "completion.h"

#define CHAT_MAGIC "Edit chat 1\n"
void *chat_open(const char *bytes, size_t len); // NULL bytes starts a new session
void chat_close(void *chat);
char *chat_archive(buffer *b, size_t *len);
void chat_restore(buffer *b);
char *chat_saved_draft(void *object, size_t *len);
buffer *chat_active(edit_state *e, bool writing);
bool chat_tick(edit_state *e, buffer *b);
bool chat_stop(edit_state *e, buffer *b);
bool chat_busy(void *chat);
const char *chat_style(void *chat, size_t pos);
int chat_command(edit_state *e, int command);
enum { CHAT_OPEN, CHAT_NEW, CHAT_CLEAR, CHAT_SEND, CHAT_PREV = 'p', CHAT_NEXT = 'n' };

// Editor operations used by the agent and transcript.
buffer *chat_target(edit_state *e, bool fresh);
void *chat_handle(buffer *b);
char *chat_slice(buffer *b, size_t start, size_t *len);
size_t chat_draft(buffer *b);
void chat_replace_view(edit_state *e, buffer *b, size_t start, const char *text, size_t len, bool keep_draft);
size_t chat_point(edit_state *e, buffer *b, size_t set_to);
void chat_status(edit_state *e, buffer *b, const char *message);
typedef struct {
  const char *name;
  size_t length, point, line, column;
  struct {
    int pane;
    size_t point, mark;
    bool focused;
  } views[8];
  int panes;
  bool writable, dirty;
} chat_buffer_info;
bool chat_info(edit_state *e, int index, chat_buffer_info *info, buffer **document);
const char *chat_edit(edit_state *e, buffer *b, size_t pos, size_t remove, const char *text, size_t len);
const char *chat_create(edit_state *e, const char *name, const char *text, size_t len);
const char *chat_help(void);
const char *light_url(void);
#endif
