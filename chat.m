// Edit's Light chat sessions. The on-disk archive contains the original messages,
// tool calls, reasoning, model, and unfinished draft. The pane displays their text.
#import <Foundation/Foundation.h>
#include "chat.h"

static NSString *string(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }
static NSData *bytes(NSString *text) { return [text dataUsingEncoding:NSUTF8StringEncoding]; }
static id json(NSData *data) {
  return data.length
             ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil]
             : nil;
}
static NSString *slice(buffer *b, size_t pos, size_t len) {
  char *data = chat_slice(b, pos, &len);
  return data ? [[NSString alloc] initWithBytesNoCopy:data
                                               length:len
                                             encoding:NSUTF8StringEncoding
                                         freeWhenDone:YES]
              : nil;
}

// The URL delegate only receives bytes. All parsing and editor mutations run on the editor thread.
@interface ChatTransfer : NSObject <NSURLSessionDataDelegate>
@property NSMutableData *received;
@property NSURLSession *session;
@property NSHTTPURLResponse *response;
@property NSError *error;
@property BOOL finished;
@end
@implementation ChatTransfer
- (void)URLSession:(NSURLSession *)session
              dataTask:(NSURLSessionDataTask *)task
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition))answer {
  @synchronized(self) {
    self.response = (NSHTTPURLResponse *)response;
  }
  answer(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)task
    didReceiveData:(NSData *)data {
  @synchronized(self) {
    [self.received appendData:data];
  }
}
- (void)URLSession:(NSURLSession *)session
                    task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
  @synchronized(self) {
    self.error = error;
    self.finished = YES;
  }
}
@end

@interface EditChat : NSObject
@property NSMutableArray<NSMutableDictionary *> *messages;
@property NSString *model, *draft, *effort;
@property NSArray *tools;
@property NSMutableArray<NSNumber *> *offsets, *sections, *styles;
@property ChatTransfer *transfer;
@property NSMutableData *pending;
@property NSString *finish;
@property BOOL done;
@property double retry, deadline;
@end
@implementation EditChat
@end

static EditChat *state(buffer *b) { return (__bridge EditChat *)chat_handle(b); }
static bool valid_call(id c) {
  return [c isKindOfClass:NSDictionary.class] && [c[@"id"] isKindOfClass:NSString.class] &&
         [c[@"function"] isKindOfClass:NSDictionary.class] &&
         [c[@"function"][@"name"] isKindOfClass:NSString.class] &&
         [c[@"function"][@"arguments"] isKindOfClass:NSString.class];
}

static NSArray *tools(void);

void *chat_open(const char *data, size_t len) {
  @autoreleasepool {
    EditChat *c = [EditChat new];
    c.tools = tools();
    c.effort = @"low";
    c.offsets = [NSMutableArray array];
    c.sections = [NSMutableArray array];
    c.styles = [NSMutableArray array];
    if (data) {
      id archive = json([NSData dataWithBytes:data length:len]);
      if (![archive isKindOfClass:NSDictionary.class] ||
          ![archive[@"messages"] isKindOfClass:NSArray.class] ||
          ![archive[@"draft"] isKindOfClass:NSString.class])
        return NULL;
      if (![archive[@"tools"] isKindOfClass:NSArray.class] ||
          ![archive[@"reasoning_effort"] isKindOfClass:NSString.class])
        return NULL;
      c.tools = archive[@"tools"];
      c.effort = archive[@"reasoning_effort"];
      c.messages = archive[@"messages"];
      c.model = string(archive[@"model"]);
      c.draft = archive[@"draft"];
      for (id m in c.messages) {
        if (![m isKindOfClass:NSDictionary.class] || ![m[@"content"] isKindOfClass:NSString.class] ||
            ![@[ @"system", @"user", @"assistant", @"tool" ] containsObject:string(m[@"role"])])
          return NULL;
        if (m[@"tool_calls"] && ![m[@"tool_calls"] isKindOfClass:NSArray.class]) return NULL;
        for (id call in m[@"tool_calls"])
          if (!valid_call(call)) return NULL;
        if ([m[@"role"] isEqual:@"tool"] && ![m[@"tool_call_id"] isKindOfClass:NSString.class]) return NULL;
      }
      if (![c.messages.firstObject[@"role"] isEqual:@"system"]) return NULL;
    } else {
      const char *home = getenv("HOME");
      NSString *path = [@(home ? home : "") stringByAppendingPathComponent:@".agents.md"];
      NSError *err = nil;
      NSString *system = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&err];
      if (!system && err.code != NSFileReadNoSuchFileError) return NULL;
      c.messages = [NSMutableArray arrayWithObject:[@{
                                     @"role" : @"system",
                                     @"content" : system ? system : @"You are a coding assistant inside Edit."
                                   } mutableCopy]];
      c.draft = @"";
    }
    return (__bridge_retained void *)c;
  }
}

