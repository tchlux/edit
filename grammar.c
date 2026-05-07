// ___________________________________________________________________
//                            grammar.c
//
// DESCRIPTION
//  Small native syntax grammar loader for edit. It keeps grammars as
//  plain line-oriented text and uses regex.c for matching.
//
// COMPILATION
//  cc -std=c11 -Wall -Wextra -pedantic -c grammar.c
// ___________________________________________________________________

#include "grammar.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void matcha(const char * regex, const char * string,
            int * n, int ** starts, int ** ends);

static char * _space(char * s) {
  while ((*s != '\0') && (! isspace((unsigned char) *s))) s++;
  if (*s == '\0') return s;
  *s++ = '\0';
  while (isspace((unsigned char) *s)) s++;
  return s;
}

static void _copy(char * dst, size_t n, const char * src) {
  if (n == 0) return;
  snprintf(dst, n, "%s", src);
}

static char * _trim(char * s) {
  while (isspace((unsigned char) *s)) s++;
  for (size_t n = strlen(s); (n > 0) && isspace((unsigned char) s[n-1]); n--)
    s[n-1] = '\0';
  return s;
}

static const char * _sgr(grammar * g, const char * scope) {
  for (int i = 0; i < g->n_styles; i++)
    if (strcmp(g->styles[i].scope, scope) == 0)
      return g->styles[i].sgr;
  return "0";
}

static void _style(grammar * g, const char * scope, const char * sgr) {
  if (g->n_styles >= GRAMMAR_MAX_STYLES) return;
  _copy(g->styles[g->n_styles].scope, GRAMMAR_SCOPE_SIZE, scope);
  _copy(g->styles[g->n_styles].sgr, GRAMMAR_SGR_SIZE, sgr);
  g->n_styles++;
}

static void _rule(grammar * g, const char * scope, const char * value, int word) {
  if (g->n_rules >= GRAMMAR_MAX_RULES) return;
  _copy(g->rules[g->n_rules].scope, GRAMMAR_SCOPE_SIZE, scope);
  _copy(g->rules[g->n_rules].regex, GRAMMAR_REGEX_SIZE, value);
  g->rules[g->n_rules].word = word;
  g->n_rules++;
}

static void _parse(grammar * g, char * line) {
  char * kind = _trim(line);
  if ((*kind == '\0') || (*kind == '#')) return;
  char * scope = _space(kind);
  char * value = _space(scope);

  if (strcmp(kind, "style") == 0) _style(g, scope, value);
  else if (strcmp(kind, "rule") == 0) _rule(g, scope, value, 0);
  else if (strcmp(kind, "word") == 0) {
    while (*value != '\0') {
      char * next = _space(value);
      _rule(g, scope, value, 1);
      value = next;
    }
  }
}

void grammar_load_default(grammar * g) {
  memset(g, 0, sizeof(*g));
  _style(g, "comment", "90");
  _style(g, "string", "32");
  _style(g, "number", "36");
  _style(g, "keyword", "35");
  _rule(g, "comment", "//.*", 0);
  _rule(g, "string", "\"{[\"\n]}*\"", 0);
  _rule(g, "number", "[0123456789][0123456789]*", 0);

  char words[] = "word keyword int char return if else for while struct static void size_t";
  _parse(g, words);
}

int grammar_load(grammar * g, const char * path) {
  memset(g, 0, sizeof(*g));
  FILE * f = fopen(path, "r");
  if (f == NULL) return -1;

  char line[512];
  while (fgets(line, sizeof(line), f) != NULL) {
    _parse(g, line);
  }

  fclose(f);
  return 0;
}

static int _boundary(char c) {
  return ! (isalnum((unsigned char) c) || c == '_');
}

static void _paint(const char ** sgrs, size_t len, size_t start, size_t end,
                   const char * sgr) {
  if (start > len) start = len;
  if (end > len) end = len;
  for (size_t i = start; i < end; i++)
    if (sgrs[i] == NULL) sgrs[i] = sgr;
}

static void _word(const char ** sgrs, const char * line, size_t len,
                  const char * word, const char * sgr) {
  size_t n = strlen(word);
  if (n == 0 || n > len) return;
  for (size_t i = 0; i + n <= len; i++)
    if ((i == 0 || _boundary(line[i-1])) &&
        (i + n == len || _boundary(line[i+n])) &&
        memcmp(line + i, word, n) == 0)
      _paint(sgrs, len, i, i + n, sgr);
}

int grammar_highlight(grammar * g, const char * line, size_t len,
                      grammar_span * spans, int max_spans) {
  if (len == 0 || max_spans <= 0) return 0;
  char * text = malloc(len + 1);
  const char ** sgrs = calloc(len, sizeof(*sgrs));
  if (text == NULL || sgrs == NULL) {
    free(text);
    free(sgrs);
    return -1;
  }
  memcpy(text, line, len);
  text[len] = '\0';

  for (int i = 0; i < g->n_rules; i++) {
    const char * sgr = _sgr(g, g->rules[i].scope);
    if (g->rules[i].word) {
      _word(sgrs, line, len, g->rules[i].regex, sgr);
    } else {
      int n = GRAMMAR_MAX_SPANS;
      int * starts = NULL;
      int * ends = NULL;
      matcha(g->rules[i].regex, text, &n, &starts, &ends);
      for (int j = 0; j < n; j++)
        if (starts[j] >= 0 && ends[j] > starts[j])
          _paint(sgrs, len, (size_t) starts[j], (size_t) ends[j], sgr);
      free(starts);
    }
  }

  int n_spans = 0;
  for (size_t i = 0; i < len && n_spans < max_spans; i++) {
    if (sgrs[i] == NULL) continue;
    spans[n_spans].start = i;
    spans[n_spans].sgr = sgrs[i];
    while (i < len && sgrs[i] == spans[n_spans].sgr) i++;
    spans[n_spans].end = i--;
    n_spans++;
  }

  free(text);
  free(sgrs);
  return n_spans;
}

int grammar_match(grammar * g, const char * line, size_t len,
                  int * start, int * end, const char ** sgr) {
  grammar_span span;
  int n = grammar_highlight(g, line, len, &span, 1);
  if (n <= 0) return n;
  *start = (int) span.start;
  *end = (int) span.end;
  *sgr = span.sgr;
  return 1;
}
