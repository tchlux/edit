#!/usr/bin/env python3
import fcntl
import os
import pty
import select
import struct
import sys
import termios
import time


def ctrl(c):
    return bytes([ord(c) & 0x1f])


def keys(s):
    out = b""
    i = 0
    while i < len(s):
        if s.startswith("<left>", i):
            out += b"\x1b[D"
            i += 6
        elif s.startswith("<right>", i):
            out += b"\x1b[C"
            i += 7
        elif s.startswith("<left-o>", i):
            out += b"\x1bOD"
            i += 8
        elif s.startswith("<right-o>", i):
            out += b"\x1bOC"
            i += 9
        elif s.startswith("<right-csi>", i):
            out += b"\x1b[1;2C"
            i += 11
        elif s.startswith("<up>", i):
            out += b"\x1b[A"
            i += 4
        elif s.startswith("<down>", i):
            out += b"\x1b[B"
            i += 6
        elif s.startswith("<up-o>", i):
            out += b"\x1bOA"
            i += 6
        elif s.startswith("<down-o>", i):
            out += b"\x1bOB"
            i += 8
        elif s.startswith("<down-csi>", i):
            out += b"\x1b[1;2B"
            i += 10
        elif s.startswith("<m-v>", i):
            out += b"\x1bv"
            i += 5
        elif s.startswith("<m-n>", i):
            out += b"\x1bn"
            i += 5
        elif s.startswith("<m-p>", i):
            out += b"\x1bp"
            i += 5
        elif s.startswith("<m-f>", i):
            out += b"\x1bf"
            i += 5
        elif s.startswith("<m-b>", i):
            out += b"\x1bb"
            i += 5
        elif s.startswith("<m-r>", i):
            out += b"\x1br"
            i += 5
        elif s.startswith("<tab>", i):
            out += b"\t"
            i += 5
        elif s.startswith("<esc>", i):
            out += b"\x1b\x00"
            i += 5
        elif s.startswith("<opt-n>", i):
            out += bytes([0xCB, 0x9C])
            i += 7
        elif s.startswith("<opt-p>", i):
            out += bytes([0xCF, 0x80])
            i += 7
        elif s.startswith("<opt-f>", i):
            out += bytes([0xC6, 0x92])
            i += 7
        elif s.startswith("<opt-b>", i):
            out += bytes([0xE2, 0x88, 0xAB])
            i += 7
        elif s.startswith("<opt-r>", i):
            out += bytes([0xC2, 0xAE])
            i += 7
        elif s.startswith("<opt-lt>", i):
            out += bytes([0xC2, 0xAF])
            i += 8
        elif s.startswith("<opt-gt>", i):
            out += bytes([0xCB, 0x98])
            i += 8
        elif s.startswith("<mac-n>", i):
            out += bytes([0xCB, 0x9C])
            i += 7
        elif s.startswith("<mac-p>", i):
            out += bytes([0xCF, 0x80])
            i += 7
        elif s.startswith("<mac-f>", i):
            out += bytes([0xC6, 0x92])
            i += 7
        elif s.startswith("<mac-b>", i):
            out += bytes([0xE2, 0x88, 0xAB])
            i += 7
        elif s.startswith("<mac-r>", i):
            out += bytes([0xC2, 0xAE])
            i += 7
        elif s.startswith("<mac-lt>", i):
            out += bytes([0xC2, 0xAF])
            i += 8
        elif s.startswith("<mac-gt>", i):
            out += bytes([0xCB, 0x98])
            i += 8
        elif s.startswith("<c-x>", i):
            out += ctrl("x")
            i += 5
        elif s[i] == "^" and i + 1 < len(s):
            out += ctrl(s[i + 1].lower())
            i += 2
        elif s[i] == "\n":
            out += b"\r"
            i += 1
        else:
            out += s[i].encode()
            i += 1
    return out