void chat_close(void *object) {
  EditChat *c = (__bridge_transfer EditChat *)object;
  [c.transfer.session invalidateAndCancel];
}
bool chat_busy(void *object) {
  EditChat *c = (__bridge EditChat *)object;
  return c.transfer || c.retry;
}

char *chat_archive(buffer *b, size_t *len) {
  @autoreleasepool {
    EditChat *c = state(b);
    NSString *draft = slice(b, chat_draft(b), SIZE_MAX);
    if (!draft) return NULL;
    NSData *body = [NSJSONSerialization dataWithJSONObject:@{
      @"messages" : c.messages,
      @"model" : string(c.model),
      @"draft" : draft,
      @"tools" : c.tools,
      @"reasoning_effort" : c.effort
    }
                                                   options:0
                                                     error:nil];
    if (!body) return NULL;
    size_t header = strlen(CHAT_MAGIC);
    char *out = malloc(header + body.length + 1);
    if (out) {
      memcpy(out, CHAT_MAGIC, header);
      memcpy(out + header, body.bytes, body.length);
      *len = header + body.length;
      out[*len] = 0;
    }
    return out;
  }
}

enum { SYSTEM, USER, THINKING, ASSISTANT, CALL, RESULT, NOTICE };
static void section(EditChat *c, NSMutableData *out, size_t base, int style, NSString *heading,
                    NSString *body) {
  [c.sections addObject:@(base + out.length)];
  [c.styles addObject:@(style)];
  [out appendData:bytes(heading)];
  [out appendData:bytes(@"\n")];
  [out appendData:bytes(body)];
  [out appendData:bytes(@"\n\n")];
}

// A streamed delta redraws only the current message. Older turns keep their byte offsets.
static void display(edit_state *e, buffer *b, NSUInteger from, bool keepDraft) {
  EditChat *c = state(b);
  size_t base = from < c.offsets.count ? c.offsets[from].unsignedLongLongValue : 0;
  [c.offsets removeObjectsInRange:NSMakeRange(from, c.offsets.count - from)];
  while (c.sections.count && c.sections.lastObject.unsignedLongLongValue >= base) {
    [c.sections removeLastObject];
    [c.styles removeLastObject];
  }
  NSMutableData *out = [NSMutableData data];
  for (NSUInteger i = from; i < c.messages.count; i++) {
    NSDictionary *m = c.messages[i];
    [c.offsets addObject:@(base + out.length)];
    NSString *role = m[@"role"], *body = m[@"content"];
    if ([role isEqual:@"assistant"]) {
      if (string(m[@"reasoning_content"]).length)
        section(c, out, base, THINKING, @"Thinking", m[@"reasoning_content"]);
      if (body.length) section(c, out, base, ASSISTANT, @"Assistant", body);
      for (NSDictionary *call in m[@"tool_calls"]) {
        NSDictionary *f = call[@"function"];
        NSString *raw = string(f[@"arguments"]);
        id args = json(bytes(raw));
        NSMutableArray *fields = [NSMutableArray array];
        if ([args isKindOfClass:NSDictionary.class])
          for (NSString *key in [[args allKeys] sortedArrayUsingSelector:@selector(compare:)])
            [fields addObject:[NSString stringWithFormat:@"%@\n%@", key, args[key]]];
        section(c, out, base, CALL, [@"Tool · " stringByAppendingString:string(f[@"name"])],
                [args isKindOfClass:NSDictionary.class] ? [fields componentsJoinedByString:@"\n"]
                                                        : (chat_busy(chat_handle(b)) ? @"" : raw));
      }
      if (m[@"partial"] && (i + 1 != c.messages.count || !chat_busy(chat_handle(b))))
        section(c, out, base, NOTICE, @"Interrupted", string(m[@"partial"]));
    } else if ([role isEqual:@"tool"])
      section(c, out, base, RESULT, @"Tool result", body);
    else if ([role isEqual:@"system"])
      section(c, out, base, SYSTEM, @"System", body);
    else
      section(c, out, base, USER, @"You", body);
  }
  [c.offsets addObject:@(base + out.length)];
  if (!chat_busy(chat_handle(b))) {
    [c.sections addObject:@(base + out.length)];
    [c.styles addObject:@(USER)];
    [out appendData:bytes(@"You\n")];
  }
  chat_replace_view(e, b, base, out.bytes, out.length, keepDraft);
}

