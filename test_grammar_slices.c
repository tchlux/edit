// Exercise grammar highlighting on bounded, non-NUL-terminated input.
// Run with: sh test-grammar.sh
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include "grammar.h"

static void custom(grammar *g, const char *pattern) {
  memset(g, 0, sizeof(*g));
  strcpy(g->styles[0].scope, "test");
  strcpy(g->styles[0].sgr, "31");
  g->n_styles = 1;
  strcpy(g->rules[0].scope, "test");
  strcpy(g->rules[0].regex, pattern);
  g->n_rules = 1;
}

static void check(const char *pattern, const char *text, size_t len,
                  int count, size_t start, size_t end) {
  grammar g;
  custom(&g, pattern);
  // Exact allocation: ASan catches any attempt to read a terminator.
  char *slice = malloc(len ? len : 1);
  assert(slice != NULL);
  memcpy(slice, text, len);
  grammar_span spans[8];
  int n = grammar_highlight(&g, NULL, slice, len, spans, 8);
  assert(n == count);
  if (n) {
    assert(spans[0].start == start && spans[0].end == end);
    assert(strcmp(spans[0].sgr, "31") == 0);
  }
  free(slice);
}

// Compare slice and terminated input for default and custom grammars.
static void compare(grammar *initial, const char *path, const char *text,
                    size_t len, int cap) {
  char *slice = malloc(len ? len : 1), *copy = malloc(len + 1);
  assert(slice && copy);
  memcpy(slice, text, len);
  memcpy(copy, text, len);
  copy[len] = '\0';
  grammar g = *initial, h = *initial;
  grammar_span a[64], b[64];
  int n = grammar_highlight(&g, path, slice, len, a, cap);
  int m = grammar_highlight(&h, path, copy, len, b, cap);
  assert(n == m && n >= 0);
  for (int i = 0; i < n; i++) {
    assert(a[i].start == b[i].start && a[i].end == b[i].end);
    assert(a[i].end <= len && a[i].start < a[i].end);
    assert(a[i].attr == b[i].attr);
    assert((a[i].sgr == NULL) == (b[i].sgr == NULL));
    if (a[i].sgr) assert(strcmp(a[i].sgr, b[i].sgr) == 0);
  }
  assert(g.triple_quote == h.triple_quote && g.block_comment == h.block_comment);
  assert(g.markdown_fence == h.markdown_fence && g.string_interpolation == h.string_interpolation);
  free(slice); free(copy);
}

int main(void) {
  check("b", "abc", 1, 0, 0, 0);
  check("b{.}", "abc", 2, 1, 1, 2);
  check("{.}a", "abc", 1, 1, 0, 1);
  check("aa", "aaaa", 4, 1, 0, 4); // overlapping matches paint one span
  check("a?", "ba", 2, 1, 1, 2); // ignore zero-length matches
  check("{a}", "b", 1, 1, 0, 1); // clamp legacy terminating-NUL span
  check("b", "a\0b", 3, 0, 0, 0); // retain early-NUL regex behavior
  check("[*]", "x*x", 3, 1, 1, 2); // vendored upstream fix remains
  check("[", "abc", 3, 0, 0, 0); // malformed rules remain ignored

  grammar g;
  custom(&g, "a");
  grammar_span spans[4];
  assert(grammar_highlight(&g, NULL, NULL, 0, spans, 4) == 0);
  assert(grammar_highlight(&g, NULL, "a", 1, spans, 0) == 0);
  // Rule order and word-boundary behavior are unchanged.
  strcpy(g.rules[0].regex, "a");
  g.rules[1] = g.rules[0];
  strcpy(g.rules[1].scope, "second");
  strcpy(g.rules[1].regex, "ab");
  g.n_rules = 2;
  g.styles[1] = g.styles[0];
  strcpy(g.styles[1].scope, "second");
  strcpy(g.styles[1].sgr, "32");
  g.n_styles = 2;
  int n = grammar_highlight(&g, NULL, "ab", 2, spans, 4);
  assert(n == 2 && spans[0].start == 0 && spans[0].end == 1 && !strcmp(spans[0].sgr,"31"));
  assert(spans[1].start == 1 && spans[1].end == 2 && !strcmp(spans[1].sgr,"32"));

  custom(&g, "a");
  g.rules[0].word = 1;
  n = grammar_highlight(&g, NULL, "a ab a", 6, spans, 4);
  assert(n == 2 && spans[0].start == 0 && spans[0].end == 1);
  assert(spans[1].start == 5 && spans[1].end == 6);

  const char *patterns[] = {"a", "[ab]", "aa", "a*", "a?", "{a}", "a{.}", "{.}a", "[*]", "["};
  const char *texts[] = {"", "aaab", "*a*", "a\0b", "int main() { return 42; }", "// a comment", "# Heading", "'quoted'", "/* open", "```"};
  const char *paths[] = {"test.c", "notes.md", "source.f90"};
  for (size_t p = 0; p < sizeof(patterns)/sizeof(patterns[0]); p++) {
    custom(&g, patterns[p]);
    for (size_t t = 0; t < sizeof(texts)/sizeof(texts[0]); t++)
      for (size_t len = 0; len <= strlen(texts[t]); len++)
        for (int cap = 1; cap <= 64; cap += 63)
          compare(&g, NULL, texts[t], len, cap);
  }
  for (size_t p = 0; p < sizeof(paths)/sizeof(paths[0]); p++) {
    grammar_load_default(&g);
    for (size_t t = 0; t < sizeof(texts)/sizeof(texts[0]); t++)
      for (size_t len = 0; len <= strlen(texts[t]); len++)
        compare(&g, paths[p], texts[t], len, 64);
  }
  // A custom prose rule must retain spell-check attributes on the slice.
  custom(&g, "{.}a.*b");
  strcpy(g.rules[0].scope, "comment");
  strcpy(g.styles[0].scope, "comment");
  n = grammar_highlight(&g, NULL, "aab!", 3, spans, 4);
  assert(n == 1 && spans[0].start == 0 && spans[0].end == 3);
  assert(spans[0].attr & GRAMMAR_ATTR_SPELL);
  puts("Grammar slice integration tests passed.");
  return 0;
}
