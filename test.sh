#!/bin/sh
set -eu

sh ./build.sh
Edit.app/Contents/MacOS/Edit --ansi-self-test

tmp=$(mktemp)
base=${tmp##*/}
out=$(mktemp)
recent=$(mktemp)
dir=$(mktemp -d)
export EDIT_RECENT="$recent"
clip_has=0
clip_saved=
if command -v pbcopy >/dev/null 2>&1 && command -v pbpaste >/dev/null 2>&1; then
  clip_saved=$(pbpaste 2>/dev/null || true)
  if printf __edit_clip_probe | pbcopy 2>/dev/null &&
     [ "$(pbpaste 2>/dev/null || true)" = "__edit_clip_probe" ]; then
    clip_has=1
  else
    printf '%s' "$clip_saved" | pbcopy 2>/dev/null || true
  fi
fi
cleanup() {
  if [ "$clip_has" = 1 ]; then printf '%s' "$clip_saved" | pbcopy; fi
  rm -rf "$dir"
  rm -f "$tmp" "$out" "$recent" "$tmp.grammar" "$tmp.expected" "$tmp.head" "$tmp.debug" "$tmp.debug2" "$tmp.debug3"
}
trap cleanup EXIT

foot() {
  width=$1
  msg=$2
  hint='C-h help'
  limit=$((width - 1))
  left=$((limit - ${#hint}))
  if [ "$left" -le 0 ]; then
    printf '%.*s' "$limit" "$hint"
    return
  fi
  printf '%.*s' "$left" "$msg"
  used=${#msg}
  [ "$used" -gt "$left" ] && used=$left
  while [ "$used" -lt "$left" ]; do
    printf ' '
    used=$((used + 1))
  done
  printf '%s' "$hint"
}

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

printf '* item\naXXb\na.*b\n' > "$tmp"
./edit --search 1:1 '*' "$tmp" > "$out"
printf '1:1..1:2\n' | cmp -s - "$out"

./edit --search 1:1 '[*]' "$tmp" > "$out"
printf '1:1..1:2\n' | cmp -s - "$out"

./edit --search 1:2 '[*]' "$tmp" > "$out"
printf '3:3..3:4\n' | cmp -s - "$out"

./edit --search 1:1 'a.*b' "$tmp" > "$out"
printf '2:1..2:5\n' | cmp -s - "$out"

printf 'abc\n' > "$tmp"
if ./edit --search 1:1 '*' "$tmp" > "$out" 2>&1; then exit 1; fi

printf 'one\ntwo\nthree\n' > "$tmp"
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
printf '%s[38;2;150;190;255mint%s[0m %s[38;2;255;215;95mtint%s[0m %s[38;2;224;224;224m=%s[0m %s[38;2;120;220;255m42%s[0m%s[38;2;224;224;224m;%s[0m %s[38;2;255;166;102m// return 7%s[0m\n%s[38;2;150;190;255mchar%s[0m %s[38;2;224;224;224m*%s[0m%s[38;2;255;215;95ms%s[0m %s[38;2;224;224;224m=%s[0m %s[38;2;170;255;170m"hi"%s[0m%s[38;2;224;224;224m;%s[0m\n\n' \
  "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" \
  "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" \
  "$esc" "$esc" "$esc" "$esc" |
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

printf '#include <stdio.h>\n#define LIMIT 16\n' > "$tmp"
./edit --render-color 4:80 "$tmp" > "$out"
grep -F -q "$(printf '%s[38;2;255;215;95m#include%s[0m%s[38;2;116;150;200m <stdio.h>%s[0m' "$esc" "$esc" "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;255;215;95m#define%s[0m%s[38;2;116;150;200m LIMIT 16%s[0m' "$esc" "$esc" "$esc" "$esc")" "$out"

printf 'printf "$(date +%%S)"\n' > "$tmp"
./edit --render-color 3:80 "$tmp" > "$out"
grep -F -q "$(printf '%s[38;2;120;220;255mdate%s[0m' "$esc" "$esc")" "$out"

printf 'x = """\nline\n"""\n' > "$tmp"
./edit --render-color 5:80 "$tmp" > "$out"
grep -F -q "$(printf '%s[38;2;170;255;170mline%s[0m' "$esc" "$esc")" "$out"

printf 'print(f"{value + 1}")\n' > "$tmp"
./edit --render-color 3:80 "$tmp" > "$out"
grep -F -q "$(printf '%s[38;2;255;150;170mf%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;120;220;255m1%s[0m' "$esc" "$esc")" "$out"

printf 'x = r"raw"\n' > "$tmp"
./edit --render-color 3:80 "$tmp" > "$out"
grep -F -q "$(printf '%s[38;2;255;150;170mr%s[0m' "$esc" "$esc")" "$out"

printf 'def foo():\n    return list()\n' > "$tmp"
./edit --render-color 4:80 "$tmp" > "$out"
grep -F -q "$(printf '%s[38;2;120;255;255mdef%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;80;190;255mfoo%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;232;232;232mlist%s[0m' "$esc" "$esc")" "$out"
if grep -F -q "$(printf '%s[38;2;80;190;255mlist%s[0m' "$esc" "$esc")" "$out"; then exit 1; fi

printf 'value: list = []\n' > "$tmp"
./edit --render-color 3:80 "$tmp" > "$out"
grep -F -q "$(printf '%s[38;2;150;190;255mlist%s[0m' "$esc" "$esc")" "$out"

printf 'class Foo:\n    pass\nvalue = Path("x")\n' > "$tmp"
./edit --render-color 3:80 "$tmp" > "$out"
grep -F -q "$(printf '%s[38;2;210;255;90mFoo%s[0m' "$esc" "$esc")" "$out"
if grep -F -q "$(printf '%s[38;2;210;255;90mPath%s[0m' "$esc" "$esc")" "$out"; then exit 1; fi

printf 'answer: int = 42\nif answer == 42:\n    obj.answer = 1\ndef f(limit: int = 0): pass\n' > "$tmp"
./edit --render-color 6:80 "$tmp" > "$out"
grep -F -q "$(printf '%s[38;2;255;215;95manswer%s[0m' "$esc" "$esc")" "$out"
if grep -F -q "$(printf 'obj.%s[38;2;255;215;95manswer%s[0m' "$esc" "$esc")" "$out"; then exit 1; fi
if grep -F -q "$(printf '%s[38;2;255;215;95mint%s[0m' "$esc" "$esc")" "$out"; then exit 1; fi
if grep -F -q "$(printf '%s[38;2;255;215;95mlimit%s[0m' "$esc" "$esc")" "$out"; then exit 1; fi

f90="$dir/sample.f90"
printf 'MODULE demo\nUSE iso_fortran_env, ONLY: INT32\nIMPLICIT NONE\nINTEGER(KIND=INT32) :: value = SELECTED_INT_KIND(19)\nINTEGER(KIND=INT32) :: DO      ! dimension output\nTYPE, BIND(C) :: PROFILE_ENTRY\nREAL(KIND=REAL64) :: WALL_TIME\nEND TYPE PROFILE_ENTRY\nTYPE(PROFILE_ENTRY) :: PROFILE\nFUNCTION f(x) RESULT(y)\nREAL :: y\nIF (0.0_REAL32 .LT. 1.0_REAL32) y = x\nMASK = .FALSE.\nCALL g(MODEL(CONFIG%ASEV:CONFIG%AEEV), RANDOM_LENGTHS=.TRUE._C_BOOL)\nDO i = 1, 3\nEND DO\nEND FUNCTION f\n! this is and for prose\n' > "$f90"
./edit --render-color 20:100 "$f90" > "$out"
grep -F -q "$(printf '%s[38;2;120;255;255mMODULE%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;120;255;255mUSE%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;120;255;255mIMPLICIT%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;150;190;255mINTEGER%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;120;255;255mFUNCTION%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;120;255;255mEND%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;232;232;232mSELECTED_INT_KIND%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;120;220;255m0.0_REAL32%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;120;255;255m.LT.%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;120;220;255m.FALSE.%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;120;220;255m.TRUE._C_BOOL%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;255;166;102m! this is and for prose%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;224;224;224m::%s[0m %s[38;2;120;255;175mDO%s[0m      %s[38;2;255;166;102m! dimension output%s[0m' "$esc" "$esc" "$esc" "$esc" "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;210;255;90mPROFILE_ENTRY%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;120;255;175mWALL_TIME%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;120;255;175mPROFILE%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;120;255;255mDO%s[0m i %s[38;2;224;224;224m=%s[0m' "$esc" "$esc" "$esc" "$esc")" "$out"
if grep -F -q "$(printf '%s[38;2;120;255;255mis%s[0m' "$esc" "$esc")" "$out"; then exit 1; fi
if grep -F -q "$(printf '%s[38;2;120;255;255mand%s[0m' "$esc" "$esc")" "$out"; then exit 1; fi
if grep -F -q "$(printf '%s[38;2;120;255;255mfor%s[0m' "$esc" "$esc")" "$out"; then exit 1; fi
if grep -F -q "$(printf ':: %s[38;2;120;255;255mDO%s[0m' "$esc" "$esc")" "$out"; then exit 1; fi
if grep -F -q "$(printf 'CONFIG%%ASEV:%s[38;2;120;220;255mCONFIG%%AEEV%s[0m' "$esc" "$esc")" "$out"; then exit 1; fi

md="$dir/sample.md"
printf '# Title\n- item\n> quote\nSee [guide](https://example.com) and `code`.\n```\nreturn 0;\n```\nTODO: write docs\n' > "$md"
./edit --render-color 10:80 "$md" > "$out"
grep -F -q "$(printf '%s[38;2;80;190;255m# Title%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;224;224;224m-%s[0m item' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;255;166;102m>%s[0m quote' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;80;190;255mhttps://example.com%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;170;255;170m`code`%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;170;255;170mreturn 0;%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;255;150;170mTODO%s[0m' "$esc" "$esc")" "$out"

printf '*word*\n**word**\n***word***\n*TODO*\n*open\n' > "$md"
./edit --render-color 7:80 "$md" > "$out"
grep -F -q "$(printf '%s[38;2;255;140;255m*%s[0m%s[3mword%s[0m%s[38;2;255;140;255m*' "$esc" "$esc" "$esc" "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;255;140;255m**%s[0m%s[1mword%s[0m%s[38;2;255;140;255m**' "$esc" "$esc" "$esc" "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;255;140;255m***%s[0m%s[1;3mword%s[0m%s[38;2;255;140;255m***' "$esc" "$esc" "$esc" "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[3;38;2;255;150;170mTODO%s[0m' "$esc" "$esc")" "$out"
if grep -F -q "$(printf '%s[3mopen' "$esc")" "$out"; then exit 1; fi

txt="$dir/sample.txt"
printf 'for class return\n- item\n> quote\nTODO: see https://example.com\n' > "$txt"
./edit --render-color 6:80 "$txt" > "$out"
grep -F -q "$(printf '%s[38;2;224;224;224m-%s[0m item' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;255;166;102m>%s[0m quote' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;255;150;170mTODO%s[0m' "$esc" "$esc")" "$out"
grep -F -q "$(printf '%s[38;2;80;190;255mhttps://example.com%s[0m' "$esc" "$esc")" "$out"
if grep -F -q "$(printf '%s[38;2;120;255;255mfor%s[0m' "$esc" "$esc")" "$out"; then exit 1; fi
if grep -F -q "$(printf '%s[38;2;120;255;255mreturn%s[0m' "$esc" "$esc")" "$out"; then exit 1; fi
if grep -F -q "$(printf '%s[38;2;210;255;90mclass%s[0m' "$esc" "$esc")" "$out"; then exit 1; fi

printf 'abc\n  def\n\tghi\n' > "$tmp"
./edit --render 5:12 "$tmp" > "$out"
printf '|abc\n..def\n>..ghi\n%s 1:1\n%s\n' "$base" "$(foot 12 "")" | cmp -s - "$out"

./edit --render-at 5:12 2:2 "$tmp" > "$out"
printf 'abc\n.|.def\n>..ghi\n%s 2:2\n%s\n' "$base" "$(foot 12 "")" | cmp -s - "$out"

./edit --render-keys 5:12 nf "$tmp" > "$out"
printf 'abc\n.|.def\n>..ghi\n%s 2:2\n%s\n' "$base" "$(foot 12 "")" | cmp -s - "$out"

./edit --render-at 5:12 3:2 "$tmp" > "$out"
printf 'abc\n..def\n>..|ghi\n%s 3:2\n%s\n' "$base" "$(foot 12 "")" | cmp -s - "$out"

EDIT_TAB_WIDTH=4 ./edit --render 5:12 "$tmp" > "$out"
printf '|abc\n..def\n>...ghi\n%s 1:1\n%s\n' "$base" "$(foot 12 "")" | cmp -s - "$out"

printf 'abc\n' > "$tmp"
./edit --render-keys 4:20 "$(printf '\t')" "$tmp" > "$out"
printf '...|abc\n\n%s* 1:4\n%s\n' "$base" "$(foot 20 "")" | cmp -s - "$out"

EDIT_TAB_WIDTH=2 ./edit --render-keys 4:20 "$(printf '\t')" "$tmp" > "$out"
printf '..|abc\n\n%s* 1:3\n%s\n' "$base" "$(foot 20 "")" | cmp -s - "$out"

js="$dir/sample.js"
css="$dir/sample.css"
printf 'abc\n' > "$js"
printf 'abc\n' > "$css"
EDIT_TAB_WIDTH=5 ./edit --render-keys 4:20 "$(printf '\t')" "$js" > "$out"
printf '..|abc\n\nsample.js* 1:3\n%s\n' "$(foot 20 "")" | cmp -s - "$out"

EDIT_TAB_WIDTH=5 ./edit --render-keys 4:20 "$(printf '\t')" "$css" > "$out"
printf '..|abc\n\nsample.css* 1:3\n%s\n' "$(foot 20 "")" | cmp -s - "$out"

./edit --render-keys 4:20 "$(printf '\t')_" "$tmp" > "$out"
printf '|abc\n\n%s 1:1\n%s\n' "$base" "$(foot 20 "undo")" | cmp -s - "$out"

./edit --render-keys 4:20 "q$(printf '\t')" "$tmp" > "$out"
printf '>..|abc\n\n%s* 1:2\n%s\n' "$base" "$(foot 20 "C-q")" | cmp -s - "$out"

./edit --render-keys 4:20 "q$(printf '\t')_" "$tmp" > "$out"
printf '|abc\n\n%s 1:1\n%s\n' "$base" "$(foot 20 "undo")" | cmp -s - "$out"

printf 'abcdef\nabc\n' > "$tmp"
./edit --render-keys 5:12 fffn "$tmp" > "$out"
printf 'abcdef\nabc|\n\n%s 2:4\n%s\n' "$base" "$(foot 12 "")" | cmp -s - "$out"

printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n' > "$tmp"
./edit --render-keys 5:12 v "$tmp" > "$out"
printf 'l3\n|l4\nl5\n%s 4:1\n%s\n' "$base" "$(foot 12 "")" | cmp -s - "$out"

./edit --render-keys 5:12 vV "$tmp" > "$out"
printf '|l1\nl2\nl3\n%s 1:1\n%s\n' "$base" "$(foot 12 "")" | cmp -s - "$out"

./edit --render-keys 5:20 nnnnnl "$tmp" > "$out"
printf 'l5\n|l6\nl7\n%s 6:1\n%s\n' "$base" "$(foot 20 "")" | cmp -s - "$out"

./edit --render-keys 5:20 nnnnnll "$tmp" > "$out"
printf '|l6\nl7\nl8\n%s 6:1\n%s\n' "$base" "$(foot 20 "")" | cmp -s - "$out"

./edit --render-keys 5:20 nnnnnlll "$tmp" > "$out"
printf 'l4\nl5\n|l6\n%s 6:1\n%s\n' "$base" "$(foot 20 "")" | cmp -s - "$out"

printf 'l01xx\nl02xx\nl03xx\nl04xx\nl05xx\nl06xx\nl07xx\nl08xx\nl09xx\nl10xx\nl11xx\nl12xx\n' > "$tmp"
./edit --render-keys 6:20 ffN "$tmp" > "$out"
printf 'l09xx\nl10xx\nl1|1xx\nl12xx\n%s 11:3\n%s\n' "$base" "$(foot 20 "")" | cmp -s - "$out"

./edit --render-keys 6:20 ffNP "$tmp" > "$out"
printf 'l0|1xx\nl02xx\nl03xx\nl04xx\n%s 1:3\n%s\n' "$base" "$(foot 20 "")" | cmp -s - "$out"

./edit --render-keys 6:20 ">>" "$tmp" > "$out"
printf 'l10xx\nl11xx\nl12xx\n|\n%s 13:1\n%s\n' "$base" "$(foot 20 "")" | cmp -s - "$out"

./edit --render-keys 6:20 ">>nf" "$tmp" > "$out"
printf 'l10xx\nl11xx\nl12xx\n|\n%s 13:1\n%s\n' "$base" "$(foot 20 "")" | cmp -s - "$out"

printf 'l01xx\nl02xx\nl03xx\nl04xx\nl05xx\nl06xx\nl07xx\nl08xx\nl09xx\nl10xx\nl11xx\nl12xx' > "$tmp"
./edit --render-keys 6:20 ">>nf" "$tmp" > "$out"
printf 'l09xx\nl10xx\nl11xx\nl12xx|\n%s 12:6\n%s\n' "$base" "$(foot 20 "")" | cmp -s - "$out"

printf 'l01xx\nl02xx\nl03xx\nl04xx\nl05xx\nl06xx\nl07xx\nl08xx\nl09xx\nl10xx\nl11xx\nl12xx\n' > "$tmp"

./edit --render-keys 6:20 ">>><" "$tmp" > "$out"
printf '|l01xx\nl02xx\nl03xx\nl04xx\n%s 1:1\n%s\n' "$base" "$(foot 20 "")" | cmp -s - "$out"

python3 ./tui_view.py 6:30 '<opt-gt>' "$tmp" > "$out"
sed -n '5p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *13:1*) ;; *) exit 1;; esac

python3 ./tui_view.py 6:30 '<opt-gt><opt-lt>' "$tmp" > "$out"
sed -n '5p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *1:1*) ;; *) exit 1;; esac

python3 ./tui_view.py 6:30 '<right><right><m-g>g7
' "$tmp" > "$out"
sed -n '5p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *7:1*) ;; *) exit 1;; esac
case "$(tail -n 1 "$out")" in cursor:*:1) ;; *) exit 1;; esac

python3 ./tui_view.py 6:30 '<m-g>g99
' "$tmp" > "$out"
sed -n '5p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *13:1*) ;; *) exit 1;; esac

python3 ./tui_view.py 6:30 '<right><right><down><m-g>gabc
' "$tmp" > "$out"
sed -n '5p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *2:3*) ;; *) exit 1;; esac
grep -q 'bad.line' "$out"

printf 'one, two_three 9x\n' > "$tmp"
./edit --render-keys 4:30 F "$tmp" > "$out"
printf 'one|,.two_three.9x\n\n%s 1:4\n%s\n' "$base" "$(foot 30 "")" | cmp -s - "$out"

./edit --render-keys 4:30 FF "$tmp" > "$out"
printf 'one,.two|_three.9x\n\n%s 1:9\n%s\n' "$base" "$(foot 30 "")" | cmp -s - "$out"

./edit --render-keys 4:30 FFB "$tmp" > "$out"
printf 'one,.|two_three.9x\n\n%s 1:6\n%s\n' "$base" "$(foot 30 "")" | cmp -s - "$out"

./edit --render-keys 4:30 FffB "$tmp" > "$out"
printf '|one,.two_three.9x\n\n%s 1:1\n%s\n' "$base" "$(foot 30 "")" | cmp -s - "$out"

printf 'camelCaseWord other\n' > "$tmp"
./edit --render-keys 4:40 F "$tmp" > "$out"
printf 'camel|CaseWord.other\n\n%s 1:6\n%s\n' "$base" "$(foot 40 "")" | cmp -s - "$out"

./edit --render-keys 4:40 FF "$tmp" > "$out"
printf 'camelCase|Word.other\n\n%s 1:10\n%s\n' "$base" "$(foot 40 "")" | cmp -s - "$out"

./edit --render-keys 4:40 FFFB "$tmp" > "$out"
printf 'camelCase|Word.other\n\n%s 1:10\n%s\n' "$base" "$(foot 40 "")" | cmp -s - "$out"

printf 'snake_case other\n' > "$tmp"
./edit --render-keys 4:40 F "$tmp" > "$out"
printf 'snake|_case.other\n\n%s 1:6\n%s\n' "$base" "$(foot 40 "")" | cmp -s - "$out"

./edit --render-keys 4:40 FF "$tmp" > "$out"
printf 'snake_case|.other\n\n%s 1:11\n%s\n' "$base" "$(foot 40 "")" | cmp -s - "$out"

./edit --render-keys 4:40 FFB "$tmp" > "$out"
printf 'snake_|case.other\n\n%s 1:7\n%s\n' "$base" "$(foot 40 "")" | cmp -s - "$out"

./edit --render-keys 4:40 FFBB "$tmp" > "$out"
printf '|snake_case.other\n\n%s 1:1\n%s\n' "$base" "$(foot 40 "")" | cmp -s - "$out"

printf 'one, two_three 9x\n' > "$tmp"
./edit --render-keys 4:30 D "$tmp" > "$out"
printf '|,.two_three.9x\n\n%s* 1:1\n%s\n' "$base" "$(foot 30 "")" | cmp -s - "$out"

./edit --render-keys 4:30 FD "$tmp" > "$out"
printf 'one|_three.9x\n\n%s* 1:4\n%s\n' "$base" "$(foot 30 "")" | cmp -s - "$out"

./edit --render-keys 4:30 DDD "$tmp" > "$out"
printf '|.9x\n\n%s* 1:1\n%s\n' "$base" "$(foot 30 "")" | cmp -s - "$out"

./edit --render-keys 4:30 D_ "$tmp" > "$out"
printf 'one|,.two_three.9x\n\n%s 1:4\n%s\n' "$base" "$(foot 30 "undo")" | cmp -s - "$out"

printf 'camelCaseWord other\n' > "$tmp"
./edit --render-keys 4:40 DD "$tmp" > "$out"
printf '|Word.other\n\n%s* 1:1\n%s\n' "$base" "$(foot 40 "")" | cmp -s - "$out"

printf 'snake_case other\n' > "$tmp"
./edit --render-keys 4:40 DD "$tmp" > "$out"
printf '|.other\n\n%s* 1:1\n%s\n' "$base" "$(foot 40 "")" | cmp -s - "$out"

printf 'one, two_three 9x\n' > "$tmp"
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

python3 ./tui_view.py 4:40 '<m-f>ff' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:15\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 4:40 '<mac-f><mac-f><mac-b>' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:6\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 4:50 '<opt-d>' "$tmp" > "$out"
grep -q '^>01:,.two_three.9x$' "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:1\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 4:50 '<mac-d><mac-d>' "$tmp" > "$out"
grep -q '^>01:_three.9x$' "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:1\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 4:50 '<m-f><m-f><m-del>' "$tmp" > "$out"
grep -q '^>01:one,._three.9x$' "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:6\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 4:50 '<m-f><m-f><m-del><m-del>' "$tmp" > "$out"
grep -q '^>01:_three.9x$' "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:1\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 4:50 '<m-f><m-f><m-del><c-slash>' "$tmp" > "$out"
grep -q '^>01:one,.two_three.9x$' "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:9\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

printf 'camelCaseWord other\n' > "$tmp"
python3 ./tui_view.py 4:50 '<m-f><m-f><m-f><m-del>' "$tmp" > "$out"
grep -q '^>01:camelCase.other$' "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:10\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

printf 'snake_case other\n' > "$tmp"
python3 ./tui_view.py 4:40 '<m-f><m-f><m-b>' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:7\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 4:50 '<m-f><m-f><m-del>' "$tmp" > "$out"
grep -q '^>01:snake_.other$' "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:7\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

printf 'one, two_three 9x\n' > "$tmp"
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

EDIT_DEBUG_LOG="$tmp.debug3" python3 ./tui_view.py 4:60 '<m-r><esc>foo bar^a<m-f>X
' "$tmp" > "$out"
grep -q '^note=fooX bar' "$tmp.debug3"

printf 'l01xx\nl02xx\nl03xx\nl04xx\nl05xx\nl06xx\nl07xx\nl08xx\nl09xx\nl10xx\nl11xx\nl12xx\n' > "$tmp"
python3 ./tui_view.py 6:20 '<right><right><opt-n>' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:3:3\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 6:20 '<right><right><mac-n><mac-p>' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:3\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 6:20 '<right><right><opt-n><opt-p>' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:3\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

./edit --render-keys 6:20 nnn "$tmp" > "$out"
printf 'l02xx\nl03xx\n|l04xx\nl05xx\n%s 4:1\n%s\n' "$base" "$(foot 20 "")" | cmp -s - "$out"

./edit --render-keys 6:20 nnnnnp "$tmp" > "$out"
printf 'l03xx\nl04xx\n|l05xx\nl06xx\n%s 5:1\n%s\n' "$base" "$(foot 20 "")" | cmp -s - "$out"

printf 'one\ntwo\nthree\nfour\n' > "$tmp"
./edit --render-keys 6:20 x2 "$tmp" > "$out"
printf '|one\ntwo\n%s 1:1>\n|one\n%s 1:1\n%s\n' "$base" "$base" "$(foot 20 "split")" | cmp -s - "$out"

./edit --render-keys 6:20 x2nxof "$tmp" > "$out"
printf 'one\n|two\n%s 2:1\no|ne\n%s 1:2>\n%s\n' "$base" "$base" "$(foot 20 "other pane")" | cmp -s - "$out"

./edit --render-keys 6:20 x2Xxo "$tmp" > "$out"
printf 'X|one\ntwo\n%s* 1:2\nX|one\n%s* 1:2>\n%s\n' "$base" "$base" "$(foot 20 "other pane")" | cmp -s - "$out"

./edit --render-keys 6:20 x2X_xo "$tmp" > "$out"
printf '|one\ntwo\n%s 1:1\n|one\n%s 1:1>\n%s\n' "$base" "$base" "$(foot 20 "other pane")" | cmp -s - "$out"

./edit --render-keys 6:20 x2x0 "$tmp" > "$out"
printf '|one\ntwo\nthree\nfour\n%s 1:1\n%s\n' "$base" "$(foot 20 "close pane")" | cmp -s - "$out"

./edit --render-keys 6:20 x2x1 "$tmp" > "$out"
printf '|one\ntwo\nthree\nfour\n%s 1:1\n%s\n' "$base" "$(foot 20 "one pane")" | cmp -s - "$out"

./edit --render-keys 5:24 x3 "$tmp" > "$out"
head=$(printf '%s' "$base" | cut -c 1-11)
printf '|one       │|one       \ntwo        │two        \nthree      │three      \n%s│%s\n%s\n' "$head" "$head" "$(foot 24 "split")" | cmp -s - "$out"

./edit --render-keys 5:24 x3nxof "$tmp" > "$out"
printf 'one        │o|ne       \n|two       │two        \nthree      │three      \n%s│%s\n%s\n' "$head" "$head" "$(foot 24 "other pane")" | cmp -s - "$out"

cell15() {
  printf '%-15.15s' "$1"
}

pane=$(cell15 "$base 1:1")
pane_active=$(cell15 "$base 1:1>")
blank=$(cell15 "")
./edit --render-keys 8:32 x3x2 "$tmp" > "$out"
printf '%s│%s\n%s│%s\n%s│%s\n%s│%s\n%s│%s\n%s│%s\n%s│%s\n%s\n' \
  "$(cell15 "|one")" "$(cell15 "|one")" \
  "$(cell15 "two")" "$(cell15 "two")" \
  "$(cell15 "three")" "$(cell15 "three")" \
  "$pane_active" "$(cell15 "four")" \
  "$(cell15 "|one")" "$blank" \
  "$(cell15 "two")" "$blank" \
  "$pane" "$pane" \
  "$(foot 32 "split")" | cmp -s - "$out"

./edit --render-keys 8:32 x3xox2 "$tmp" > "$out"
printf '%s│%s\n%s│%s\n%s│%s\n%s│%s\n%s│%s\n%s│%s\n%s│%s\n%s\n' \
  "$(cell15 "|one")" "$(cell15 "|one")" \
  "$(cell15 "two")" "$(cell15 "two")" \
  "$(cell15 "three")" "$(cell15 "three")" \
  "$(cell15 "four")" "$pane_active" \
  "$blank" "$(cell15 "|one")" \
  "$blank" "$(cell15 "two")" \
  "$pane" "$pane" \
  "$(foot 32 "split")" | cmp -s - "$out"

./edit --render-keys 8:32 x3x2x0 "$tmp" > "$out"
printf '%s│%s\n%s│%s\n%s│%s\n%s│%s\n%s│%s\n%s│%s\n%s│%s\n%s\n' \
  "$(cell15 "|one")" "$(cell15 "|one")" \
  "$(cell15 "two")" "$(cell15 "two")" \
  "$(cell15 "three")" "$(cell15 "three")" \
  "$(cell15 "four")" "$(cell15 "four")" \
  "$blank" "$blank" \
  "$blank" "$blank" \
  "$pane_active" "$pane" \
  "$(foot 32 "close pane")" | cmp -s - "$out"

./edit --render-keys 8:32 x3x2x1 "$tmp" > "$out"
printf '|one\ntwo\nthree\nfour\n\n\n%s 1:1\n%s\n' "$base" "$(foot 32 "one pane")" | cmp -s - "$out"

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
del=$(printf '\177')
printf 'one\ntwo\nthree\n' > "$tmp"
./edit --render-keys 5:12 "stwo$enter" "$tmp" > "$out"
printf 'one\n|two\nthree\n%s 2:1\n%s\n' "$base" "$(foot 12 "match two")" | cmp -s - "$out"

printf 'one two one two\n' > "$tmp"
./edit --render-keys 4:40 "stwo${enter}ss" "$tmp" > "$out"
printf 'one.two.one.|two\n\n%s 1:13\n%s\n' "$base" "$(foot 40 "match two")" | cmp -s - "$out"

./edit --render-keys 4:40 "stwo${enter}ssr" "$tmp" > "$out"
printf 'one.|two.one.two\n\n%s 1:5\n%s\n' "$base" "$(foot 40 "match two")" | cmp -s - "$out"

./edit --render-keys 4:40 "stwosf" "$tmp" > "$out"
printf 'one.t|wo.one.two\n\n%s 1:6\n%s\n' "$base" "$(foot 40 "match two")" | cmp -s - "$out"

./edit --render-keys 4:40 "stwo${enter}sss" "$tmp" > "$out"
printf 'one.|two.one.two\n\n%s 1:5\n%s\n' "$base" "$(foot 40 "match two")" | cmp -s - "$out"

./edit --render-keys 4:40 "stwo${enter}rr" "$tmp" > "$out"
printf 'one.two.one.|two\n\n%s 1:13\n%s\n' "$base" "$(foot 40 "match two")" | cmp -s - "$out"

./edit --render-keys-color 4:40 "stwo${enter}" "$tmp" > "$out"
printf 'one two one two\n\n\n' | cmp -s - "$out"

./edit --render-keys-color 4:40 "stwo${enter}ss" "$tmp" > "$out"
printf 'one %s[48;5;238mtwo%s[0m one %s[48;5;241mtwo%s[0m\n\n\n' \
  "$esc" "$esc" "$esc" "$esc" | cmp -s - "$out"

./edit --render-keys-color 4:40 "stwo${enter}ssr" "$tmp" > "$out"
printf 'one %s[48;5;241mtwo%s[0m one %s[48;5;238mtwo%s[0m\n\n\n' \
  "$esc" "$esc" "$esc" "$esc" | cmp -s - "$out"

./edit --render-keys-color 4:40 "stwosf" "$tmp" > "$out"
printf 'one two one two\n\n\n' | cmp -s - "$out"

printf '42 42\n' > "$tmp"
./edit --render-keys-color 3:40 "s42${enter}" "$tmp" > "$out"
printf '%s[38;2;120;220;255m42%s[0m %s[38;2;120;220;255m42%s[0m\n\n' \
  "$esc" "$esc" "$esc" "$esc" | cmp -s - "$out"

printf 'one\ntwo\nthree\n' > "$tmp"
./edit --render-keys 6:20 "stwosn" "$tmp" > "$out"
printf 'one\ntwo\n|three\n\n%s 3:1\n%s\n' "$base" "$(foot 20 "match two")" | cmp -s - "$out"

printf 'one two one two\n' > "$tmp"
./edit --render-keys-color 4:40 "stwo${enter}g" "$tmp" > "$out"
printf 'one two one two\n\n\n' | cmp -s - "$out"

printf 'two two\n' > "$tmp"
./edit --render-keys-color 4:40 "%two${enter}TWO${enter}!" "$tmp" > "$out"
printf 'TWO TWO\n\n\n' | cmp -s - "$out"

printf 'ab\n' > "$tmp"
python3 ./tui_view.py 4:30 '<right>^o^x^s' "$tmp" > "$out"
printf 'a\nb\n' | cmp -s - "$tmp"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:2\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

printf 'one one one\n' > "$tmp"
python3 ./tui_view.py 4:40 '<esc>%one
ONE
 ^g^x^s' "$tmp" > "$out"
printf 'ONE one one\n' | cmp -s - "$tmp"

printf 'one one one\n' > "$tmp"
python3 ./tui_view.py 4:40 '<esc>%one
ONE
n ^g^x^s' "$tmp" > "$out"
printf 'one ONE one\n' | cmp -s - "$tmp"

printf 'one one one\n' > "$tmp"
python3 ./tui_view.py 4:40 '<esc>%one
ONE
!^x^s' "$tmp" > "$out"
printf 'ONE ONE ONE\n' | cmp -s - "$tmp"

printf 'one one\n' > "$tmp"
python3 ./tui_view.py 4:40 '<opt-%>one
ONE
!^x^s' "$tmp" > "$out"
printf 'ONE ONE\n' | cmp -s - "$tmp"

printf 'foo bar\n' > "$tmp"
python3 ./tui_view.py 4:50 '<opt-%>foo bar^a<m-f>X' "$tmp" > "$out"
grep -q 'replace:.fooX.bar' "$out"

printf 'foo bar\n' > "$tmp"
python3 ./tui_view.py 4:50 '<opt-%>foo
bar baz^a<m-f>X' "$tmp" > "$out"
grep -q 'with:.barX.baz' "$out"

printf '* one *\n' > "$tmp"
python3 ./tui_view.py 4:40 '<esc>%*
X
!^x^s' "$tmp" > "$out"
printf 'X one X\n' | cmp -s - "$tmp"

printf '* one * two *\n' > "$tmp"
python3 ./tui_view.py 4:40 '<esc>%[*]
-
!^x^s' "$tmp" > "$out"
printf -- '- one - two -\n' | cmp -s - "$tmp"

i=0
: > "$tmp"
while [ "$i" -lt 1130 ]; do
  printf '* item\n' >> "$tmp"
  i=$((i + 1))
done
python3 ./tui_view.py 5:40 '<esc>%*
-
!<c-slash>^x^s' "$tmp" > "$out"
test "$(grep -c '^\* item$' "$tmp")" = 1130
if grep -q '^- item$' "$tmp"; then exit 1; fi

printf 'one one\n' > "$tmp"
python3 ./tui_view.py 4:40 '<c-c>^r<esc>%' "$tmp" > "$out"
grep -q 'read.only' "$out"

printf 'one two one two\n' > "$tmp"
./edit --render-keys 4:40 "stwogA" "$tmp" > "$out"
printf 'A|one.two.one.two\n\n%s* 1:2\n%s\n' "$base" "$(foot 40 "cancel")" | cmp -s - "$out"

printf 'abc\n' > "$tmp"
./edit --render-keys 4:40 xgA "$tmp" > "$out"
printf 'A|abc\n\n%s* 1:2\n%s\n' "$base" "$(foot 40 "cancel")" | cmp -s - "$out"

python3 ./tui_view.py 4:40 '^g<wait-status>' "$tmp" > "$out"
grep -q 'C-s/C-r.search,.C-g.cancel,.EscC-h.help' "$out"
if grep -q 'cancel\.\{10,\}C-h.help' "$out"; then exit 1; fi

printf 'abc\n' > "$tmp"
./edit --render-keys 4:20 X "$tmp" > "$out"
printf 'X|abc\n\n%s* 1:2\n%s\n' "$base" "$(foot 20 "")" | cmp -s - "$out"

printf 'abc\n' > "$tmp"
./edit --render-keys 4:20 X_ "$tmp" > "$out"
printf '|abc\n\n%s 1:1\n%s\n' "$base" "$(foot 20 "undo")" | cmp -s - "$out"

./edit --render-keys 4:20 X/ "$tmp" > "$out"
printf '|abc\n\n%s 1:1\n%s\n' "$base" "$(foot 20 "undo")" | cmp -s - "$out"

printf 'abc\n' > "$tmp"
python3 ./tui_view.py 4:40 'X<c-slash>^x^s' "$tmp" > "$out"
printf 'abc\n' | cmp -s - "$tmp"

./edit --render-keys 4:20 Xxu "$tmp" > "$out"
printf '|abc\n\n%s 1:1\n%s\n' "$base" "$(foot 20 "undo")" | cmp -s - "$out"

printf 'abc\n' > "$tmp"
python3 ./tui_view.py 4:40 'X^_^xr^x^s' "$tmp" > "$out"
printf 'Xabc\n' | cmp -s - "$tmp"
grep -q 'cursor:1:2' "$out"

printf 'abc\n' > "$tmp"
python3 ./tui_view.py 4:40 'XY^_^_^xr^xr^x^s' "$tmp" > "$out"
printf 'XYabc\n' | cmp -s - "$tmp"
grep -q 'cursor:1:3' "$out"

printf 'abc\n' > "$tmp"
python3 ./tui_view.py 4:40 '^xr' "$tmp" > "$out"
grep -q 'no.redo' "$out"

printf 'abc\n' > "$tmp"
python3 ./tui_view.py 4:40 'X^_Y^xr' "$tmp" > "$out"
grep -q 'Yabc' "$out"
grep -q 'no.redo' "$out"

printf 'abc\n' > "$tmp"
python3 ./tui_view.py 4:40 'X^_<c-c>^r^xr' "$tmp" > "$out"
grep -q 'read.only' "$out"

./edit --render-keys 4:20 "f${del}" "$tmp" > "$out"
printf '|bc\n\n%s* 1:1\n%s\n' "$base" "$(foot 20 "")" | cmp -s - "$out"

printf 'abcdef\nzz\n' > "$tmp"
python3 ./tui_view.py 5:30 '<right><right><right>^k^x^s' "$tmp" > "$out"
printf 'abc\nzz\n' | cmp -s - "$tmp"

printf 'abcdef\nzz\n' > "$tmp"
python3 ./tui_view.py 5:30 '^e^k^x^s' "$tmp" > "$out"
printf 'abcdefzz\n' | cmp -s - "$tmp"

printf 'abcdef\nzz\n' > "$tmp"
python3 ./tui_view.py 5:30 '<right><right><right>^k^y^x^s' "$tmp" > "$out"
printf 'abcdef\nzz\n' | cmp -s - "$tmp"

printf 'abcdef\nzz\n' > "$tmp"
python3 ./tui_view.py 5:30 '<right><right><right>^k^y^_^x^s' "$tmp" > "$out"
printf 'abc\nzz\n' | cmp -s - "$tmp"

printf 'abc\ndef\nzzz\n' > "$tmp"
python3 ./tui_view.py 5:40 '<right><right><right>^k^k^y^x^s' "$tmp" > "$out"
printf 'abc\ndef\nzzz\n' | cmp -s - "$tmp"

printf 'abc\ndef\n' > "$tmp"
python3 ./tui_view.py 5:40 '^k^n^k^y<m-y>^x^s' "$tmp" > "$out"
printf '\nabc\n' | cmp -s - "$tmp"

printf 'one\ntwo\nthree\n' > "$tmp"
python3 ./tui_view.py 6:40 '^k^n^k^n^k^y<m-y><m-y>^x^s' "$tmp" > "$out"
printf '\n\none\n' | cmp -s - "$tmp"

printf 'abc\ndef\n' > "$tmp"
python3 ./tui_view.py 5:40 '<right><right><right>^k^y<right><m-y>' "$tmp" > "$out"
grep -q 'no.yank' "$out"

printf 'aaa\nbb\n' > "$tmp"
python3 ./tui_view.py 5:40 '^k^n<c-space><right><right>^w^y<m-y>^x^s' "$tmp" > "$out"
printf '\naaa\n' | cmp -s - "$tmp"

printf 'abc\n' > "$tmp"
python3 ./tui_view.py 4:40 '<c-space><right><right>^w^x^s' "$tmp" > "$out"
printf 'c\n' | cmp -s - "$tmp"

printf 'abc\n' > "$tmp"
python3 ./tui_view.py 4:40 '<c-space><right><right>^w^y^x^s' "$tmp" > "$out"
printf 'abc\n' | cmp -s - "$tmp"

printf 'abc\n' > "$tmp"
python3 ./tui_view.py 4:40 '<c-space><right><right>^w^_^x^s' "$tmp" > "$out"
printf 'abc\n' | cmp -s - "$tmp"

if [ "$clip_has" = 1 ]; then
  printf 'abc\n' > "$tmp"
  python3 ./tui_view.py 4:40 '^k^x^s' "$tmp" > "$out"
  [ "$(pbpaste)" = "abc" ]

  printf 'abc\n' > "$tmp"
  python3 ./tui_view.py 4:40 '<c-space><right><right><m-w>^x^c' "$tmp" > "$out"
  printf 'abc\n' | cmp -s - "$tmp"
  [ "$(pbpaste)" = "ab" ]

  printf 'word next\n' > "$tmp"
  python3 ./tui_view.py 4:40 '<c-space><m-f><opt-w>^g^x^c' "$tmp" > "$out"
  printf 'word next\n' | cmp -s - "$tmp"
  [ "$(pbpaste)" = "word" ]

  printf 'abc\n' > "$tmp"
  printf 'CLIP' | pbcopy
  python3 ./tui_view.py 4:40 '^y^x^s' "$tmp" > "$out"
  printf 'CLIPabc\n' | cmp -s - "$tmp"

  printf 'abc\n' > "$tmp"
  printf 'CLIP' | pbcopy
  python3 ./tui_view.py 4:40 '^y^_^x^s' "$tmp" > "$out"
  printf 'abc\n' | cmp -s - "$tmp"

  printf 'abc\nCLIP\n' > "$tmp"
  printf 'CLIP' | pbcopy
  python3 ./tui_view.py 4:40 '^s^y
' "$tmp" > "$out"
  tail -n 1 "$out" > "$tmp.head"
  printf 'cursor:2:1\n' > "$tmp.expected"
  cmp -s "$tmp.expected" "$tmp.head"
fi

printf 'abc\nPASTE\n' > "$tmp"
python3 ./tui_view.py 4:40 '^s<paste>PASTE</paste>
' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:2:1\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

printf 'fooX bar\n' > "$tmp"
python3 ./tui_view.py 4:50 '^sfoo bar^a<m-f>X
' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:1\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

printf 'foo\n' > "$tmp"
python3 ./tui_view.py 4:50 '^sfoo bar<m-del>
' "$tmp" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:1:1\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

printf 'abc\n' > "$tmp"
python3 ./tui_view.py 4:40 '<raw><c-space><right>' "$tmp" > "$out"
grep -F -q "$(printf '\033[0;38;2;224;224;224;48;2;32;32;32;7m')" "$out"
grep -F -q "$(printf 'a\033[0;38;2;224;224;224;48;2;32;32;32mbc')" "$out"

printf 'multiline_str: str = """"\n' > "$tmp"
python3 ./tui_view.py 4:100 '<raw><c-space><right>' "$tmp" > "$out"
grep -F -q "$(printf '\033[0;38;2;224;224;224;48;2;32;32;32;7mm\033[0;38;2;224;224;224;48;2;32;32;32;38;2;255;215;95multiline_str')" "$out"

printf 'abc\n' > "$tmp"
./edit --render-keys 60:80 h "$tmp" > "$out"
grep -q '\*help\*' "$out"
grep -q 'C-c.x' "$out"
grep -q 'C-x.C-f' "$out"
grep -q 'C-s' "$out"
grep -q 'Esc.v' "$out"
grep -q 'Esc.w' "$out"
grep -q 'Esc.y' "$out"
grep -q 'C-/' "$out"
grep -q 'C-x.r' "$out"
grep -q 'C-x.C-c' "$out"

./edit --render-keys 4:20 hX "$tmp" > "$out"
printf '|edit.help\n\n*help* RO 1:1\n%s\n' "$(foot 20 "read only")" | cmp -s - "$out"

./edit --render-keys 4:20 fhxk "$tmp" > "$out"
printf 'a|bc\n\n%s 1:2\n%s\n' "$base" "$(foot 20 "killed")" | cmp -s - "$out"

./edit --render-keys 4:20 d_ "$tmp" > "$out"
printf 'a|bc\n\n%s 1:2\n%s\n' "$base" "$(foot 20 "undo")" | cmp -s - "$out"

./edit --render-keys 4:20 A_c__ "$tmp" > "$out"
printf '|abc\n\n%s 1:1\n%s\n' "$base" "$(foot 20 "no undo")" | cmp -s - "$out"

./edit --render-keys 4:20 Ac__ "$tmp" > "$out"
printf '|abc\n\n%s 1:1\n%s\n' "$base" "$(foot 20 "undo")" | cmp -s - "$out"

printf 'abcdefghijklmnopqrstuvwxyz\n' > "$tmp"
./edit --render-keys 4:12 fffffffffffff "$tmp" > "$out"
printf 'defghijklm|n\n\n%s 1:14\n%s\n' "$base" "$(foot 12 "")" | cmp -s - "$out"

./edit --render-keys 4:12 fffffffffffffbbbbbbbbbbbbb "$tmp" > "$out"
printf '|abcdefghijk\n\n%s 1:1\n%s\n' "$base" "$(foot 12 "")" | cmp -s - "$out"

wrap="$dir/w"
printf 'abcdefghijklmnopqrstuvwxyz\n' > "$wrap"
python3 ./tui_view.py 5:12 '<c-c>^w' "$wrap" > "$out"
grep -q '02:lmnopqrstuv' "$out"
grep -q '04:w.1:1.Wrap' "$out"

python3 ./tui_view.py 5:12 '<c-c>^w<c-c>^w' "$wrap" > "$out"
grep -q '01:abcdefghijk' "$out"
if grep -q 'Wrap' "$out"; then exit 1; fi

rights='<right><right><right><right><right><right><right><right><right><right><right><right><right>'
python3 ./tui_view.py 5:12 "<c-c>^w$rights" "$wrap" > "$out"
grep -q 'cursor:2:3' "$out"
grep -q '04:w.1:14.Wrap' "$out"

printf '  alpha   beta gamma\ndelta epsilon zeta eta theta iota kappa lambda mu nu xi\n\nnext\n' > "$tmp"
./edit --render-keys 6:90 Q "$tmp" > "$out"
printf '..alpha.beta.gamma.delta.epsilon.zeta.eta.theta.iota.kappa.lambda.mu\n..nu.xi|\n\nnext\n%s* 2:8\n%s\n' \
  "$base" "$(foot 90 "fill paragraph")" | cmp -s - "$out"

md="$dir/plan.md"
printf '  alpha   beta gamma\ndelta epsilon zeta eta theta iota kappa lambda mu nu xi\n\nnext\n' > "$md"
./edit --render-keys 6:90 Q "$md" > "$out"
printf '..alpha.beta.gamma.delta.epsilon.zeta.eta.theta.iota.kappa.lambda.mu\n..nu.xi|\n\nnext\nplan.md* 2:8\n%s\n' \
  "$(foot 90 "fill paragraph")" | cmp -s - "$out"

printf '# Title\n\n## Summary\n  alpha   beta gamma\ndelta epsilon zeta eta theta iota kappa lambda mu nu xi\n\nnext\n' > "$md"
./edit --render-keys 8:90 nnnQ "$md" > "$out"
printf '#.Title\n\n##.Summary\n..alpha.beta.gamma.delta.epsilon.zeta.eta.theta.iota.kappa.lambda.mu\n..nu.xi|\n\nplan.md* 5:8\n%s\n' \
  "$(foot 90 "fill paragraph")" | cmp -s - "$out"

./edit --render-keys 6:90 Q_ "$tmp" > "$out"
printf '..alpha...beta.gamma\ndelta.epsilon.zeta.eta.theta.iota.kappa.lambda.mu.nu.xi|\n\nnext\n%s 2:56\n%s\n' \
  "$base" "$(foot 90 "undo")" | cmp -s - "$out"

python3 ./tui_view.py 6:80 '<c-c>^r<m-q>' "$tmp" > "$out"
grep -q 'read.only' "$out"

printf 'abc\n' > "$tmp"
python3 ./tui_view.py 4:40 '<c-c>^rX' "$tmp" > "$out"
grep -q '1:1.RO' "$out"
grep -q 'read.only' "$out"

python3 ./tui_view.py 4:40 '<c-c>^r<c-c>^rX' "$tmp" > "$out"
grep -q 'Xabc' "$out"

python3 ./tui_view.py 4:40 '<raw>' "$tmp" > "$out"
grep -F -q "$(printf '\033[?1007h')" "$out"
grep -F -q "$(printf '\033[?1000h')" "$out"
grep -F -q "$(printf '\033[?1006h')" "$out"
grep -F -q "$(printf '\033[38;2;224;224;224;48;2;32;32;32m')" "$out"
grep -F -q "$(printf '\033[2 q')" "$out"
grep -F -q "$(printf '\033[?12l')" "$out"

python3 ./tui_view.py 4:40 '<raw><c-x>^c' "$tmp" > "$out"
grep -F -q "$(printf '\033[?1006l')" "$out"
grep -F -q "$(printf '\033[?1000l')" "$out"
grep -F -q "$(printf '\033[?1007l')" "$out"

printf 'one\ntwo\nthree\n' > "$tmp"
python3 ./tui_view.py 4:40 '<wheel-down>' "$tmp" > "$out"
grep -q 'cursor:2:1' "$out"

python3 ./tui_view.py 4:40 '<down><wheel-up>' "$tmp" > "$out"
grep -q 'cursor:1:1' "$out"

python3 ./tui_view.py 4:40 '<wheel-x10-down>' "$tmp" > "$out"
grep -q 'cursor:2:1' "$out"

python3 ./tui_view.py 4:40 '<wheel-right>' "$tmp" > "$out"
grep -q 'cursor:1:2' "$out"

python3 ./tui_view.py 4:40 '<right><wheel-left>' "$tmp" > "$out"
grep -q 'cursor:1:1' "$out"

python3 ./tui_view.py 4:40 '<wheel-x10-right>' "$tmp" > "$out"
grep -q 'cursor:1:2' "$out"

python3 ./tui_view.py 4:40 '<right><wheel-shift-up>' "$tmp" > "$out"
grep -q 'cursor:1:1' "$out"

python3 ./tui_view.py 4:40 '<wheel-shift-down>' "$tmp" > "$out"
grep -q 'cursor:1:2' "$out"

python3 ./tui_view.py 4:40 '<wheel-x10-shift-down>' "$tmp" > "$out"
grep -q 'cursor:1:2' "$out"

printf 'abc\ndef\n' > "$tmp"
python3 ./tui_view.py 5:40 '<click:3:2>' "$tmp" > "$out"
grep -q 'cursor:2:3' "$out"

python3 ./tui_view.py 5:40 '<click-x10:2:1>' "$tmp" > "$out"
grep -q 'cursor:1:2' "$out"

printf 'int x\n' > "$tmp"
python3 ./tui_view.py 4:40 '<raw>' "$tmp" > "$out"
grep -F -q "$(printf '\033[0;38;2;224;224;224;48;2;32;32;32;38;2;150;190;255m')" "$out"

printf 'alpha\n' > "$tmp"
python3 ./tui_view.py 5:40 '<rewrite><right>' "$tmp" > "$out"
grep -q 'external.reload' "$out"

printf 'alpha\n' > "$tmp"
python3 ./tui_view.py 5:40 'X<rewrite><right>' "$tmp" > "$out"
grep -q 'Xalpha' "$out"
if grep -q 'external.reload' "$out"; then exit 1; fi

printf 'abc\n' > "$tmp"
python3 ./tui_view.py 5:50 'X^x^s' "$tmp" > "$out"
grep -q saved "$out"
printf 'Xabc\n' | cmp -s - "$tmp"

printf 'abc\n' > "$tmp"
python3 ./tui_view.py 5:50 '^x^c' "$tmp" > "$out"

python3 ./tui_view.py 5:50 'X^x^c' "$tmp" > "$out"
grep -q modified "$out"
grep -q again "$out"
printf 'abc\n' | cmp -s - "$tmp"

python3 ./tui_view.py 5:50 'X^_^x^c' "$tmp" > "$out"
if grep -q modified "$out"; then exit 1; fi

awk 'BEGIN { for (i = 1; i <= 400; i++) { printf "word%03d", i; if (i < 400) printf " " } }' > "$tmp.expected"
printf '' > "$tmp"
python3 ./tui_view.py 5:80 "<paste>$(cat "$tmp.expected")</paste>^x^s" "$tmp" > "$out"
cmp -s "$tmp.expected" "$tmp"

printf '' > "$tmp"
python3 ./tui_view.py 5:40 '<paste>a
b</paste>^x^s' "$tmp" > "$out"
printf 'a\nb' | cmp -s - "$tmp"

printf '' > "$tmp"
python3 ./tui_view.py 5:80 "<paste>$(cat "$tmp.expected")</paste>^_^x^s" "$tmp" > "$out"
printf '' | cmp -s - "$tmp"

printf 'caf\303\251 \342\230\203' > "$tmp.expected"
printf '' > "$tmp"
python3 ./tui_view.py 5:40 "<paste>$(cat "$tmp.expected")</paste>^x^s" "$tmp" > "$out"
cmp -s "$tmp.expected" "$tmp"

printf 'ab\342\200\234\342\200\235' > "$tmp"
python3 ./tui_view.py 5:40 '<opt-gt>' "$tmp" > "$out"
grep -q 'cursor:1:5' "$out"

printf 'ab\342\200\234\342\200\235X' > "$tmp.expected"
printf 'ab\342\200\234\342\200\235' > "$tmp"
python3 ./tui_view.py 5:40 '<opt-gt>X^x^s' "$tmp" > "$out"
cmp -s "$tmp.expected" "$tmp"

printf 'ab\342\200\234X\342\200\235' > "$tmp.expected"
printf 'ab\342\200\234\342\200\235' > "$tmp"
python3 ./tui_view.py 5:40 '<right><right><right>X^x^s' "$tmp" > "$out"
cmp -s "$tmp.expected" "$tmp"

printf 'ab\342\200\234X\342\200\235' > "$tmp.expected"
printf 'ab\342\200\234\342\200\235' > "$tmp"
python3 ./tui_view.py 5:40 '<opt-gt><left>X^x^s' "$tmp" > "$out"
cmp -s "$tmp.expected" "$tmp"

printf 'alpha\n' > "$dir/a"
printf 'beta\n' > "$dir/b"
printf 'gamma\n' > "$dir/gamma"
mkdir "$dir/sub"
printf 'child\n' > "$dir/sub/child"

python3 ./tui_view.py 5:200 '^x^f' "$dir/a" > "$out"
grep -Fq "find.file:.$dir/" "$out"
grep -q 'cursor:5:' "$out"

python3 ./tui_view.py 5:80 '^x^f^a^kfoo bar^a<m-f>' "$dir/a" > "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:5:15\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 5:80 '^x^f^a^kfoo bar<m-del>' "$dir/a" > "$out"
grep -q 'find.file:.foo' "$out"
tail -n 1 "$out" > "$tmp.head"
printf 'cursor:5:16\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

./edit --render-keys 5:30 xk "$dir/a" > "$out"
grep -q '\*scratch\*' "$out"

printf '%s\n' "$dir/b" > "$recent"
./edit --render-keys 5:50 "xf
" "$dir/a" > "$out"
sed -n '1p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *alpha*) ;; *) exit 1;; esac
grep -q 'open failed' "$out"

printf 'alpha\n' > "$dir/a"
./edit --render-keys 5:30 Xxk "$dir/a" > "$out"
printf 'Xalpha\n' | cmp -s - "$dir/a"

./edit --render-keys 5:160 xb "$dir/a" > "$out"
grep -q '\*buffers\*' "$out"
grep -Fq "$dir/a" "$out"

printf '%s\n' "$dir/b" > "$recent"
./edit --render-keys 5:160 "xf
xb
" "$dir/a" > "$out"
sed -n '1p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *alpha*) ;; *) exit 1;; esac

python3 ./tui_view.py 5:120 "^x^b^x^f$dir/gamma
" "$dir/a" > "$out"
sed -n '1p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *alpha*gamma*) ;; *) exit 1;; esac

printf 'gamut\n' > "$dir/gamut"
python3 ./tui_view.py 5:120 "^x^b^x^f$dir/ga<tab>" "$dir/a" > "$out"
grep -q 'gamma' "$out"
grep -q 'gamut' "$out"
rm -f "$dir/gamut"

printf '%s\n' "$dir/b" > "$recent"
python3 ./tui_view.py 5:80 '^x^f
<c-x>b' "$dir/a" > "$out"
sed -n '1p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *alpha*) ;; *) exit 1;; esac

python3 ./tui_view.py 5:100 "^x^fb
^x^fgamma
<c-x>b<c-x>3<c-x>o<c-x>b<c-x>b<c-x>o<c-x>b" "$dir/a" > "$out"
sed -n '1p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *beta*gamma*) ;; *) exit 1;; esac

printf 'alpha\n' > "$dir/a"
printf '%s\n' "$dir/b" > "$recent"
python3 ./tui_view.py 5:80 '<right>X^x^f
<c-x>b^_' "$dir/a" > "$out"
sed -n '1p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *alpha*) ;; *) exit 1;; esac
grep -q undo "$out"

test ! -e '*scratch*'
./edit --render-keys 5:40 "xkXxs" "$dir/a" > "$out"
grep -q 'scratch not saved' "$out"
test ! -e '*scratch*'

printf 'alpha\n' > "$dir/a"
printf '%s\n' "$dir/b" > "$recent"
python3 ./tui_view.py 5:50 '^x^f
' "$dir/a" > "$out"
sed -n '1p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *alpha*) ;; *) exit 1;; esac
grep -q "^$dir/a$" "$recent"
grep -q "^$dir/b$" "$recent"

printf '' > "$recent"
python3 ./tui_view.py 5:50 "^x^fb
" "$dir/a" > "$out"
sed -n '1p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *beta*) ;; *) exit 1;; esac

python3 ./tui_view.py 5:50 "^x^fga<tab>
" "$dir/a" > "$out"
sed -n '1p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *gamma*) ;; *) exit 1;; esac

printf 'source\n' > "$dir/alpha.c"
printf 'header\n' > "$dir/beta.c"
python3 ./tui_view.py 5:80 "^x^f.*[.]c<tab>" "$dir/a" > "$out"
grep -q 'alpha.c' "$out"
grep -q 'beta.c' "$out"

python3 ./tui_view.py 5:50 "^x^fg.*a
" "$dir/a" > "$out"
sed -n '1p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *gamma*) ;; *) exit 1;; esac

printf 'gamut\n' > "$dir/gamut"
python3 ./tui_view.py 5:80 "^x^fg.*
" "$dir/a" > "$out"
sed -n '1p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *alpha*) ;; *) exit 1;; esac
grep -q 'gamma' "$out"
grep -q 'gamut' "$out"
rm -f "$dir/gamut"

special_dir="$dir/a[bc]*"
mkdir "$special_dir"
printf 'start\n' > "$special_dir/start"
printf 'matched\n' > "$special_dir/only.c"
python3 ./tui_view.py 5:100 "^x^f.*[.]c
" "$special_dir/start" > "$out"
sed -n '1p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *matched*) ;; *) exit 1;; esac

python3 ./tui_view.py 5:50 "^x^fsu<tab>child
" "$dir/a" > "$out"
sed -n '1p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *child*) ;; *) exit 1;; esac

python3 ./tui_view.py 5:70 "^x^f<tab>" "$dir/a" > "$out"
grep -q 'gamma' "$out"
grep -q 'sub/' "$out"

for n in 1 2 3 4; do printf 'long-open\n' > "$dir/long_completion_name_$n"; done
python3 ./tui_view.py 8:60 "^x^flong_completion<tab>" "$dir/a" > "$out"
grep -q '\*find.completions\*' "$out"
grep -q 'long_completion_name_' "$out"
python3 ./tui_view.py 8:60 "^x^flong_completion<tab>
" "$dir/a" > "$out"
grep -q 'long-open' "$out"
python3 ./tui_view.py 8:60 "^x^flong_completion<tab>^g^xb" "$dir/a" > "$out"
grep -q '\*find.completions\*' "$out"

printf '%s\n' "$dir/b" > "$recent"
printf 'alpha\n' > "$dir/a"
python3 ./tui_view.py 5:50 'X^x^f
' "$dir/a" > "$out"
sed -n '1p' "$out" > "$tmp.head"
case "$(cat "$tmp.head")" in *alpha*) ;; *) exit 1;; esac
printf 'alpha\n' | cmp -s - "$dir/a"

home="$dir/home"
mkdir "$home"
env -u EDIT_RECENT HOME="$home" python3 ./tui_view.py 5:50 '^x^f
' "$dir/a" > "$out"
test -s "$home/.edit/recent"
grep -q "^$dir/a$" "$home/.edit/recent"

run_home="$dir/run-home"
mkdir "$run_home"
mkdir "$run_home/.edit"
printf 'theme	dark\n' > "$run_home/.edit/config"
env SHELL=/bin/zsh HOME="$run_home" python3 ./tui_view.py 8:120 '^cxprintf command-output
' "$dir/a" > "$out"
grep -q 'command-output' "$out"
grep -q 'cursor:1:1' "$out"
grep -q "theme	dark" "$run_home/.edit/config"
grep -q "run	$dir/a	printf command-output" "$run_home/.edit/config"

run_prompt_home="$dir/run-prompt-home"
mkdir "$run_prompt_home"
env SHELL=/bin/zsh HOME="$run_prompt_home" python3 ./tui_view.py 8:120 '^cx^a^kecho two^a<m-f> one
' "$dir/a" > "$out"
grep -q 'one.two' "$out"

env SHELL=/bin/zsh HOME="$run_home" python3 ./tui_view.py 8:120 '^cx
' "$dir/a" > "$out"
grep -q 'cmd:.printf.command-output' "$out"

printf 'alpha\n' > "$dir/a"
dirty_home="$dir/dirty-home"
mkdir "$dirty_home"
env SHELL=/bin/zsh HOME="$dirty_home" python3 ./tui_view.py 8:120 'X^cxcat a
' "$dir/a" > "$out"
grep -q 'Xalpha' "$out"
printf 'Xalpha\n' | cmp -s - "$dir/a"

fail_home="$dir/fail-home"
mkdir "$fail_home"
env SHELL=/bin/zsh HOME="$fail_home" python3 ./tui_view.py 8:120 "^cxsh -c 'echo err >&2; exit 7'
" "$dir/a" > "$out"
grep -q 'err' "$out"
grep -q 'exit.7' "$out"

cap_home="$dir/cap-home"
mkdir "$cap_home"
env SHELL=/bin/zsh HOME="$cap_home" EDIT_RUN_OUTPUT_MAX=32 python3 ./tui_view.py 9:120 "^cxpython3 -c 'print(\"x\"*80)'
" "$dir/a" > "$out"
grep -q 'output.truncated' "$out"
grep -q 'exit.0' "$out"

cancel_run_home="$dir/cancel-run-home"
mkdir "$cancel_run_home"
env SHELL=/bin/zsh HOME="$cancel_run_home" python3 ./tui_view.py 9:120 "^cxpython3 -c 'import time; time.sleep(10)'
^g" "$dir/a" > "$out"
grep -q 'run.canceled' "$out"
grep -q 'exit.130' "$out"

cancel_home="$dir/cancel-home"
mkdir "$cancel_home"
env SHELL=/bin/zsh HOME="$cancel_home" python3 ./tui_view.py 5:80 '^cxprintf nope^g' "$dir/a" > "$out"
test ! -e "$cancel_home/.edit/config"

python3 ./tui_view.py 10:40 '<down><down><down><right><right>' test.sh > "$out"
printf ' 01:#!/bin/sh\n 02:set.-eu\n 03:\n>04:sh../build.sh\n 05:Edit.app/Contents/MacOS/Edit.--ansi-sel\n 06:\n 07:tmp=$(mktemp)\n' > "$tmp.expected"
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
printf 'cursor:6:15\n' > "$tmp.expected"
cmp -s "$tmp.expected" "$tmp.head"

python3 ./tui_view.py 12:28 '<right><right><right><right><right><right><right><right><right><right><right><right><right><right><down><down><down><down><down>' readme.md > "$out"
tail -n 1 "$out" > "$tmp.head"
cmp -s "$tmp.expected" "$tmp.head"

printf 'ok\n'