void chat_restore(buffer *b) {
  @autoreleasepool {
    display(NULL, b, 0, false);
  }
}
const char *chat_style(void *object, size_t pos) {
  EditChat *c = (__bridge EditChat *)object;
  NSUInteger lo = 0, hi = c.sections.count;
  while (lo < hi) {
    NSUInteger mid = lo + (hi - lo) / 2;
    if (c.sections[mid].unsignedLongLongValue <= pos)
      lo = mid + 1;
    else
      hi = mid;
  }
  static const char *styles[] = {"38;2;167;178;196", "38;2;127;204;255", "3;38;2;173;161;198",
                                 "38;2;232;232;229", "38;2;240;196;120", "38;2;151;210;167",
                                 "38;2;238;149;132"};
  return lo ? styles[c.styles[lo - 1].intValue] : NULL;
}
char *chat_saved_draft(void *object, size_t *len) {
  EditChat *c = (__bridge EditChat *)object;
  NSData *data = bytes(string(c.draft));
  *len = data.length;
  char *draft = malloc(*len + 1);
  if (draft && *len) memcpy(draft, data.bytes, *len);
  c.draft = nil;
  return draft;
}

static NSDictionary *tool(NSString *name, NSString *description, NSDictionary *properties,
                          NSArray *required) {
  return @{
    @"type" : @"function",
    @"function" : @{
      @"name" : name,
      @"description" : description,
      @"parameters" : @{@"type" : @"object", @"properties" : properties, @"required" : required}
    }
  };
}
static NSArray *tools(void) {
  NSDictionary *str = @{@"type" : @"string"}, *num = @{@"type" : @"integer"};
  return @[
    tool(@"list_buffers",
         @"List open buffers, names, lengths, cursor and selection byte offsets, and visible panes.", @{},
         @[]),
    tool(@"read_buffer",
         @"Read the current UTF-8 text of an open buffer. Optional start and length are bytes.",
         @{@"name" : str, @"start" : num, @"length" : num}, @[ @"name" ]),
    tool(@"edit_buffer",
         @"Replace one unique exact occurrence in an open buffer. Empty old_text inserts at its cursor.",
         @{@"name" : str, @"old_text" : str, @"new_text" : str}, @[ @"name", @"old_text", @"new_text" ]),
    tool(@"create_buffer", @"Create a new named editor buffer with this text. Use a new filename.",
         @{@"name" : str, @"text" : str}, @[ @"name", @"text" ]),
    tool(@"edit_help", @"Read Edit's built-in command and keybinding reference.", @{}, @[])
  ];
}
static NSString *execute(edit_state *e, NSDictionary *call) {
  NSString *fn = call[@"function"][@"name"];
  id a = json(bytes(call[@"function"][@"arguments"]));
  if (![a isKindOfClass:NSDictionary.class]) return @"Invalid tool arguments.";
  if ([fn isEqual:@"edit_help"]) return @(chat_help());
  NSMutableString *list = [NSMutableString string];
  buffer *b = NULL, *target = NULL;
  chat_buffer_info info, selected = {0};
  bool exact = false;
  unsigned matches = 0;
  for (int i = 0; chat_info(e, i, &info, &b); i++) {
    NSString *name = @(info.name);
    [list appendFormat:@"%@ · %zu bytes · cursor %zu (line %zu, column %zu)", name, info.length, info.point,
                       info.line, info.column];
    for (int j = 0; j < info.panes; j++) {
      [list appendFormat:@" · pane %d%@ at %zu", info.views[j].pane,
                         info.views[j].focused ? @" (focused)" : @"", info.views[j].point];
      if (info.views[j].mark != SIZE_MAX) [list appendFormat:@" mark %zu", info.views[j].mark];
    }
    [list appendFormat:@" · %@%@\n", info.writable ? @"editable" : @"read only",
                       info.dirty ? @" · modified" : @""];
    if ([name isEqual:a[@"name"]]) {
      target = b;
      selected = info;
      exact = true;
    } else if (!exact && [name.lastPathComponent isEqual:a[@"name"]]) {
      target = b;
      selected = info;
      matches++;
    }
  }
  if ([fn isEqual:@"list_buffers"]) return list;
  if (![a[@"name"] isKindOfClass:NSString.class] || [a[@"name"] containsString:@"\0"])
    return @"Invalid buffer name.";
  if ([fn isEqual:@"create_buffer"] && [a[@"text"] isKindOfClass:NSString.class]) {
    NSData *text = bytes(a[@"text"]);
    return @(chat_create(e, [a[@"name"] UTF8String], text.bytes, text.length));
  }
  if (!exact && matches > 1) return @"Ambiguous name. Use the full name from list_buffers.";
  if (!target) return @"Buffer not found. Use list_buffers and its exact name.";
  if ([fn isEqual:@"read_buffer"]) {
    for (NSString *key in @[ @"start", @"length" ])
      if (a[key] && (![a[key] isKindOfClass:NSNumber.class] || [a[key] longLongValue] < 0))
        return @"Invalid byte range.";
    NSString *text = slice(target, [a[@"start"] unsignedLongLongValue],
                           a[@"length"] ? [a[@"length"] unsignedLongLongValue] : SIZE_MAX);
    return text ? text : @"Invalid UTF-8 byte range.";
  }
  if (![fn isEqual:@"edit_buffer"] || ![a[@"old_text"] isKindOfClass:NSString.class] ||
      ![a[@"new_text"] isKindOfClass:NSString.class])
    return @"Unknown tool or invalid arguments.";
  if (!selected.writable) return @"Buffer is read only.";
  NSData *old = bytes(a[@"old_text"]), *replacement = bytes(a[@"new_text"]);
  size_t pos = selected.point;
  if (old.length) {
    size_t len = SIZE_MAX;
    char *data = chat_slice(target, 0, &len);
    if (!data) return @"Cannot read buffer.";
    NSData *doc = [NSData dataWithBytesNoCopy:data length:len freeWhenDone:YES];
    NSRange hit = [doc rangeOfData:old options:0 range:NSMakeRange(0, len)];
    if (hit.location == NSNotFound) return @"Old text does not match.";
    pos = hit.location;
    if ([doc rangeOfData:old options:0 range:NSMakeRange(pos + 1, len - pos - 1)].location != NSNotFound)
      return @"Old text is ambiguous. Include surrounding text.";
  }
  return @(chat_edit(e, target, pos, old.length, replacement.bytes, replacement.length));
}

