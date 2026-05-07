#!/bin/sh
set -eu

sh ./build.sh

tmp=$(mktemp)
out=$(mktemp)
trap 'rm -f "$tmp" "$out" "$tmp.grammar" "$tmp.expected" "$tmp.head"' EXIT

printf 'one\ntwo\nthree\n' > "$tmp"
./edit --print 2:1..3:1 "$tmp" > "$out"
printf 'two\n' | cmp -s - "$out"

./edit --insert 2:1 'X' "$tmp" > "$out"
printf 'one\nXtwo\nthree\n' | cmp -s - "$tmp"

./edit --delete 2:1..2:2 "$tmp" > "$out"
printf 'one\ntwo\nthree\n' | cmp -s - "$tmp"

printf 'middle' | ./edit --replace 2:1..2:4 - "$tmp" > "$out"
printf 'one\nmiddle\nthree\n' | cmp -s - "$tmp"

printf 'style comment 90\nrule comment //.*\n' > "$tmp.grammar"
EDIT_GRAMMAR="$tmp.grammar" ./edit --print 1:1..1:4 "$tmp" > "$out"
printf 'one' | cmp -s - "$out"

printf 'abc\n  def\n\tghi\n' > "$tmp"
./edit --render 5:12 "$tmp" > "$out"
printf '|abc\n..def\n>ghi\n\n=%s\n' "$tmp" | cmp -s - "$out"

./edit --render-at 5:12 2:2 "$tmp" > "$out"
printf 'abc\n.|.def\n>ghi\n\n=%s\n' "$tmp" | cmp -s - "$out"

./edit --render-keys 5:12 nf "$tmp" > "$out"
printf 'abc\n.|.def\n>ghi\n\n=%s\n' "$tmp" | cmp -s - "$out"

printf 'abcdef\nabc\n' > "$tmp"
./edit --render-keys 5:12 fffn "$tmp" > "$out"
printf 'abcdef\nabc|\n\n\n=%s\n' "$tmp" | cmp -s - "$out"

python3 ./tui_view.py 10:40 '<down><down><down><right><right>' test.sh > "$out"
printf ' 01:#!/bin/sh\n 02:set.-eu\n 03:\n>04:sh../build.sh\n 05:\n 06:tmp=$(mktemp)\n 07:out=$(mktemp)\n' > "$tmp.expected"
head -n 7 "$out" > "$tmp.head"
cmp -s "$tmp.expected" "$tmp.head"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:4:3\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 10:40 '<down-o><down-o><down-o><right-o><right-o>' test.sh > "$out"
tail -n 1 "$out" > "$tmp.head"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 10:40 '<down-csi><down-csi><down-csi><right-csi><right-csi>' test.sh > "$out"
tail -n 1 "$out" > "$tmp.head"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 10:40 '<down><down>' test.sh > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:3:1\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 12:40 '<right><right><right><right><right><right><right><right><right><right><right><right><right><right><down><down><down><down><down>' readme.md > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:6:14\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 12:28 '<right><right><right><right><right><right><right><right><right><right><right><right><right><right><down><down><down><down><down>' readme.md > "$out"
tail -n 1 "$out" > "$tmp.head"
cmp -s "$tmp.expected" "$tmp.head"

printf 'ok\n'
