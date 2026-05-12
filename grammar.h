// ___________________________________________________________________
//                            grammar.h
//
// Tiny syntax grammar interface for edit. Grammar files are line based:
//
//   style scope sgr
//   rule  scope regex
//   word  scope word...
//
// Example:
//   style comment 90
//   rule  comment //.*
//   word  keyword int return
// ___________________________________________________________________

#ifndef EDIT_GRAMMAR_H
#define EDIT_GRAMMAR_H

#include <stddef.h>

#define GRAMMAR_MAX_RULES 256
#define GRAMMAR_MAX_STYLES 128
#define GRAMMAR_SCOPE_SIZE 32
#define GRAMMAR_SGR_SIZE 32
#define GRAMMAR_REGEX_SIZE 256
#define GRAMMAR_MAX_SPANS 256

typedef struct {
  char scope[GRAMMAR_SCOPE_SIZE];
  char regex[GRAMMAR_REGEX_SIZE];
  int word;
} grammar_rule;

typedef struct {
  char scope[GRAMMAR_SCOPE_SIZE];
  char sgr[GRAMMAR_SGR_SIZE];
} grammar_style;

typedef struct {
  grammar_rule rules[GRAMMAR_MAX_RULES];
  grammar_style styles[GRAMMAR_MAX_STYLES];
  int n_rules;
  int n_styles;
  int is_default;
  char triple_quote;
  char markdown_fence;
} grammar;

typedef struct {
  size_t start;
  size_t end;
  const char * sgr;
} grammar_span;

void grammar_load_default(grammar * g);
int grammar_load(grammar * g, const char * path);
int grammar_highlight(grammar * g, const char * path, const char * line,
                      size_t len, grammar_span * spans, int max_spans);
int grammar_match(grammar * g, const char * line, size_t len,
                  int * start, int * end, const char ** sgr);

#endif