static void request(EditChat *c) {
  NSMutableArray *messages = [NSMutableArray array];
  // The last record is the reply being requested. Preserve earlier partial replies
  // as text so the model can discuss them without replaying unfinished tool calls.
  for (NSUInteger i = 0; i + 1 < c.messages.count; i++) {
    NSDictionary *m = c.messages[i];
    if (!m[@"partial"]) {
      [messages addObject:m];
      continue;
    }
    NSMutableString *text = [string(m[@"content"]) mutableCopy];
    for (NSDictionary *call in m[@"tool_calls"])
      [text appendFormat:@"\nTool · %@\n%@", call[@"function"][@"name"], call[@"function"][@"arguments"]];
    [text appendFormat:@"\nInterrupted · %@", string(m[@"partial"])];
    NSMutableDictionary *partial = [@{@"role" : @"assistant", @"content" : text} mutableCopy];
    if (m[@"reasoning_content"]) partial[@"reasoning_content"] = m[@"reasoning_content"];
    [messages addObject:partial];
  }
  NSMutableDictionary *body = [@{
    @"messages" : messages,
    @"tools" : c.tools,
    @"stream" : @YES,
    @"reasoning_effort" : c.effort
  } mutableCopy];
  if (c.model.length) body[@"model"] = c.model;
  NSURL *url = [NSURL URLWithString:@(light_url())];
  ChatTransfer *t = [ChatTransfer new];
  t.received = [NSMutableData data];
  c.transfer = t;
  c.pending = [NSMutableData data];
  c.finish = nil;
  c.done = NO;
  c.retry = 0;
  if (!url.host.length || ![@[ @"http", @"https" ] containsObject:string(url.scheme)]) {
    t.error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadURL userInfo:@{NSLocalizedDescriptionKey: @"Set EDIT_COMPLETION_URL or ~/.edit/completion-url to an HTTP(S) chat completions URL."}];
    t.finished = YES;
    return;
  }
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
  req.HTTPMethod = @"POST";
  [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
  NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
  cfg.connectionProxyDictionary = @{};
  cfg.timeoutIntervalForRequest = 190;
  t.session = [NSURLSession sessionWithConfiguration:cfg delegate:t delegateQueue:nil];
  [[t.session dataTaskWithRequest:req] resume];
}

