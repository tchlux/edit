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
  g->is_default = 1;
  _style(g, "comment", "38;5;208");
  _style(g, "string", "32");
  _style(g, "stringtag", "38;5;203");
  _style(g, "number", "38;5;81");
  _style(g, "keyword", "38;5;159");
  _style(g, "type", "38;5;111");
  _style(g, "class", "38;5;118");
  _style(g, "function", "38;5;67");
  _style(g, "call", "38;5;250");
  _style(g, "builtin", "38;5;75");
  _style(g, "constant", "38;5;203");
  _style(g, "preproc", "38;5;178");
  _style(g, "decorator", "38;5;177");
  _style(g, "variable", "38;5;120");
  _style(g, "assign", "38;5;180");
  _style(g, "operator", "38;5;244");
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

static void _paint_over(const char ** sgrs, size_t len, size_t start, size_t end,
                        const char * sgr) {
  if (start > len) start = len;
  if (end > len) end = len;
  for (size_t i = start; i < end; i++) sgrs[i] = sgr;
}

static void _clear(const char ** sgrs, size_t len, size_t start, size_t end) {
  if (start > len) start = len;
  if (end > len) end = len;
  for (size_t i = start; i < end; i++) sgrs[i] = NULL;
}

static int _word_start(char c) {
  return isalpha((unsigned char) c) || c == '_';
}

static int _word_char(char c) {
  return isalnum((unsigned char) c) || c == '_';
}

static int _word_in(const char * words, const char * s, size_t n) {
  const char * p = words;
  while (*p != '\0') {
    while (*p == ' ') p++;
    const char * q = p;
    while (*q != '\0' && *q != ' ') q++;
    if ((size_t) (q - p) == n && memcmp(p, s, n) == 0) return 1;
    p = q;
  }
  return 0;
}

static size_t _quote_end(const char * line, size_t len, size_t i) {
  char quote = line[i++];
  while (i < len) {
    if (line[i] == '\\' && i + 1 < len) i += 2;
    else if (line[i++] == quote) break;
  }
  return i;
}

static size_t _string_prefix(const char * line, size_t i, int * fstring) {
  size_t s = i;
  *fstring = 0;
  while (s > 0 && i - s < 2 && strchr("fFrRbBuU", line[s-1]) != NULL) s--;
  if (s > 0 && _word_char(line[s-1])) s = i;
  for (size_t j = s; j < i; j++)
    if (line[j] == 'f' || line[j] == 'F') *fstring = 1;
  return s;
}

static int _triple_at(const char * line, size_t len, size_t i, char quote) {
  return i + 2 < len && line[i] == quote && line[i+1] == quote && line[i+2] == quote;
}

static size_t _triple_end(const char * line, size_t len, size_t i, char quote) {
  for (i += 3; i + 2 < len; i++)
    if (_triple_at(line, len, i, quote)) return i + 3;
  return len;
}

static size_t _triple_close(const char * line, size_t len, char quote) {
  for (size_t i = 0; i + 2 < len; i++)
    if (_triple_at(line, len, i, quote)) return i + 3;
  return len;
}

static size_t _number_end(const char * line, size_t len, size_t i) {
  if (i + 2 < len && line[i] == '0' && (line[i+1] == 'x' || line[i+1] == 'X')) {
    i += 2;
    while (i < len && isxdigit((unsigned char) line[i])) i++;
    return i;
  }
  while (i < len && isdigit((unsigned char) line[i])) i++;
  if (i + 1 < len && line[i] == '.' && isdigit((unsigned char) line[i+1]))
    while (++i < len && isdigit((unsigned char) line[i])) {}
  return i;
}

static int _call_ahead(const char * line, size_t len, size_t i) {
  while (i < len && isspace((unsigned char) line[i])) i++;
  return i < len && line[i] == '(';
}

static int _after_class(const char * line, size_t start) {
  size_t i = start;
  while (i > 0 && isspace((unsigned char) line[i-1])) i--;
  size_t end = i;
  while (i > 0 && _word_char(line[i-1])) i--;
  return end - i == 5 && memcmp(line + i, "class", 5) == 0;
}

static int _after_def(const char * line, size_t start) {
  size_t i = start;
  while (i > 0 && isspace((unsigned char) line[i-1])) i--;
  size_t end = i;
  while (i > 0 && _word_char(line[i-1])) i--;
  return end - i == 3 && memcmp(line + i, "def", 3) == 0;
}

static int _def_params(const char * line, size_t start) {
  int seen_def = 0;
  int depth = 0;
  for (size_t i = 0; i < start;) {
    if (_word_start(line[i])) {
      size_t j = i + 1;
      while (j < start && _word_char(line[j])) j++;
      if (j - i == 3 && memcmp(line + i, "def", 3) == 0) seen_def = 1;
      i = j;
    } else {
      if (seen_def && line[i] == '(') depth++;
      else if (seen_def && line[i] == ')' && depth > 0) depth--;
      i++;
    }
  }
  return seen_def && depth > 0;
}

