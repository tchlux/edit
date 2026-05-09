#!/bin/sh
set -eu

sh ./build.sh

tmp=$(mktemp)
base=${tmp##*/}
out=$(mktemp)
trap 'rm -f "$tmp" "$out" "$tmp.grammar" "$tmp.expected" "$tmp.head" "$tmp.debug" "$tmp.debug2" "$tmp.debug3"' EXIT

printf 'one\ntwo\nthree\n' > "$tmp"
./edit --print 2:1..3:1 "$tmp" > "$out"
printf 'two\n' | cmp -s - "$out"

./edit --search 1:1 one "$tmp" > "$out"
printf '1:1..1:4\n' | cmp -s - "$out"

./edit --search 1:1 wo "$tmp" > "$out"
printf '2:2..2:4\n' | cmp -s - "$out"

./edit --search 3:5 e "$tmp" > "$out"
printf '3:5..3:6\n' | cmp -s - "$out"

if ./edit --search 1:1 zzz "$tmp" > "$out" 2>&1; then exit 1; fi

./edit --insert 2:1 'X' "$tmp" > "$out"
printf 'one\nXtwo\nthree\n' | cmp -s - "$tmp"

./edit --delete 2:1..2:2 "$tmp" > "$out"
printf 'one\ntwo\nthree\n' | cmp -s - "$tmp"

printf 'middle' | ./edit --replace 2:1..2:4 - "$tmp" > "$out"
printf 'one\nmiddle\nthree\n' | cmp -s - "$tmp"

printf 'style comment 90\nrule comment //.*\n' > "$tmp.grammar"
EDIT_GRAMMAR="$tmp.grammar" ./edit --print 1:1..1:4 "$tmp" > "$out"
printf 'one' | cmp -s - "$out"

esc=$(printf '\033')
printf 'int tint = 42; // return 7\nchar *s = "hi";\n' > "$tmp"
./edit --render-color 4:80 "$tmp" > "$out"
printf '%s[35mint%s[0m tint = %s[36m42%s[0m; %s[90m// return 7%s[0m\n%s[35mchar%s[0m *s = %s[32m"hi"%s[0m;\n\n' \
  "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" |
  cmp -s - "$out"

printf 'style comment 31\nrule comment //.*\n' > "$tmp.grammar"
EDIT_GRAMMAR="$tmp.grammar" ./edit --render-color 3:80 "$tmp" > "$out"
printf 'int tint = 42; %s[31m// return 7%s[0m\nchar *s = "hi";\n' \
  "$esc" "$esc" | cmp -s - "$out"

printf 'style keyword 33\nword keyword int return\n' > "$tmp.grammar"
printf 'int tint return\n' > "$tmp"
EDIT_GRAMMAR="$tmp.grammar" ./edit --render-color 3:80 "$tmp" > "$out"
printf '%s[33mint%s[0m tint %s[33mreturn%s[0m\n\n' \
  "$esc" "$esc" "$esc" "$esc" | cmp -s - "$out"

printf 'abc\n  def\n\tghi\n' > "$tmp"
./edit --render 5:12 "$tmp" > "$out"
printf '|abc\n..def\n>ghi\n%s 1:1\nC-s search \n' "$base" | cmp -s - "$out"

./edit --render-at 5:12 2:2 "$tmp" > "$out"
printf 'abc\n.|.def\n>ghi\n%s 2:2\nC-s search \n' "$base" | cmp -s - "$out"

./edit --render-keys 5:12 nf "$tmp" > "$out"
printf 'abc\n.|.def\n>ghi\n%s 2:2\nC-s search \n' "$base" | cmp -s - "$out"

printf 'abcdef\nabc\n' > "$tmp"
./edit --render-keys 5:12 fffn "$tmp" > "$out"
printf 'abcdef\nabc|\n\n%s 2:4\nC-s search \n' "$base" | cmp -s - "$out"

printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n' > "$tmp"
./edit --render-keys 5:12 v "$tmp" > "$out"
printf 'l2\nl3\n|l4\n%s 4:1\nC-s search \n' "$base" | cmp -s - "$out"

./edit --render-keys 5:12 vV "$tmp" > "$out"
printf '|l1\nl2\nl3\n%s 1:1\nC-s search \n' "$base" | cmp -s - "$out"

./edit --render-keys 5:20 nnnnnl "$tmp" > "$out"
printf 'l5\n|l6\nl7\n%s 6:1\nC-s search  C-r rev\n' "$base" | cmp -s - "$out"

./edit --render-keys 5:20 nnnnnll "$tmp" > "$out"
printf '|l6\nl7\nl8\n%s 6:1\nC-s search  C-r rev\n' "$base" | cmp -s - "$out"

./edit --render-keys 5:20 nnnnnlll "$tmp" > "$out"
printf 'l4\nl5\n|l6\n%s 6:1\nC-s search  C-r rev\n' "$base" | cmp -s - "$out"

printf 'l01xx\nl02xx\nl03xx\nl04xx\nl05xx\nl06xx\nl07xx\nl08xx\nl09xx\nl10xx\nl11xx\nl12xx\n' > "$tmp"
./edit --render-keys 6:20 ffN "$tmp" > "$out"
printf 'l08xx\nl09xx\nl10xx\nl1|1xx\n%s 11:3\nC-s search  C-r rev\n' "$base" | cmp -s - "$out"

./edit --render-keys 6:20 ffNP "$tmp" > "$out"
printf 'l0|1xx\nl02xx\nl03xx\nl04xx\n%s 1:3\nC-s search  C-r rev\n' "$base" | cmp -s - "$out"

printf 'one, two_three 9x\n' > "$tmp"
./edit --render-keys 4:30 F "$tmp" > "$out"
printf 'one|,.two_three.9x\n\n%s 1:4\nC-s search  C-r reverse  C-g \n' "$base" | cmp -s - "$out"

./edit --render-keys 4:30 FF "$tmp" > "$out"
printf 'one,.two_three|.9x\n\n%s 1:15\nC-s search  C-r reverse  C-g \n' "$base" | cmp -s - "$out"

./edit --render-keys 4:30 FFB "$tmp" > "$out"
printf 'one,.|two_three.9x\n\n%s 1:6\nC-s search  C-r reverse  C-g \n' "$base" | cmp -s - "$out"

./edit --render-keys 4:30 FffB "$tmp" > "$out"
printf '|one,.two_three.9x\n\n%s 1:1\nC-s search  C-r reverse  C-g \n' "$base" | cmp -s - "$out"

python3 ./tui_view.py 4:40 '<opt-f>' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:4\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 4:40 '<opt-f><opt-f><opt-b>' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:6\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 4:40 '<esc>f' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:4\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 4:40 '<mac-f><mac-f><mac-b>' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:6\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

EDIT_DEBUG_LOG="$tmp.debug" python3 ./tui_view.py 4:40 '<m-r><opt-f><esc>meta failed
' "$tmp" > "$out"
test -s "$tmp.debug"
grep -q 'rows=4 cols=40' "$tmp.debug"
grep -q 'kind=mac-option key=M-f raw=c6 92' "$tmp.debug"
grep -q 'state after .*cursor=3.*line=1.*col=4' "$tmp.debug"
grep -q '^ansi_hex=' "$tmp.debug"
grep -q '^snapshot:' "$tmp.debug"
grep -q '^note=meta failed' "$tmp.debug"

EDIT_DEBUG_LOG="$tmp.debug2" python3 ./tui_view.py 4:40 '<m-r><m-f><esc>ok
' "$tmp" > "$out"
test -s "$tmp.debug2"
grep -q 'kind=esc-meta key=M-f raw=1b 66' "$tmp.debug2"
grep -q 'kind=plain-esc key=ESC raw=1b' "$tmp.debug2"
grep -q '^note=ok' "$tmp.debug2"

EDIT_DEBUG_LOG="$tmp.debug3" python3 ./tui_view.py 4:40 '<esc>r<opt-f><esc>delayed
' "$tmp" > "$out"
test -s "$tmp.debug3"
grep -q 'action=debug-start' "$tmp.debug3"
grep -q 'kind=mac-option key=M-f raw=c6 92' "$tmp.debug3"
grep -q 'state after .*cursor=3.*line=1.*col=4' "$tmp.debug3"
grep -q '^note=delayed' "$tmp.debug3"

EDIT_DEBUG_LOG="$tmp.debug3" python3 ./tui_view.py 4:40 '<mac-r><mac-f><esc>mac option
' "$tmp" > "$out"
test -s "$tmp.debug3"
grep -q 'kind=mac-option key=M-f raw=c6 92' "$tmp.debug3"
grep -q 'state after .*cursor=3.*line=1.*col=4' "$tmp.debug3"
grep -q '^note=mac option' "$tmp.debug3"

printf 'l01xx\nl02xx\nl03xx\nl04xx\nl05xx\nl06xx\nl07xx\nl08xx\nl09xx\nl10xx\nl11xx\nl12xx\n' > "$tmp"
python3 ./tui_view.py 6:20 '<right><right><opt-n>' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:4:3\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 6:20 '<right><right><mac-n><mac-p>' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:3\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 6:20 '<right><right><opt-n><opt-p>' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:3\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

printf 'one\ntwo\nthree\nfour\n' > "$tmp"
./edit --render-keys 6:20 x2 "$tmp" > "$out"
printf '|one\ntwo\n%s 1:1> split\n|one\n%s 1:1\nC-s search  C-r rev\n' "$base" "$base" | cmp -s - "$out"

./edit --render-keys 6:20 x2nxof "$tmp" > "$out"
printf 'one\n|two\n%s 2:1\no|ne\n%s 1:2> other pane\nC-s search  C-r rev\n' "$base" "$base" | cmp -s - "$out"

./edit --render-keys 6:20 x2Xxo "$tmp" > "$out"
printf 'X|one\ntwo\n%s* 1:2\nX|one\n%s* 1:2> other pane\nC-s search  C-r rev\n' "$base" "$base" | cmp -s - "$out"

./edit --render-keys 6:20 x2X_xo "$tmp" > "$out"
printf '|one\ntwo\n%s* 1:1\n|one\n%s* 1:1> other pane\nC-s search  C-r rev\n' "$base" "$base" | cmp -s - "$out"

./edit --render-keys 6:20 x2x0 "$tmp" > "$out"
printf '|one\ntwo\nthree\nfour\n%s 1:1 close pane\nC-s search  C-r rev\n' "$base" | cmp -s - "$out"

./edit --render-keys 6:20 x2x1 "$tmp" > "$out"
printf '|one\ntwo\nthree\nfour\n%s 1:1 one pane\nC-s search  C-r rev\n' "$base" | cmp -s - "$out"

./edit --render-keys 5:24 x3 "$tmp" > "$out"
head=$(printf '%s' "$base" | cut -c 1-11)
printf '|one       |one       \ntwo        two        \nthree      three      \n%s%s split\nC-s search  C-r reverse\n' "$head" "$head" | cmp -s - "$out"

./edit --render-keys 5:24 x3nxof "$tmp" > "$out"
printf 'one        o|ne       \n|two       two        \nthree      three      \n%s%s other pane\nC-s search  C-r reverse\n' "$head" "$head" | cmp -s - "$out"

python3 ./tui_view.py 6:30 '<c-x>2<c-x>o' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:4:1\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 5:30 '<c-x>3<c-x>o' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:16\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 5:20 '^v<m-v>' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:1\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

enter=$(printf '\r')
printf 'one\ntwo\nthree\n' > "$tmp"
./edit --render-keys 5:12 "stwo$enter" "$tmp" > "$out"
printf 'one\n|two\nthree\n%s 2:1 match two\nC-s search \n' "$base" | cmp -s - "$out"

printf 'one two one two\n' > "$tmp"
./edit --render-keys 4:40 "stwo${enter}ss" "$tmp" > "$out"
printf 'one.two.one.|two\n\n%s 1:13 match two\nC-s search  C-r reverse  C-g cancel  Es\n' "$base" | cmp -s - "$out"

./edit --render-keys 4:40 "stwo${enter}ssr" "$tmp" > "$out"
printf 'one.|two.one.two\n\n%s 1:5 match two\nC-s search  C-r reverse  C-g cancel  Es\n' "$base" | cmp -s - "$out"

./edit --render-keys 4:40 "stwogA" "$tmp" > "$out"
printf 'A|one.two.one.two\n\n%s* 1:2 cancel\nC-s search  C-r reverse  C-g cancel  Es\n' "$base" | cmp -s - "$out"

printf 'abc\n' > "$tmp"
./edit --render-keys 4:40 xgA "$tmp" > "$out"
printf 'A|abc\n\n%s* 1:2 cancel\nC-s search  C-r reverse  C-g cancel  Es\n' "$base" | cmp -s - "$out"

printf 'abc\n' > "$tmp"
./edit --render-keys 4:20 X "$tmp" > "$out"
printf 'X|abc\n\n%s* 1:2\nC-s search  C-r rev\n' "$base" | cmp -s - "$out"

printf 'abc\n' > "$tmp"
./edit --render-keys 4:20 X_ "$tmp" > "$out"
printf '|abc\n\n%s* 1:1 undo\nC-s search  C-r rev\n' "$base" | cmp -s - "$out"

./edit --render-keys 4:20 X/ "$tmp" > "$out"
printf '|abc\n\n%s* 1:1 undo\nC-s search  C-r rev\n' "$base" | cmp -s - "$out"

./edit --render-keys 4:20 Xxu "$tmp" > "$out"
printf '|abc\n\n%s* 1:1 undo\nC-s search  C-r rev\n' "$base" | cmp -s - "$out"

./edit --render-keys 4:20 fh_ "$tmp" > "$out"
printf 'a|bc\n\n%s* 1:2 undo\nC-s search  C-r rev\n' "$base" | cmp -s - "$out"

./edit --render-keys 4:20 d_ "$tmp" > "$out"
printf 'a|bc\n\n%s* 1:2 undo\nC-s search  C-r rev\n' "$base" | cmp -s - "$out"

./edit --render-keys 4:20 A_c__ "$tmp" > "$out"
printf 'A|abc\n\n%s* 1:2 undo\nC-s search  C-r rev\n' "$base" | cmp -s - "$out"

./edit --render-keys 4:20 Ac__ "$tmp" > "$out"
printf '|abc\n\n%s* 1:1 undo\nC-s search  C-r rev\n' "$base" | cmp -s - "$out"

python3 ./tui_view.py 5:50 'X^x^s' "$tmp" > "$out"
sed -n '4p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *saved*) ;; *) exit 1;; esac
printf 'Xabc\n' | cmp -s - "$tmp"

printf 'abc\n' > "$tmp"
python3 ./tui_view.py 5:50 '^x^c' "$tmp" > "$out"

python3 ./tui_view.py 5:50 'X^x^c' "$tmp" > "$out"
sed -n '4p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *modified*again*) ;; *) exit 1;; esac
printf 'abc\n' | cmp -s - "$tmp"

python3 ./tui_view.py 5:50 'X^_^x^c' "$tmp" > "$out"
sed -n '4p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *modified*again*) ;; *) exit 1;; esac

python3 ./tui_view.py 10:40 '<down><down><down><right><right>' test.sh > "$out"
printf ' 01:#!/bin/sh\n 02:set.-eu\n 03:\n>04:sh../build.sh\n 05:\n 06:tmp=$(mktemp)\n 07:base=${tmp##*/}\n' > "$tmp.expected"
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