static void begin_round(EditChat *c) {
  c.deadline = NSProcessInfo.processInfo.systemUptime + 190;
  [c.messages
      addObject:[@{@"role" : @"assistant", @"content" : @"", @"partial" : @"Generation was interrupted."}
                    mutableCopy]];
  request(c);
}
static void interrupt(EditChat *c, NSString *reason) {
  [c.transfer.session invalidateAndCancel];
  c.transfer = nil;
  c.retry = 0;
  c.messages.lastObject[@"partial"] = reason;
}
bool chat_stop(edit_state *e, buffer *b) {
  @autoreleasepool {
    EditChat *c = state(b);
    if (!chat_busy(chat_handle(b))) return false;
    interrupt(c, @"Canceled.");
    display(e, b, c.messages.count - 1, true);
    return true;
  }
}

static NSString *consume(EditChat *c, NSData *data) {
  [c.pending appendData:data];
  const char *p = c.pending.bytes;
  size_t at = 0, len = c.pending.length;
  while (at < len) {
    const char *nl = memchr(p + at, '\n', len - at);
    if (!nl) break;
    size_t n = nl - (p + at);
    const char *line = p + at;
    at += n + 1;
    if (n && line[n - 1] == '\r') n--;
    if (n < 5 || memcmp(line, "data:", 5)) continue;
    line += 5;
    n -= 5;
    while (n && *line == ' ') {
      line++;
      n--;
    }
    if (n == 6 && !memcmp(line, "[DONE]", 6)) {
      c.done = YES;
      continue;
    }
    id event = json([NSData dataWithBytes:line length:n]);
    if (![event isKindOfClass:NSDictionary.class] || event[@"error"] ||
        ![event[@"choices"] isKindOfClass:NSArray.class])
      return @"Light returned an invalid or failed stream.";
    if (!c.model.length && string(event[@"model"]).length) c.model = event[@"model"];
    id choice = [event[@"choices"] firstObject];
    if (!choice) continue;
    if (![choice isKindOfClass:NSDictionary.class] || ![choice[@"delta"] isKindOfClass:NSDictionary.class])
      return @"Invalid stream choice.";
    NSDictionary *delta = choice[@"delta"];
    NSMutableDictionary *m = c.messages.lastObject;
    for (NSString *key in @[ @"reasoning_content", @"content" ])
      if (string(delta[key]).length) m[key] = [string(m[key]) stringByAppendingString:delta[key]];
    if (string(choice[@"finish_reason"]).length) c.finish = choice[@"finish_reason"];
    if (delta[@"tool_calls"] && ![delta[@"tool_calls"] isKindOfClass:NSArray.class])
      return @"Invalid tool call stream.";
    for (id part in delta[@"tool_calls"]) {
      if (![part isKindOfClass:NSDictionary.class] || ![part[@"index"] isKindOfClass:NSNumber.class])
        return @"Invalid tool index.";
      NSUInteger index = [part[@"index"] unsignedIntegerValue];
      NSMutableArray *calls = m[@"tool_calls"];
      if (!calls) m[@"tool_calls"] = calls = [NSMutableArray array];
      if (index > calls.count) return @"Out-of-order tool call.";
      if (index == calls.count)
        [calls addObject:[@{
                 @"id" : @"",
                 @"type" : @"function",
                 @"function" : [@{@"name" : @"", @"arguments" : @""} mutableCopy]
               } mutableCopy]];
      NSMutableDictionary *call = calls[index], *f = call[@"function"];
      if (string(part[@"id"]).length) call[@"id"] = part[@"id"];
      id fragment = part[@"function"];
      if (fragment && ![fragment isKindOfClass:NSDictionary.class]) return @"Invalid function fragment.";
      for (NSString *key in @[ @"name", @"arguments" ])
        if (string(fragment[key]).length) f[key] = [f[key] stringByAppendingString:fragment[key]];
    }
  }
  if (at) [c.pending replaceBytesInRange:NSMakeRange(0, at) withBytes:NULL length:0];
  return nil;
}

