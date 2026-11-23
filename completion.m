// Inline code completion for Edit. Build with Foundation and libcurl.
// Only an explicit editor command sends context to Light. All network activity,
// retry state, prompt construction, and stream decoding live in this module.
#import <Foundation/Foundation.h>
#include <curl/curl.h>
#include <unistd.h>
#include "completion.h"

static NSString *excerpt(edit_stream s, size_t start, size_t end) {
  NSMutableData *bytes = [NSMutableData dataWithLength:end - start];
  char *out = bytes.mutableBytes;
  for (size_t i = start; i < end; i++) *out++ = buffer_at(s.document, i);
  return [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
}

static NSString *completion_prompt(edit_stream s) {
  size_t head = 0, before = s.cursor, after = s.cursor;
  for (int lines = 0; head < s.length && lines < 10; )
    if (buffer_at(s.document, head++) == '\n') lines++;
  for (int lines = 0; before && lines < 21; before--)
    if (buffer_at(s.document, before - 1) == '\n' && ++lines == 21) break;
  for (int lines = 0; after < s.length && lines < 21; )
    if (buffer_at(s.document, after++) == '\n') lines++;

  NSString *top = excerpt(s, 0, MIN(before, head));
  NSString *left = excerpt(s, before, s.cursor);
  NSString *right = excerpt(s, s.cursor, MAX(head, after));
  if (!top || !left || !right) return nil;
  NSMutableString *prompt = [NSMutableString stringWithFormat:
    @"File: %s\n```\n%@%@%@<CURSOR>%@%@\n```\n", s.filename, top,
    before > head ? @"...\n" : @"", left, right, MAX(head, after) < s.length ? @"...\n" : @""];
  if (s.mark != s.cursor) {
    NSString *selection = excerpt(s, MIN(s.mark, s.cursor), MAX(s.mark, s.cursor));
    if (!selection) return nil;
    [prompt appendFormat:@"Rewrite this entire selection:\n```\n%@\n```\n", selection];
  } else {
    NSString *prefix = [left componentsSeparatedByString:@"\n"].lastObject;
    NSString *suffix = [right componentsSeparatedByString:@"\n"].firstObject;
    [prompt appendFormat:@"Fill the hole on this line: %@<CURSOR>%@\n"
                          "The prefix and suffix are already in the file. "
                          "Return only the missing characters between them.\n", prefix, suffix];
  }
  [prompt appendString:@"Return only the minimal code to insert, matching the file's style. "
                        "Preserve indentation. Omit explanations and Markdown fences."];
  return prompt;
}

// libcurl can split a UTF-8 character or an SSE line between callbacks.
typedef struct {
  CURL *http;
  NSMutableData *line, *output, *failure;
  bool done;
  const char *error;
} completion_stream;

static size_t receive_data(char *bytes, size_t size, size_t count, void *context) {
  completion_stream *s = context;
  size_t len = size * count;
  long status = 0;
  curl_easy_getinfo(s->http, CURLINFO_RESPONSE_CODE, &status);
  if (status != 200) {
    if (s->failure.length + len <= 65536) [s->failure appendBytes:bytes length:len];
    return len;
  }
  for (size_t at = 0; at < len;) {
    char *newline = memchr(bytes + at, '\n', len - at);
    size_t n = newline ? (size_t)(newline - (bytes + at)) : len - at;
    [s->line appendBytes:bytes + at length:n];
    at += n;
    if (!newline) break;
    at++;
    NSString *line = [[NSString alloc] initWithData:s->line encoding:NSUTF8StringEncoding];
    s->line.length = 0;
    if ([line hasSuffix:@"\r"]) line = [line substringToIndex:line.length - 1];
    if (![line hasPrefix:@"data:"]) continue;
    NSString *data = [[line substringFromIndex:5] stringByTrimmingCharactersInSet:
                      NSCharacterSet.whitespaceCharacterSet];
    if ([data isEqualToString:@"[DONE]"]) { s->done = true; continue; }
    NSDictionary *event = [NSJSONSerialization JSONObjectWithData:
      [data dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    NSArray *choices = [event isKindOfClass:NSDictionary.class] ? event[@"choices"] : nil;
    if (![choices isKindOfClass:NSArray.class] || event[@"error"]) {
      s->error = "invalid or failed completion stream";
      return 0;
    }
    NSDictionary *choice = choices.firstObject;
    NSDictionary *delta = [choice isKindOfClass:NSDictionary.class] ? choice[@"delta"] : nil;
    NSString *content = [delta isKindOfClass:NSDictionary.class] ? delta[@"content"] : nil;
    if ([content isKindOfClass:NSString.class])
      [s->output appendData:[content dataUsingEncoding:NSUTF8StringEncoding]];
  }
  return len;
}

const char *light_url(void) {
  const char *url = getenv("EDIT_COMPLETION_URL");
  if (url && *url) return url;
  const char *home = getenv("HOME");
  if (home && *home) {
    NSString *path = [@(home) stringByAppendingPathComponent:@".edit/completion-url"];
    NSString *value = [[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil]
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (value.length && !setenv("EDIT_COMPLETION_URL", value.UTF8String, 1)) return getenv("EDIT_COMPLETION_URL");
  }
  return "";
}

static void completion_run(edit_stream source) {
  @autoreleasepool {
    NSString *prompt = completion_prompt(source);
    if (!prompt) {
      set_status(source.editor, "completion needs UTF-8 text");
      return;
    }
    NSData *body = [NSJSONSerialization dataWithJSONObject:@{
      @"messages": @[@{@"role": @"user", @"content": prompt}], @"stream": @YES,
      @"reasoning_effort": @"none"
    } options:0 error:nil];
    CURL *http = curl_easy_init();
    CURLM *multi = curl_multi_init();
    struct curl_slist *headers = curl_slist_append(NULL, "Content-Type: application/json");
    const char *result = "completion could not start";
    if (http && multi && headers && body) {
      completion_stream stream = {http, [NSMutableData data], [NSMutableData data], [NSMutableData data], false, NULL};
      curl_easy_setopt(http, CURLOPT_URL, light_url());
      curl_easy_setopt(http, CURLOPT_NOPROXY, "*");
      curl_easy_setopt(http, CURLOPT_HTTPHEADER, headers);
      curl_easy_setopt(http, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)body.length);
      curl_easy_setopt(http, CURLOPT_COPYPOSTFIELDS, body.bytes);
      curl_easy_setopt(http, CURLOPT_CONNECTTIMEOUT, 5L);
      curl_easy_setopt(http, CURLOPT_WRITEFUNCTION, receive_data);
      curl_easy_setopt(http, CURLOPT_WRITEDATA, &stream);
      NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 190;
      struct curl_waitfd input = {STDIN_FILENO, CURL_WAIT_POLLIN, 0};
      while (curl_multi_add_handle(multi, http) == CURLM_OK) {
        bool canceled = false;
        int running = 1;
        CURLMcode rc = CURLM_OK;
        while (running && rc == CURLM_OK) {
          if (!edit_stream_write(&source, NULL, 0)) { canceled = true; break; }
          @autoreleasepool { rc = curl_multi_perform(multi, &running); }
          if (stream.output.length && !edit_stream_write(&source, stream.output.bytes, stream.output.length)) {
            canceled = true; break;
          }
          stream.output.length = 0;
          if (running && rc == CURLM_OK) rc = curl_multi_poll(multi, &input, 1, 100, NULL);
        }
        int queued = 0;
        CURLMsg *msg = curl_multi_info_read(multi, &queued);
        CURLcode transfer = msg && msg->msg == CURLMSG_DONE ? msg->data.result : CURLE_ABORTED_BY_CALLBACK;
        long code = 0;
        curl_easy_getinfo(http, CURLINFO_RESPONSE_CODE, &code);
        curl_multi_remove_handle(multi, http);
        if (canceled) { result = "completion canceled"; break; }
        if (stream.error) { result = stream.error; break; }
        if (rc != CURLM_OK) { result = curl_multi_strerror(rc); break; }
        if (transfer != CURLE_OK) { result = curl_easy_strerror(transfer); break; }
        if (code == 200) { result = stream.done ? "completion finished" : "completion stream interrupted"; break; }

        // Light does not retain a cold-start request. Replay only retryable admissions.
        NSDictionary *reply = stream.failure.length ? [NSJSONSerialization JSONObjectWithData:stream.failure options:0 error:nil] : nil;
        NSDictionary *guidance = [reply isKindOfClass:NSDictionary.class] ? reply[@"guidance"] : nil;
        curl_off_t delay = 0;
        curl_easy_getinfo(http, CURLINFO_RETRY_AFTER, &delay);
        if (delay <= 0) delay = 5;
        NSTimeInterval retry = NSProcessInfo.processInfo.systemUptime + delay;
        if ((code != 503 && code != 429) || ![guidance isKindOfClass:NSDictionary.class] ||
            ![guidance[@"retryable"] boolValue] || retry > deadline) {
          NSDictionary *error = [reply isKindOfClass:NSDictionary.class] ? reply[@"error"] : nil;
          NSString *reason = [error isKindOfClass:NSDictionary.class] ? error[@"code"] : nil;
          set_status(source.editor, "completion HTTP %ld %s", code,
                     [reason isKindOfClass:NSString.class] ? reason.UTF8String : "");
          result = NULL; break;
        }
        stream.failure.length = 0;
        set_status(source.editor, "completion HTTP %ld; retrying in %llds (any key cancels)", code, (long long)delay);
        render(source.editor);
        while (NSProcessInfo.processInfo.systemUptime < retry && edit_stream_write(&source, NULL, 0))
          curl_multi_poll(multi, &input, 1, 100, NULL);
        if (!edit_stream_write(&source, NULL, 0)) { result = "completion canceled"; break; }
      }
    }
    if (result) set_status(source.editor, "%s", result);
    curl_slist_free_all(headers);
    if (http) curl_easy_cleanup(http);
    if (multi) curl_multi_cleanup(multi);
  }
}

int cmd_complete(edit_state *e, int key) {
  (void)key;
  if (!*light_url()) return set_status(e,"set EDIT_COMPLETION_URL or ~/.edit/completion-url"),0;
  edit_stream source;
  if (!edit_stream_open(e, &source)) return 0;
  size_t start = MIN(source.cursor, source.mark);
  source.insert_at = MAX(source.cursor, source.mark);
  if (start == source.insert_at)
    for (int i = 0; start && i < 2000; i++) start = utf8_prev_pos(source.document, start);
  kill_push(e, source.document, start, source.insert_at);
  set_status(e, "completing (any key cancels)");
  render(e);
  completion_run(source);
  return 0;
}