static int _assignment_ahead(const char * line, size_t len,
                             size_t start, size_t end) {
  size_t prev = start;
  while (prev > 0 && isspace((unsigned char) line[prev-1])) prev--;
  if ((prev > 0 && (line[prev-1] == '.' || line[prev-1] == ':')) ||
      _def_params(line, start))
    return 0;
  while (end < len && isspace((unsigned char) line[end])) end++;
  if (end < len && line[end] == '=')
    return end + 1 >= len || line[end+1] != '=';
  if (end >= len || line[end] != ':') return 0;
  for (size_t i = end + 1; i < len && line[i] != ',' && line[i] != ')'; i++)
    if (line[i] == '=') return i + 1 >= len || line[i+1] != '=';
  return 0;
}

static int _preproc(const char * line, size_t len, size_t * start) {
  size_t i = 0;
  while (i < len && (line[i] == ' ' || line[i] == '\t')) i++;
  if (i >= len || line[i] != '#') return 0;
  size_t j = i + 1;
  while (j < len && isalpha((unsigned char) line[j])) j++;
  if (j == i + 1) return 0;
  *start = i;
  return _word_in("include define if ifdef ifndef elif else endif pragma undef error",
                  line + i + 1, j - i - 1);
}

static void _command_subs(grammar * g, const char * line, size_t len,
                          size_t start, size_t end, const char ** sgrs) {
  for (size_t i = start; i + 2 < end;) {
    if (line[i] != '$' || line[i+1] != '(') {
      i++;
      continue;
    }
    size_t j = i + 2;
    while (j < end && isspace((unsigned char) line[j])) j++;
    if (j < end && _word_start(line[j])) {
      size_t k = j + 1;
      while (k < end && _word_char(line[k])) k++;
      _paint_over(sgrs, len, j, k, _sgr(g, "builtin"));
    }
    i = j + 1;
  }
}

static void _code_expr(grammar * g, const char * line, size_t len,
                       size_t start, size_t end, const char ** sgrs) {
  const char * keywords =
    "if else for while return def class import from as in is and or not";
  const char * builtins = "len range enumerate zip map filter print isinstance super";
  const char * constants = "True False None";
  _clear(sgrs, len, start, end);
  for (size_t i = start; i < end;) {
    if (line[i] == '"' || line[i] == '\'') {
      size_t j = _quote_end(line, end, i);
      _paint(sgrs, len, i, j, _sgr(g, "string"));
      i = j;
    } else if (isdigit((unsigned char) line[i])) {
      size_t j = _number_end(line, end, i);
      _paint(sgrs, len, i, j, _sgr(g, "number"));
      i = j;
    } else if (_word_start(line[i])) {
      size_t j = i + 1;
      while (j < end && _word_char(line[j])) j++;
      const char * sgr = _word_in(keywords, line + i, j - i) ? _sgr(g, "keyword") :
        _word_in(builtins, line + i, j - i) ? _sgr(g, "builtin") :
        _word_in(constants, line + i, j - i) ? _sgr(g, "constant") :
        _after_class(line, i) ? _sgr(g, "class") : NULL;
      if (sgr != NULL) _paint(sgrs, len, i, j, sgr);
      i = j;
    } else {
      if (strchr("-+*/%=!<>|&^~:.,;(){}[]", line[i]) != NULL)
        _paint(sgrs, len, i, i + 1, _sgr(g, "operator"));
      i++;
    }
  }
}

static void _fstring_exprs(grammar * g, const char * line, size_t len,
                           size_t start, size_t end, const char ** sgrs) {
  for (size_t i = start; i < end; i++) {
    if (line[i] == '{' && i + 1 < end && line[i+1] == '{') {
      i++;
    } else if (line[i] == '{') {
      size_t j = i + 1;
      while (j < end && line[j] != '}') j++;
      if (j >= end) return;
      _paint_over(sgrs, len, i, i + 1, _sgr(g, "operator"));
      _code_expr(g, line, len, i + 1, j, sgrs);
      _paint_over(sgrs, len, j, j + 1, _sgr(g, "operator"));
      i = j;
    }
  }
}