bool chat_tick(edit_state *e, buffer *b) {
  @autoreleasepool {
    EditChat *c = state(b);
    if (c.retry && NSProcessInfo.processInfo.systemUptime >= c.retry) request(c);
    ChatTransfer *t = c.transfer;
    if (!t) return c.retry != 0;
    NSData *data;
    NSInteger status;
    BOOL finished;
    NSError *err;
    @synchronized(t) {
      data = t.received;
      t.received = [NSMutableData data];
      finished = t.finished;
      status = t.response.statusCode;
      err = t.error;
    }
    NSUInteger from = c.messages.count - 1;
    NSString *problem = nil;
    if (status == 200)
      problem = consume(c, data);
    else if (data.length)
      [c.pending appendData:data];
    if (!problem && !finished) {
      if (data.length && status == 200) display(e, b, from, true);
      return true;
    }
    if (problem)
      [t.session invalidateAndCancel];
    else
      [t.session finishTasksAndInvalidate];
    c.transfer = nil;
    if (!problem && err) problem = err.localizedDescription;
    if (!problem && status != 200) {
      id body = json(c.pending);
      id guidance = [body isKindOfClass:NSDictionary.class] ? body[@"guidance"] : nil;
      double delay = [[t.response valueForHTTPHeaderField:@"Retry-After"] doubleValue];
      if (delay <= 0) delay = 5;
      double retry = NSProcessInfo.processInfo.systemUptime + delay;
      if ((status == 503 || status == 429) && [guidance isKindOfClass:NSDictionary.class] &&
          [guidance[@"retryable"] boolValue] && retry <= c.deadline) {
        c.retry = retry;
        chat_status(e, b, "chat waiting for Light · retrying");
        return true;
      }
      problem = [NSString stringWithFormat:@"Light HTTP %ld. %@", (long)status,
                                           [guidance isKindOfClass:NSDictionary.class]
                                               ? string(guidance[@"next_action"])
                                               : @""];
    }
    if (!problem && (!c.done || ![@[ @"stop", @"tool_calls" ] containsObject:string(c.finish)]))
      problem =
          [NSString stringWithFormat:@"Incomplete response (%@).", c.finish ? c.finish : @"disconnected"];
    NSMutableDictionary *m = c.messages.lastObject;
    NSArray *calls = m[@"tool_calls"];
    if (!problem && ((calls.count > 0) != [c.finish isEqual:@"tool_calls"]))
      problem = @"Incomplete tool calls.";
    NSMutableSet *ids = [NSMutableSet set];
    for (NSDictionary *call in calls) {
      if (!string(call[@"id"]).length || !string(call[@"function"][@"name"]).length ||
          [ids containsObject:call[@"id"]])
        problem = @"Incomplete or duplicate tool call.";
      [ids addObject:call[@"id"]];
    }
    if (problem)
      interrupt(c, problem);
    else {
      [m removeObjectForKey:@"partial"];
      for (NSDictionary *call in calls)
        [c.messages
            addObject:[@{@"role" : @"tool", @"tool_call_id" : call[@"id"], @"content" : execute(e, call)}
                          mutableCopy]];
      if (calls.count) begin_round(c);
    }
    display(e, b, from, true);
    if (!chat_busy(chat_handle(b)))
      chat_status(e, b, problem ? "chat interrupted · see transcript" : "chat finished");
    return chat_busy(chat_handle(b));
  }
}

