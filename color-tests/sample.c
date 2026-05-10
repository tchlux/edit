#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>

#define LIMIT 16

typedef struct {
  const char * name;
  uint32_t flags;
} item;

static int score_item(const item * it, int bonus) {
  if (it == NULL) return -1;

  int score = 0x10 + bonus;
  for (size_t i = 0; it->name[i] != '\0'; i++) {
    score += (unsigned char) it->name[i];
  }

  // Clamp unusually noisy names.
  return score > LIMIT ? LIMIT : score;
}

int main(void) {
  item it = { "alpha://demo", true };
  printf("%s => %d\n", it.name, score_item(&it, 3));
  return 0;
}
