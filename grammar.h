// ___________________________________________________________________
//                            grammar.h
//
// Tiny syntax grammar interface for edit. Grammar files are line based:
//
//   style scope sgr
//   rule  scope regex
//
// Example:
//   style comment 90
//   rule  comment //.*
// ___________________________________________________________________

#ifndef EDIT_GRAMMAR_H
#define EDIT_GRAMMAR_H

#include <stddef.h>

#define GRAMMAR_MAX_RULES 128
#define GRAMMAR_MAX_STYLES 128
#define GRAMMAR_SCOPE_SIZE 32
#define GRAMMAR_SGR_SIZE 32
#define GRAMMAR_REGEX_SIZE 256

typedef struct {
  char scope[GRAMMAR_SCOPE_SIZE];
  char regex[GRAMMAR_REGEX_SIZE];
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
} grammar;

int grammar_load(grammar * g, const char * path);
int grammar_match(grammar * g, const char * line, size_t len,
                  int * start, int * end, const char ** sgr);

#endif
