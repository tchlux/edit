// ___________________________________________________________________
//                            keydump.c
//
// DESCRIPTION
//  A tiny terminal key inspector. It enters raw mode and prints the exact
//  bytes received from stdin, one read at a time, so terminal key behavior can
//  be verified without going through edit's command dispatcher.
//
// USAGE
//    cc -std=c11 -Wall -Wextra -pedantic -O2 -o keydump keydump.c
//    ./keydump
//
//  Press keys to inspect them. Press Ctrl-C twice to quit.
// ___________________________________________________________________

#include <ctype.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/time.h>
#include <termios.h>
#include <unistd.h>

static struct termios saved;
static bool raw = false;

static void raw_off(void) {
  const char * mouse_off = "\x1b[?1006l\x1b[?1000l\x1b[?1007l";
  write(STDOUT_FILENO, mouse_off, strlen(mouse_off));
  if (raw) tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved);
  raw = false;
}

static int raw_on(void) {
  if (tcgetattr(STDIN_FILENO, &saved) != 0) return -1;
  atexit(raw_off);

  struct termios t = saved;
  t.c_iflag &= (tcflag_t) ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
  t.c_oflag &= (tcflag_t) ~(OPOST);
  t.c_cflag |= CS8;
  t.c_lflag &= (tcflag_t) ~(ECHO | ICANON | IEXTEN | ISIG);
  t.c_cc[VMIN] = 0;
  t.c_cc[VTIME] = 1;
  if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &t) != 0) return -1;
  raw = true;
  return 0;
}

static long long now_ms(void) {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return (long long) tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

static const char * name(unsigned char c) {
  static char s[16];
  if (c == 0x1b) return "ESC";
  if (c == 0x7f) return "DEL";
  if (c < 32) {
    snprintf(s, sizeof(s), "C-%c", c + 64);
    return s;
  }
  if (c >= 0x80) return "HIGH";
  if (isprint(c)) {
    snprintf(s, sizeof(s), "'%c'", c);
    return s;
  }
  return "?";
}

int main(void) {
  if (raw_on() != 0) {
    fprintf(stderr, "keydump: raw mode failed\n");
    return 1;
  }

  printf("keydump: press keys; Ctrl-C twice quits\r\n");
  printf("mouse reporting enabled; scroll or click to inspect mouse bytes\r\n");
  printf("note: macOS Option may send Unicode/dead-key text, not Meta commands\r\n");
  printf("time_ms bytes hex dec names\r\n");
  fflush(stdout);
  const char * mouse_on = "\x1b[?1007h\x1b[?1000h\x1b[?1006h";
  write(STDOUT_FILENO, mouse_on, strlen(mouse_on));

  int ctrl_c = 0;
  for (;;) {
    unsigned char buf[64];
    ssize_t n = read(STDIN_FILENO, buf, sizeof(buf));
    if (n <= 0) continue;

    printf("%lld bytes=%zd hex=", now_ms(), n);
    for (ssize_t i = 0; i < n; i++) printf("%02x%s", buf[i], (i + 1 == n) ? "" : " ");
    printf(" dec=");
    for (ssize_t i = 0; i < n; i++) printf("%u%s", buf[i], (i + 1 == n) ? "" : " ");
    printf(" names=");
    for (ssize_t i = 0; i < n; i++) printf("%s%s", name(buf[i]), (i + 1 == n) ? "" : " ");
    printf("\r\n");
    fflush(stdout);

    if (n == 1 && buf[0] == 3) {
      if (++ctrl_c >= 2) break;
    } else ctrl_c = 0;
  }

  return 0;
}
