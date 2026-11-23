#!/bin/sh
# Portable C-only grammar tests; does not build the macOS application.
set -eu
cd "$(dirname "$0")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
# POSIX enables getline on hosts whose C11 mode hides it by default.
${CC:-cc} ${CFLAGS:--std=c11 -Wall -Wextra -pedantic -O2} -D_POSIX_C_SOURCE=200809L \
  test_grammar_slices.c grammar.c regex.c -o "$tmp/test-grammar"
"$tmp/test-grammar"
