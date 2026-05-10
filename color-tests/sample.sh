#!/bin/sh
set -eu

name=${1:-world}
count=3

log() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

for item in "$HOME" /tmp/*.log; do
  [ -e "$item" ] || continue
  case "$item" in
    *.log) log "found log: $item" ;;
    *) echo "skip $item" ;;
  esac
done

if grep -q "ready" "${CONFIG:-/etc/app.conf}"; then
  echo "hello, $name # not a comment"
else
  # Keep the fallback intentionally boring.
  printf 'missing config after %d tries\n' "$count"
fi
