#!/bin/sh
set -eu
cc -std=c11 -Wall -Wextra -pedantic -O2 -o edit edit.c grammar.c regex.c