def read_tui(path, rows, cols, key_text):
    pid, fd = pty.fork()
    if pid == 0:
        os.execv("./edit", ["./edit", path])

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    out = b""
    end = time.time() + 3
    while time.time() < end and b"\x1b[?1049h" not in out:
        r, _, _ = select.select([fd], [], [], 0.05)
        if fd in r:
            try:
                out += os.read(fd, 4096)
            except OSError:
                break
    for c in keys(key_text):
        if c == 0:
            time.sleep(0.05)
        else:
            os.write(fd, bytes([c]))

    done = (0, 0)
    end = time.time() + 0.25
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if fd in r:
            try:
                out += os.read(fd, 4096)
            except OSError:
                break
        try:
            done = os.waitpid(pid, os.WNOHANG)
            if done[0]:
                break
        except ChildProcessError:
            break

    snapshot = out
    if not done[0]:
        os.write(fd, ctrl("g") + ctrl("x") + ctrl("c"))
        for _ in range(2):
            end = time.time() + 0.5
            while time.time() < end:
                r, _, _ = select.select([fd], [], [], 0.05)
                if fd in r:
                    try:
                        os.read(fd, 4096)
                    except OSError:
                        break
                try:
                    done = os.waitpid(pid, os.WNOHANG)
                    if done[0]:
                        break
                except ChildProcessError:
                    break
            if done[0]:
                break
            os.write(fd, ctrl("x") + ctrl("c"))
        if not done[0]:
            os.kill(pid, 9)
            os.waitpid(pid, 0)
            raise RuntimeError("editor did not exit")
    return snapshot


def decode(out, rows, cols):
    screen = [[" " for _ in range(cols)] for _ in range(rows)]
    row = 0
    col = 0
    wrap = False
    cursor = (0, 0)
    i = 0

    while i < len(out):
        c = out[i]
        if c == 27 and i + 1 < len(out) and out[i + 1] == 91:
            j = i + 2
            while j < len(out) and not (64 <= out[j] <= 126):
                j += 1
            seq = out[i + 2:j].decode(errors="ignore")
            final = chr(out[j]) if j < len(out) else ""
            i = j + 1
            if final == "H":
                parts = [int(x) if x else 1 for x in seq.split(";")]
                row = max(0, min(rows - 1, parts[0] - 1))
                col = max(0, min(cols - 1, (parts[1] if len(parts) > 1 else 1) - 1))
                cursor = (row, col)
                wrap = False
            elif final == "K":
                for x in range(col, cols):
                    screen[row][x] = " "
                wrap = False
            continue

        if c == 13:
            col = 0
            wrap = False
        elif c == 10:
            row = min(rows - 1, row + 1)
            wrap = False
        elif 32 <= c < 127:
            if wrap:
                row = min(rows - 1, row + 1)
                col = 0
                wrap = False
            if row < rows and col < cols:
                screen[row][col] = chr(c)
            if col == cols - 1:
                wrap = True
            else:
                col += 1
        i += 1
    return screen, cursor


def main():
    if len(sys.argv) != 4:
        print("usage: tui_view.py rows:cols keys file", file=sys.stderr)
        return 2
    rows, cols = [int(x) for x in sys.argv[1].split(":")]
    out = read_tui(sys.argv[3], rows, cols, sys.argv[2])
    screen, cursor = decode(out, rows, cols)
    for y, line in enumerate(screen):
        marker = ">" if y == cursor[0] else " "
        print("%s%02d:%s" % (marker, y + 1, "".join(line).rstrip().replace(" ", ".")))
    print("cursor:%d:%d" % (cursor[0] + 1, cursor[1] + 1))
    text = "".join(screen[cursor[0]]).rstrip()
    if cursor[1] > len(text):
        print("cursor-past-eol:%d:%d:%d" % (cursor[0] + 1, cursor[1] + 1, len(text) + 1))
        return 1


if __name__ == "__main__":
    sys.exit(main())
