// Edit-side chat operations. Included inside edit.c to use its normal edit and pane paths.
void *chat_handle(buffer *b) { return b->chat; }
size_t chat_draft(buffer *b) { return b->chat_start; }
const char *chat_help(void) { return HELP_TEXT; }

char *chat_slice(buffer *b, size_t start, size_t *len) {
  if (start > buffer_len(b)) return NULL;
  if (*len > buffer_len(b) - start) *len = buffer_len(b) - start;
  char *text = malloc(*len + 1);
  if (!text) return NULL;
  for (size_t i = 0; i < *len; i++) text[i] = buffer_at(b, start + i);
  text[*len] = 0;
  return text;
}

void chat_status(edit_state *e, buffer *b, const char *message) {
  if (active_buffer(e) == b && !status_busy(e)) set_status(e, "%s", message);
}

size_t chat_point(edit_state *e, buffer *b, size_t pos) {
  pane *p = active_pane(e);
  if (active_buffer(e) != b) return SIZE_MAX;
  if (pos != SIZE_MAX) {
    p->cursor = pos;
    p->preferred_col = SIZE_MAX;
    clear_mark(e);
  }
  return p->cursor;
}

buffer *chat_target(edit_state *e, bool fresh) {
  buffer *b = active_buffer(e);
  if (!fresh && b->chat) return b;
  int id = -1;
  if (!fresh) {
    for (int i = 0; i < e->n_panes; i++)
      if (pane_buffer(e, &e->panes[i])->chat) {
        e->active_pane = i;
        return active_buffer(e);
      }
    for (int i = e->n_buffers - 1; i >= 0; i--)
      if (e->buffers[i].chat) {
        id = i;
        break;
      }
  }
  if (id < 0 && e->n_buffers == 8) {
    set_status(e, "too many buffers");
    return NULL;
  }
  bool split = !b->chat;
  if (split) {
    int count = e->n_panes;
    split_pane(e, LAYOUT_COLS);
    if (e->n_panes == count) return NULL;
    e->active_pane++;
  }
  if (id < 0) {
    char path[PATH_SIZE];
    id = e->n_buffers;
    buffer *new = &e->buffers[id];
    char name[48];
    struct stat st;
    for (unsigned n = 1;; n++) {
      snprintf(name, sizeof(name), "chat-%u.editchat", n);
      if (path_absolute(name, path, sizeof(path))) {
        path[0] = 0;
        break;
      }
      if (path_buffer(e, path) < 0 && lstat(path, &st)) {
        if (errno != ENOENT) path[0] = 0;
        break;
      }
    }
    if (!*path || buffer_blank(new, path) || !(new->chat = chat_open(NULL, 0))) {
      buffer_free(new);
      if (split) cmd_close_pane(e, 0);
      set_status(e, "cannot initialize chat from ~/.agents.md");
      return NULL;
    }
    e->n_buffers++;
    chat_restore(new);
    new->dirty = true;
    new->spelling_off = true;
    new->cursor = buffer_len(new);
  }
  save_pane_state(e);
  b = &e->buffers[id];
  *active_pane(e) =
      (pane){.buffer = id, .cursor = b->cursor, .top = b->top, .wrap = 2, .preferred_col = SIZE_MAX};
  refresh_buffer_list(e);
  return b;
}

// Replace only the changed transcript suffix, retaining the draft and scroll position.
void chat_replace_view(edit_state *e, buffer *b, size_t start, const char *text, size_t len,
                       bool keep_draft) {
  size_t old = keep_draft ? b->chat_start : buffer_len(b);
  size_t end = start + len;
  while (start < old && len && buffer_at(b, start) == *text) {
    start++;
    text++;
    len--;
  }
  if (start == old && !len) {
    b->chat_start = end;
    return;
  }
  if (start < old) buffer_delete(b, start, old);
  if (len) buffer_insert(b, start, text, len);
  b->chat_start = end;
  history_free_buffer(b);
  b->clean_at = -1;
  if (!e) return;
  for (int i = 0; i < e->n_panes; i++) {
    pane *p = &e->panes[i];
    if (pane_buffer(e, p) != b) continue;
    if (p->cursor >= old)
      p->cursor = end + (p->cursor - old);
    else if (p->cursor > start)
      p->cursor = start;
    if (p->top > p->cursor) p->top = p->cursor;
    if (p->mark_active && p->mark > start) p->mark_active = false;
  }
}

bool chat_info(edit_state *e, int i, chat_buffer_info *info, buffer **document) {
  if (i < 0 || i >= e->n_buffers) return false;
  buffer *b = *document = &e->buffers[i];
  *info = (chat_buffer_info){.name = b->path,
                             .length = buffer_len(b),
                             .point = b->cursor,
                             .writable = !b->chat && !read_only_buffer(b) &&
                                         (b->kind == BUFFER_FILE || b->kind == BUFFER_SCRATCH),
                             .dirty = b->dirty};
  for (int j = 0; j < e->n_panes; j++) {
    pane *p = &e->panes[j];
    if (p->buffer != i) continue;
    int k = info->panes++;
    info->views[k].pane = j + 1;
    info->views[k].point = p->cursor;
    info->views[k].mark = p->mark_active ? p->mark : SIZE_MAX;
    info->views[k].focused = j == e->active_pane;
    if (!k || j == e->active_pane) info->point = p->cursor;
  }
  pos_line_col(b, info->point, &info->line, &info->column);
  return true;
}

