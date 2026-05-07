A minimal and highly customizable text editor written in C.

Build:

```
sh ./build.sh
```

Interactive use:

```
./edit file.txt
```

Batch use:

```
./edit --print 1:1..2:1 file.txt
./edit --insert 1:1 "text" file.txt
./edit --delete 1:1..1:5 file.txt
./edit --replace 1:1..1:5 "text" file.txt
./edit --render 10:80 file.txt
./edit --render-at 10:80 2:1 file.txt
./edit --render-keys 10:80 nf file.txt
```

TUI debug:

```
python3 ./tui_view.py 10:80 '<down><right>' file.txt
```