static void _default_highlight(grammar * g, const char * line, size_t len,
                               const char ** sgrs) {
  const char * keywords =
    "if else for while do switch case default break continue return goto sizeof "
    "typedef struct union enum static extern const volatile inline def class "
    "import from as with try except finally raise lambda yield pass global "
    "nonlocal assert del in is and or not elif then fi esac function done";
  const char * types =
    "void char short int long float double signed unsigned size_t ssize_t bool "
    "FILE pid_t uint8_t uint16_t uint32_t uint64_t int8_t int16_t int32_t "
    "int64_t str bytes list dict tuple object self";
  const char * builtins =
    "echo printf read test cd pwd export unset local shift source grep sed awk "
    "find xargs mkdir rm cp mv cat sort uniq head tail wc date set open len range "
    "enumerate zip map filter print isinstance super";
  const char * constants = "NULL true false True False None stdin stdout stderr";
  size_t i0 = 0;
  size_t start = 0;

  if (g->triple_quote != '\0') {
    size_t j = _triple_close(line, len, g->triple_quote);
    _paint(sgrs, len, 0, j, _sgr(g, "string"));
    if (j >= len) return;
    i0 = j;
  }

  if (i0 == 0 && _preproc(line, len, &start)) {
    _paint(sgrs, len, start, len, _sgr(g, "preproc"));
    return;
  }

  for (size_t i = i0; i < len;) {
    if (line[i] == '/' && i + 1 < len && line[i+1] == '/') {
      _paint(sgrs, len, i, len, _sgr(g, "comment"));
      return;
    } else if (line[i] == '/' && i + 1 < len && line[i+1] == '*') {
      size_t j = i + 2;
      while (j + 1 < len && !(line[j] == '*' && line[j+1] == '/')) j++;
      if (j + 1 < len) {
        _paint(sgrs, len, i, j + 2, _sgr(g, "comment"));
        i = j + 2;
      } else {
        _paint(sgrs, len, i, i + 1, _sgr(g, "operator"));
        i++;
      }
    } else if (line[i] == '#') {
      _paint(sgrs, len, i, len, _sgr(g, "comment"));
      return;
    } else if ((line[i] == '"' || line[i] == '\'') && _triple_at(line, len, i, line[i])) {
      int fstring = 0;
      size_t s = _string_prefix(line, i, &fstring);
      size_t j = _triple_end(line, len, i, line[i]);
      _paint(sgrs, len, i, j, _sgr(g, "string"));
      if (s < i) _paint(sgrs, len, s, i, _sgr(g, "stringtag"));
      if (fstring) _fstring_exprs(g, line, len, i, j, sgrs);
      if (j >= len) return;
      i = j;
    } else if (line[i] == '"' || line[i] == '\'' || line[i] == '`') {
      int fstring = 0;
      size_t s = _string_prefix(line, i, &fstring);
      size_t j = _quote_end(line, len, i);
      _paint(sgrs, len, i, j, _sgr(g, "string"));
      if (s < i) _paint(sgrs, len, s, i, _sgr(g, "stringtag"));
      if (fstring) _fstring_exprs(g, line, len, i, j, sgrs);
      if (line[i] == '"') _command_subs(g, line, len, i, j, sgrs);
      i = j;
    } else if (line[i] == '@' && i + 1 < len && _word_start(line[i+1])) {
      size_t j = i + 2;
      while (j < len && _word_char(line[j])) j++;
      _paint(sgrs, len, i, j, _sgr(g, "decorator"));
      i = j;
    } else if (line[i] == '$') {
      size_t j = i + 1;
      if (j < len && line[j] == '{') {
        while (j < len && line[j++] != '}') {}
      } else if (j < len && (_word_char(line[j]) || strchr("#?*$!@", line[j]))) {
        if (_word_char(line[j])) {
          while (j < len && _word_char(line[j])) j++;
        } else {
          j++;
        }
      }
      _paint(sgrs, len, i, j, _sgr(g, "variable"));
      i = j;
    } else if (isdigit((unsigned char) line[i]) &&
               (i == 0 || !_word_char(line[i-1]))) {
      size_t j = _number_end(line, len, i);
      if (j == len || !_word_char(line[j])) _paint(sgrs, len, i, j, _sgr(g, "number"));
      i = j;
    } else if (_word_start(line[i])) {
      size_t j = i + 1;
      while (j < len && _word_char(line[j])) j++;
      const char * sgr = NULL;
      if (_word_in(keywords, line + i, j - i)) sgr = _sgr(g, "keyword");
      else if (_assignment_ahead(line, len, i, j)) sgr = _sgr(g, "assign");
      else if (_after_class(line, i)) sgr = _sgr(g, "class");
      else if (_after_def(line, i)) sgr = _sgr(g, "function");
      else if (_call_ahead(line, len, j)) sgr = _sgr(g, "call");
      else if (_word_in(types, line + i, j - i)) sgr = _sgr(g, "type");
      else if (_word_in(builtins, line + i, j - i)) sgr = _sgr(g, "builtin");
      else if (_word_in(constants, line + i, j - i)) sgr = _sgr(g, "constant");
      if (sgr != NULL) _paint(sgrs, len, i, j, sgr);
      i = j;
    } else {
      if (strchr("-+*/%=!<>|&^~:.,;(){}[]", line[i]) != NULL)
        _paint(sgrs, len, i, i + 1, _sgr(g, "operator"));
      i++;
    }
  }
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

  if (g->is_default) _default_highlight(g, line, len, sgrs);
  for (int i = 0; !g->is_default && i < g->n_rules; i++) {
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