int chat_command(edit_state *e, int command) {
  @autoreleasepool {
    buffer *b = (command == CHAT_NEW || command == CHAT_OPEN)
                    ? chat_target(e, command == CHAT_NEW)
                    : chat_active(e, command == CHAT_CLEAR || command == CHAT_SEND);
    if (!b) return 0;
    EditChat *c = state(b);
    if (command == CHAT_OPEN || command == CHAT_NEW)
      return set_status(e, "chat: C-c C-c send · C-c p/n navigate · C-x C-s save"), 0;
    if (command == CHAT_PREV || command == CHAT_NEXT) {
      size_t pos = chat_point(e, b, SIZE_MAX), next = command == CHAT_NEXT ? chat_draft(b) : 0;
      for (NSNumber *offset in c.sections) {
        size_t n = offset.unsignedLongLongValue;
        if (command == CHAT_PREV && n < pos) next = n;
        if (command == CHAT_NEXT && n > pos) {
          next = n;
          break;
        }
      }
      chat_point(e, b, next);
      return 0;
    }
    if (command == CHAT_CLEAR) {
      [c.transfer.session invalidateAndCancel];
      c.transfer = nil;
      c.retry = 0;
      c.model = nil;
      [c.messages removeObjectsInRange:NSMakeRange(1, c.messages.count - 1)];
      display(e, b, 0, false);
      chat_point(e, b, chat_draft(b));
      return set_status(e, "chat context cleared"), 0;
    }
    if (chat_busy(chat_handle(b))) return set_status(e, "chat running · C-g stops"), 0;
    NSString *draft = slice(b, chat_draft(b), SIZE_MAX);
    if (!draft) return set_status(e, "chat draft must be UTF-8"), 0;
    NSUInteger from = c.messages.count;
    if ([draft stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length)
      [c.messages addObject:[@{@"role" : @"user", @"content" : draft} mutableCopy]];
    else if (!c.messages.lastObject[@"partial"] && ![c.messages.lastObject[@"role"] isEqual:@"tool"])
      return set_status(e, "type a message after You"), 0;
    begin_round(c);
    display(e, b, from, false);
    chat_point(e, b, chat_draft(b));
    return set_status(e, "chat running · C-g stops"), 0;
  }
}