const char *chat_create(edit_state *e, const char *name, const char *text, size_t len) {
  char path[PATH_SIZE];
  struct stat st;
  if (!*name || path_absolute(name, path, sizeof(path))) return "Use a new filename.";
  char local[PATH_SIZE];
  if (path_absolute(file_name(name), local, sizeof(local)) || strcmp(local, path))
    return "Use a new filename in the editor's working directory.";
  if (!lstat(path, &st) || errno != ENOENT || path_buffer(e, path) >= 0) return "Name already exists.";
  if (e->n_buffers >= 8) return "Buffer list is full.";
  buffer *b = &e->buffers[e->n_buffers];
  if (buffer_blank(b, path)) return "Allocation failed.";
  e->n_buffers++;
  const char *result = chat_edit(e, b, 0, 0, text, len);
  if (strcmp(result, "Applied in Edit.")) {
    e->n_buffers--;
    buffer_free(b);
    return result;
  }
  b->dirty = true;
  refresh_buffer_list(e);
  return "Created in Edit.";
}

const char *chat_edit(edit_state *e, buffer *b, size_t pos, size_t remove, const char *text, size_t len) {
  if (b->chat || read_only_buffer(b) || (b->kind != BUFFER_FILE && b->kind != BUFFER_SCRATCH))
    return "Buffer is read only.";
  if (pos > buffer_len(b) || remove > buffer_len(b) - pos) return "Range changed.";
  int active = e->active_pane, id = (int)(b - e->buffers);
  pane saved = *active_pane(e);
  int shown = -1;
  for (int i = 0; i < e->n_panes; i++)
    if (e->panes[i].buffer == id) {
      shown = i;
      break;
    }
  if (shown >= 0)
    e->active_pane = shown;
  else
    *active_pane(e) = (pane){.buffer = id, .cursor = b->cursor};
  pane *p = active_pane(e);
  unsigned group = ++b->history_group;
  int rc = edit_delete(e, pos, pos + remove, group, true);
  if (!rc) rc = edit_insert(e, pos, text, len, group, true);
  if (!rc && p->cursor >= pos)
    p->cursor = pos + len + (p->cursor > pos + remove ? p->cursor - pos - remove : 0);
  if (shown < 0) {
    b->cursor = p->cursor;
    *p = saved;
  }
  e->active_pane = active;
  return rc ? "Edit failed." : "Applied in Edit.";
}

buffer *chat_active(edit_state *e, bool writing) {
  buffer *b = active_buffer(e);
  if (b->chat) {
    if (writing && b->read_only) {
      set_status(e, "read only");
      return NULL;
    }
    return b;
  }
  set_status(e, "select a chat buffer first");
  return NULL;
}
static int cmd_complete_or_chat(edit_state *e, int key) {
  return active_buffer(e)->chat ? chat_command(e, CHAT_SEND) : cmd_complete(e, key);
}
static int chat_decode(buffer *b) {
  size_t head = strlen(CHAT_MAGIC), len = buffer_len(b);
  if (len < head) return 0;
  for (size_t i = 0; i < head; i++)
    if (buffer_at(b, i) != CHAT_MAGIC[i]) return 0;
  len -= head;
  char *archive = chat_slice(b, head, &len);
  if (!archive) return -1;
  b->chat = chat_open(archive, len);
  free(archive);
  if (!b->chat) return -1;
  chat_restore(b);
  size_t n = 0;
  char *draft = chat_saved_draft(b->chat, &n);
  if (!draft) return -1;
  int rc = n ? buffer_insert(b, buffer_len(b), draft, n) : 0;
  free(draft);
  b->cursor = buffer_len(b);
  b->spelling_off = true;
  b->clean_at = 0;
  b->dirty = false;
  return rc;
}

static int chat_save_as_cmd(edit_state *e, int key) {
  (void)key;
  if (!chat_active(e, false)) return 0;
  e->find_prompt = e->chat_save_as = true;
  e->footer[0] = 0;
  set_status(e, "save chat as: ");
  e->find_path[0] = 0;
  e->find_len = e->find_pos = 0;
  e->find_origin_pane = e->active_pane;
  e->prompt_overflow = NULL;
  clear_prompt_mark(e);
  return 0;
}
static int chat_save_path(edit_state *e) {
  buffer *b = active_buffer(e);
  char path[PATH_SIZE];
  struct stat st;
  if (!b->chat || !e->find_len || path_absolute(e->find_path, path, sizeof(path)))
    return set_footer(e, "enter a file path"), 0;
  if (strcmp(path, b->path) && (path_buffer(e, path) >= 0 || !lstat(path, &st) || errno != ENOENT))
    return set_footer(e, "choose a new file path"), 0;
  char *old = b->path;
  time_t mtime = b->disk_mtime;
  if (strcmp(path, old)) b->disk_mtime = 0;
  b->path = _dup(path);
  if (!b->path || buffer_save_source(b)) {
    free(b->path);
    b->path = old;
    b->disk_mtime = mtime;
    return set_footer(e, "save failed"), 0;
  }
  free(old);
  e->chat_save_as = e->find_prompt = false;
  e->footer[0] = 0;
  clear_prompt_mark(e);
  recent_save(b->path);
  refresh_buffer_list(e);
  return set_status(e, "saved %s", b->path), 0;
}
