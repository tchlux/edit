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

void match(const char * regex, const char * string, int * start, int * end);

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

int grammar_load(grammar * g, const char * path) {
  memset(g, 0, sizeof(*g));
  FILE * f = fopen(path, "r");
  if (f == NULL) return -1;

  char line[512];
  while (fgets(line, sizeof(line), f) != NULL) {
    char * kind = _trim(line);
    if ((*kind == '\0') || (*kind == '#')) continue;
    char * scope = _space(kind);
    char * value = _space(scope);

    if ((strcmp(kind, "style") == 0) && (g->n_styles < GRAMMAR_MAX_STYLES)) {
      _copy(g->styles[g->n_styles].scope, GRAMMAR_SCOPE_SIZE, scope);
      _copy(g->styles[g->n_styles].sgr, GRAMMAR_SGR_SIZE, value);
      g->n_styles++;
    } else if ((strcmp(kind, "rule") == 0) && (g->n_rules < GRAMMAR_MAX_RULES)) {
      _copy(g->rules[g->n_rules].scope, GRAMMAR_SCOPE_SIZE, scope);
      _copy(g->rules[g->n_rules].regex, GRAMMAR_REGEX_SIZE, value);
      g->n_rules++;
    }
  }

  fclose(f);
  return 0;
}

int grammar_match(grammar * g, const char * line, size_t len,
                  int * start, int * end, const char ** sgr) {
  char * text = malloc(len + 1);
  if (text == NULL) return -1;
  memcpy(text, line, len);
  text[len] = '\0';

  for (int i = 0; i < g->n_rules; i++) {
    match(g->rules[i].regex, text, start, end);
    if (*start >= 0) {
      *sgr = _sgr(g, g->rules[i].scope);
      free(text);
      return 1;
    }
  }

  free(text);
  return 0;
}
